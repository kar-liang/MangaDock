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
        /// 已经补翻过几次。漏条补翻靠它收口，超了就老实报失败，
        /// 不能无限重试烧 token。
        var attempt: Int = 0
    }

    /// 一页最多补翻几次（首次不算）。模型偶尔漏掉尾部几条是常态，
    /// 把漏的单独再发一次，量小、又不容易再漏。
    private static let maxRetries = 2

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
            let result = await Self.recognizeWithTimeout(image: image, hint: hint, refine: refine)
            guard let result else {
                pages[key] = PageTranslationState(
                    blocks: [],
                    phase: .failed("识别超时 \(Int(Self.timeout(for: image)))s，关掉「小字二次识别」再试")
                )
                return
            }

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

        if TranslationPrefs.usesLLM {
            // 大模型走 HTTP，不需要 TranslationSession，自己把队列推起来。
            Task { @MainActor [weak self] in
                await self?.pump()
            }
        } else {
            // 端上引擎要靠 configuration 变化去触发 .translationTask，
            // session 交进来之后由 run() 的轮询循环接手。
            ensureConfiguration(source: job.sourceCode, target: job.target)
        }
    }

    @MainActor
    private func pump() async {
        guard !pumping else { return }
        pumping = true
        defer { pumping = false }

        while !queue.isEmpty {
            let job = queue[0]
            if TranslationPrefs.usesLLM {
                queue.removeFirst()
                await performLLM(job)
            } else {
                // 端上引擎：session 还没被 .translationTask 交进来就先等着，
                // 别把这一页判成失败。
                guard let session else { return }
                queue.removeFirst()
                await performOnDevice(job, session: session)
            }
        }
    }

    /// 大模型路径。一页一次请求，把整页台词一起送过去 ——
    /// 有上下文，人称和语气比逐条翻连贯得多。
    @MainActor
    private func performLLM(_ job: Job) async {
        do {
            let map = try await LLMTranslator.translate(blocks: job.blocks,
                                                        config: TranslationPrefs.llmConfig,
                                                        target: job.target)
            apply(map, to: job)
        } catch {
            pages[job.key] = PageTranslationState(
                blocks: job.blocks,
                phase: .failed(Self.describeLLM(error))
            )
        }
    }

    @MainActor
    private func performOnDevice(_ job: Job, session: TranslationSession) async {
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
                // 后面的批次失败时，前面已经翻好的别一起扔掉：
                // 先回填，剩下的走 apply 的补翻逻辑。
                if collected.isEmpty {
                    pages[job.key] = PageTranslationState(
                        blocks: job.blocks,
                        phase: .failed(Self.describe(error))
                    )
                } else {
                    apply(collected, to: job)
                }
                return
            }
        }

        apply(collected, to: job)
    }

    /// 回填译文 + 写缓存 + 收尾状态。两个引擎共用。
    ///
    /// 漏条不再直接判失败：模型（尤其一页台词多时）经常漏掉尾部几条，
    /// 而块是按从上到下排的，漏的正好是下半页 —— 以前这里一漏就把整页
    /// 标成 failed，阅读器又只翻 idle 的页，这一页就永远停在半翻状态、
    /// 队列径直去翻下一页。现在把没翻出来的块单独凑一个补翻 job 重新入队
    /// （量小，模型不容易再漏），补 `maxRetries` 次还漏才报失败。
    @MainActor
    private func apply(_ translations: [Int: String], to job: Job) {
        if !translations.isEmpty {
            TranslationCache.storeTranslations(chapter: job.chapter,
                                               page: job.page,
                                               target: job.target.rawValue,
                                               translations: translations)
        }

        // 合并回这一页的完整状态（队列里的 blocks 只有未翻译的，之前已翻的在 pages 里）。
        var state = pages[job.key] ?? PageTranslationState(blocks: job.blocks, phase: .translating)
        for index in state.blocks.indices {
            if let text = translations[state.blocks[index].id] {
                state.blocks[index].translated = text
            }
        }
        let missing = state.blocks.filter { !$0.isTranslated }

        guard !missing.isEmpty else {
            state.phase = .ready
            pages[job.key] = state
            return
        }

        if job.attempt < Self.maxRetries {
            state.phase = .translating
            pages[job.key] = state
            diagAsync("translate", "retry missing \(missing.count) blocks page=\(job.page) attempt=\(job.attempt + 1)")
            enqueue(Job(key: job.key,
                        chapter: job.chapter,
                        page: job.page,
                        blocks: missing,
                        target: job.target,
                        sourceCode: job.sourceCode,
                        attempt: job.attempt + 1))
            return
        }

        state.phase = .failed(translations.isEmpty && state.blocks.allSatisfy { !$0.isTranslated }
                              ? "没拿到译文"
                              : "有一部分没翻出来")
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

    /// 识别总超时（秒，普通页）。
    ///
    /// Vision 在超大页面上（超长条漫、扫描件）可能跑几十秒。不设上限的话界面
    /// 会永远停在「识别文字…」，用户根本分不清是在跑还是已经卡死 ——
    /// 这一版就是被这个坑到的。宁可超时报错，让人知道发生了什么。
    private static let ocrTimeout: Double = 30

    /// 这一页的实际超时：长图是分片识别的，片数越多活越多，
    /// 还按 30 秒一刀切的话，分片修好了下半页、又会整页超时失败。
    /// 每多一片加 20 秒，总上限 120 秒。
    private static func timeout(for image: UIImage) -> Double {
        guard let cgImage = image.cgImage else { return ocrTimeout }
        let tiles = ComicOCR.tileCount(pixelWidth: cgImage.width, pixelHeight: cgImage.height)
        guard tiles > 1 else { return ocrTimeout }
        return min(120, ocrTimeout + 20 * Double(tiles - 1))
    }

    /// 跑 OCR，到点没结果就返回 nil。
    ///
    /// 为什么不用 `withTaskGroup` 竞速：group 会**等所有子任务结束**才返回，
    /// 而 Vision 的 `perform` 是同步的、不响应取消 —— 超时那条路会一直卡在
    /// 等 OCR 跑完，等于没超时。所以这里让 OCR 跑在 group 之外，用一次性
    /// 闩保证「完成」和「超时」只有一方能唤醒 continuation。
    ///
    /// 代价：超时之后那次 OCR 仍在后台跑完（不写缓存、不更新状态），
    /// 只是没人在等它。这是能接受的 —— 总比界面永远转圈强。
    private static func recognizeWithTimeout(image: UIImage,
                                             hint: TranslationSourceHint,
                                             refine: Bool) async -> ComicOCR.Result? {
        let latch = OnceLatch()
        return await withCheckedContinuation { (continuation: CheckedContinuation<ComicOCR.Result?, Never>) in
            Task.detached(priority: .userInitiated) {
                let result = await ComicOCR.recognize(image: image, hint: hint, refine: refine)
                if latch.fire() {
                    continuation.resume(returning: result)
                } else {
                    diagAsync("translate", "ocr finished after timeout, discarded")
                }
            }
            let limit = timeout(for: image)
            Task {
                try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
                if latch.fire() {
                    diagAsync("translate", "ocr timeout \(Int(limit))s")
                    continuation.resume(returning: nil)
                }
            }
        }
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

    /// 大模型这条路的错误自带人话（`LLMTranslateError.errorDescription`），直接用。
    private static func describeLLM(_ error: Error) -> String {
        if let llm = error as? LLMTranslateError {
            return llm.errorDescription ?? "大模型翻译失败"
        }
        return "大模型翻译失败：\(error.localizedDescription)"
    }
}

/// 谁先到算谁的小闩。OCR 的「完成」和「超时」是两条并行路径，
/// 只有第一个能唤醒 continuation，第二个直接作废。
private final class OnceLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func fire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}
