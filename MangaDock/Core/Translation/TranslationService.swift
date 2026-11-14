import Foundation
import UIKit
import Translation

/// 翻译流水线的编排：OCR → 缓存 → 端上翻译 → 回填。
///
/// 两个必须绕开的限制：
///
/// 1. `TranslationSession` 不能自己构造，只能由 SwiftUI 的 `.translationTask`
///    修饰符交进来。所以这里同时扮演两个角色 —— 对外提供「翻这一页」的接口，
///    对内保存 `run(session:)` 交给视图挂载。
///
/// 2. **不加类级 `@MainActor`**（跟 `DownloadStore` 一个理由）：视图要在存储属性
///    初始化器里写 `@ObservedObject private var x = TranslationService.shared`，
///    那是非隔离上下文，main-actor 隔离的单例在那儿编不过。改成只给会写
///    published 状态的方法单独标 `@MainActor`。
///
/// 队列用轮询唤醒而不是 AsyncStream：常驻一个 80ms 一次的 sleep 循环，
/// 每秒空转十几次的开销可以忽略，换来的是不用处理「闭包被取消 / 被重建 /
/// 多个消费者抢同一个流」这一堆时序坑。
final class TranslationService: ObservableObject {

    static let shared = TranslationService()

    /// 以 `章节URL#页号` 为键的页面状态。
    @Published private(set) var pages: [String: PageTranslationState] = [:]
    /// 交给视图挂到 `.translationTask` 上的配置。源语言变了才换新的实例。
    @Published private(set) var configuration: TranslationSession.Configuration?

    private var session: TranslationSession?
    private var queue: [Job] = []
    private var inFlight: Set<String> = []
    private var pumping = false
    private var configuredSource: String?
    private var configuredTarget: String?

    private struct Job {
        let key: String
        let chapter: String
        let page: Int
        let blocks: [TextBlock]
        let target: TranslationTarget
        let sourceCode: String?
    }

    private init() {}

    // MARK: - 键

    static func key(chapter: URL, page: Int) -> String {
        chapter.absoluteString + "#" + String(page)
    }

    @MainActor
    func state(for key: String) -> PageTranslationState {
        pages[key] ?? PageTranslationState()
    }

    // MARK: - 对外入口

    /// 翻一页。已经翻过、正在翻、或者用户没开翻译时直接返回。
    ///
    /// - Parameters:
    ///   - chapter: 章节 URL，用于缓存键。
    ///   - page: 页号（0 起）。
    ///   - data: 这一页的原始图片数据。
    ///   - force: 忽略已有结果重新识别（长按「重新识别这一页」）。
    @MainActor
    func translate(chapter: URL,
                   page: Int,
                   data: Data,
                   force: Bool = false) async {
        let key = Self.key(chapter: chapter, page: page)
        if inFlight.contains(key) { return }
        if !force, pages[key]?.phase == .ready { return }

        inFlight.insert(key)
        defer { inFlight.remove(key) }

        let target = TranslationPrefs.target
        let chapterID = chapter.absoluteString

        // 缓存优先：本地有就立刻显示，别让用户对着空白等识别。
        let cachedBlocks = force ? nil : TranslationCache.loadOCR(chapter: chapterID, page: page)
        if cachedBlocks == nil {
            pages[key] = PageTranslationState(blocks: [], phase: .recognizing)
        }

        var blocks: [TextBlock]
        if let cachedBlocks {
            blocks = cachedBlocks
        } else {
            guard let image = await Self.decodeForOCR(data) else {
                pages[key] = PageTranslationState(blocks: [], phase: .failed("这一页解不出图片"))
                return
            }
            let hint = TranslationPrefs.sourceHint
            let refine = TranslationPrefs.refineSmallText
            let result = await Task.detached(priority: .userInitiated) {
                await ComicOCR.recognize(image: image, hint: hint, refine: refine)
            }.value

            blocks = result.blocks
            guard !blocks.isEmpty else {
                pages[key] = PageTranslationState(blocks: [], phase: .failed("这一页没找到可识别的文字"))
                return
            }
            TranslationCache.storeOCR(chapter: chapterID, page: page, blocks: blocks)
            Self.rememberSource(result.dominantLanguage)
        }

        // 译文缓存：换目标语言才重翻，换页不用。
        let cachedTranslations = TranslationCache.loadTranslations(chapter: chapterID,
                                                                   page: page,
                                                                   target: target.rawValue)
        if !cachedTranslations.isEmpty {
            for index in blocks.indices {
                if let text = cachedTranslations[blocks[index].id] {
                    blocks[index].translated = text
                }
            }
            if blocks.allSatisfy({ $0.isTranslated }) {
                pages[key] = PageTranslationState(blocks: blocks, phase: .ready)
                return
            }
        }

        pages[key] = PageTranslationState(blocks: blocks, phase: .translating)

        let sourceCode = blocks.first?.language ?? Self.rememberedSource
        enqueue(Job(key: key,
                    chapter: chapterID,
                    page: page,
                    blocks: blocks.filter { !$0.isTranslated },
                    target: target,
                    sourceCode: sourceCode))
    }

    /// 视图挂载时调用，把 session 交进来并开始处理队列。
    ///
    /// 每个进入这里的调用都跑自己的循环，不做「只允许一个」的保护：
    /// `.translationTask` 在配置变化时会取消旧闭包、启动新闭包，如果新闭包
    /// 发现「已有循环在跑」就返回，而旧循环恰好正在被取消，队列就再也没人
    /// 处理了 —— 表现为「翻译按钮点了没反应」。多几个轮询循环完全无害，
    /// `pump()` 里有 `pumping` 锁，不会重复翻译同一批。
    @MainActor
    func run(session: TranslationSession) async {
        self.session = session
        await pump()

        while !Task.isCancelled {
            if queue.isEmpty {
                try? await Task.sleep(nanoseconds: 80_000_000)
                continue
            }
            await pump()
        }
    }

    /// 换章时清掉别的章节的状态，避免长年累月攒在内存里。
    @MainActor
    func trim(keepingChapter: URL) {
        let prefix = keepingChapter.absoluteString + "#"
        pages = pages.filter { $0.key.hasPrefix(prefix) }
    }

    @MainActor
    func clearState() {
        pages.removeAll()
    }

    // MARK: - 队列

    @MainActor
    private func enqueue(_ job: Job) {
        queue.removeAll { $0.key == job.key }
        queue.append(job)
        ensureConfiguration(source: job.sourceCode, target: job.target)
    }

    @MainActor
    private func pump() async {
        guard !pumping, let session else { return }
        pumping = true
        defer { pumping = false }

        while !queue.isEmpty {
            let job = queue.removeFirst()
            await perform(job, session: session)
        }
    }

    @MainActor
    private func perform(_ job: Job, session: TranslationSession) async {
        // 语言对不支持的话，translate 会一直抛错，先问一句省得白跑。
        let targetLanguage = job.target.language
        if let sourceCode = job.sourceCode {
            let availability = LanguageAvailability()
            let status = await availability.status(from: Locale.Language(identifier: sourceCode),
                                                   to: targetLanguage)
            if status == .unsupported {
                pages[job.key] = PageTranslationState(
                    blocks: job.blocks,
                    phase: .failed("系统不支持 \(Self.languageName(sourceCode)) → \(job.target.title)")
                )
                return
            }
        }

        // 一次塞太多，端上模型会明显变慢，24 条一批刚好。
        let batchSize = 24
        var collected: [Int: String] = [:]
        var start = 0
        while start < job.blocks.count {
            let end = min(start + batchSize, job.blocks.count)
            let chunk = Array(job.blocks[start..<end])
            start = end

            let requests = chunk.map {
                TranslationSession.Request(sourceText: $0.source,
                                           clientIdentifier: String($0.id))
            }
            do {
                let responses = try await session.translations(from: requests)
                for response in responses {
                    guard let identifier = response.clientIdentifier,
                          let id = Int(identifier) else { continue }
                    let text = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { collected[id] = text }
                }
            } catch {
                pages[job.key] = PageTranslationState(
                    blocks: job.blocks,
                    phase: .failed(Self.describe(error))
                )
                return
            }
        }

        guard !collected.isEmpty else {
            pages[job.key] = PageTranslationState(blocks: job.blocks, phase: .failed("没拿到译文"))
            return
        }

        TranslationCache.storeTranslations(chapter: job.chapter,
                                           page: job.page,
                                           target: job.target.rawValue,
                                           translations: collected)

        // 合并回这一页的完整状态（队列里的 blocks 只有未翻译的，之前已翻的在 pages 里）。
        var state = pages[job.key] ?? PageTranslationState(blocks: job.blocks, phase: .translating)
        var remaining = false
        for index in state.blocks.indices {
            if let text = collected[state.blocks[index].id] {
                state.blocks[index].translated = text
            }
            if !state.blocks[index].isTranslated { remaining = true }
        }
        state.phase = remaining ? .failed("有一部分没翻出来") : .ready
        pages[job.key] = state
    }

    // MARK: - 配置

    @MainActor
    private func ensureConfiguration(source: String?, target: TranslationTarget) {
        if configuredSource == source, configuredTarget == target.rawValue { return }
        configuredSource = source
        configuredTarget = target.rawValue
        configuration = TranslationSession.Configuration(
            source: source.map { Locale.Language(identifier: $0) },
            target: target.language
        )
    }

    // MARK: - 主导语种记忆

    /// 这一整话的主导语种。逐页识别时用它兜底（缓存命中的页可能没带语种）。
    private static var rememberedSource: String?

    private static func rememberSource(_ code: String?) {
        guard let code, !code.isEmpty else { return }
        rememberedSource = code
    }

    // MARK: - 辅助

    /// OCR 用的图不能用显示用的（那张已经降采样到屏幕分辨率，小字早糊了），
    /// 但也不能直接用原图（4000px 整页要跑三四秒）。短边 1800 是实测的平衡点。
    private static func decodeForOCR(_ data: Data) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            ImageDecoder.downsample(data, maxPixelSize: 1800)
        }.value
    }

    private static func languageName(_ code: String) -> String {
        switch code.lowercased() {
        case "ja", "ja-jp": return "日文"
        case "ko", "ko-kr": return "韩文"
        case "zh", "zh-hans", "zh-hant": return "中文"
        case "en", "en-us": return "英文"
        default: return code
        }
    }

    private static func describe(_ error: Error) -> String {
        let text = "\(error)"
        if text.contains("already") || text.contains("in progress") {
            return "翻译引擎正忙，等一下再试"
        }
        if text.contains("download") || text.contains("language") {
            return "语言包还没下载，去系统「翻译」里装一下"
        }
        return "翻译失败：\(error.localizedDescription)"
    }
}
