import Foundation
import UIKit
import SwiftUI

private let enhanceDefaultsKey = "mangadock.enhance"

enum StepOutcome {
    case moved
    case atStart
    case atEnd
    case loadNextChapter
}

@MainActor
final class ReaderModel: ObservableObject {
    @Published private(set) var currentItem: WebDAVItem
    @Published private(set) var series: [WebDAVItem] = []
    @Published private(set) var seriesIndex: Int = 0

    @Published private(set) var pageCount: Int = 0
    @Published var index: Int = 0
    @Published var isLoading: Bool = true
    @Published var statusText: String = "正在打开…"
    @Published var downloadProgress: Double? = nil
    @Published var errorMessage: String? = nil
    @Published var chapterError: String? = nil
    @Published var enhance: Bool = false
    /// Per-comic AI scale (2 or 4), defaulting to the global setting.
    @Published var aiScale: Int = 2
    /// Bumped whenever the enhance mode (on/off or 2x/4x) changes, so visible
    /// pages know to drop their decoded image and re-render.
    @Published private(set) var enhanceGeneration = 0

    private var source: ComicPageSource?
    private var client: WebDAVClient?
    private let imageCache = NSCache<NSNumber, UIImage>()
    /// Remembered width/height per page so vertical scrolling keeps stable heights
    /// even after LazyVStack throws the page view away.
    private var pageAspects: [Int: CGFloat] = [:]

    init(item: WebDAVItem) {
        currentItem = item
        imageCache.countLimit = 12
        // Budget by BYTES, not by entry count: one 2200px webtoon page is
        // ~25 MB decoded, so "10 items" could mean 250 MB and iOS would start
        // killing caches behind our back (which is one source of the black
        // flash mid-scroll).
        imageCache.totalCostLimit = 160 * 1024 * 1024
    }

    func aspect(for position: Int) -> CGFloat {
        pageAspects[position] ?? 0.72
    }

    // MARK: - Derived

    var nextItem: WebDAVItem? {
        seriesIndex + 1 < series.count ? series[seriesIndex + 1] : nil
    }

    var previousItem: WebDAVItem? {
        seriesIndex > 0 ? series[seriesIndex - 1] : nil
    }

    /// Real pages plus the "本话看完" card when a next chapter exists.
    var displayPageCount: Int {
        pageCount + (nextItem != nil ? 1 : 0)
    }

    var isOnChapterEndCard: Bool {
        pageCount > 0 && index >= pageCount
    }

    var chapterLabel: String {
        guard series.count > 1 else { return "" }
        return "第 \(seriesIndex + 1) / \(series.count) 话"
    }

    func toggleEnhance() {
        setEnhance(on: !enhance)
    }

    /// Toolbar entry: turns enhancement on/off and optionally picks the AI scale.
    /// Bumps `enhanceGeneration` so visible pages re-render with the new mode.
    func setEnhance(on: Bool, scale: AIEnhancer.Scale? = nil) {
        let changed = on != enhance || (scale != nil && scale!.rawValue != aiScale)
        guard changed else { return }
        enhance = on
        if let scale { aiScale = scale.rawValue }
        PerComicPrefs.setEnhance(on, for: currentItem.url)
        PerComicPrefs.setAIScale(aiScale, for: currentItem.url)
        imageCache.removeAllObjects()
        prewarming.removeAll()
        pageTasks.removeAll()
        enhanceGeneration += 1
        prewarm(from: index + 1)
    }

    // MARK: - Loading

    func start(client: WebDAVClient, startPage: Int) async {
        self.client = client
        isLoading = true
        errorMessage = nil
        chapterError = nil

        await buildSeries(client: client)

        do {
            let prepared = try await prepare(item: currentItem, client: client)
            adopt(item: currentItem, source: prepared, startPage: startPage)
            isLoading = false
        } catch {
            errorMessage = Self.message(for: error)
            isLoading = false
        }
    }

    /// Local-file path: no WebDAV client, read straight off disk.
    func startLocal(startPage: Int) async {
        isLoading = true
        errorMessage = nil
        chapterError = nil
        series = [currentItem]
        seriesIndex = 0

        do {
            let prepared = try await prepareLocal(item: currentItem)
            adopt(item: currentItem, source: prepared, startPage: startPage)
            isLoading = false
        } catch {
            errorMessage = Self.message(for: error)
            isLoading = false
        }
    }

    private func prepareLocal(item: WebDAVItem) async throws -> ComicPageSource {
        return try await Task.detached(priority: .userInitiated) { () -> ComicPageSource in
            if item.isPDF { return try PDFComicSource(fileURL: item.url) }
            return try ZipComicSource(fileURL: item.url)
        }.value
    }

    /// Sibling chapters come from the parent folder. Same kind only — a folder of
    /// image chapters walks to other folders, a CBZ walks to other CBZ files.
    /// Offline: when the folder can't be listed, fall back to the chapters that
    /// were downloaded, so chapter-to-chapter reading still works with no
    /// network at all.
    private func buildSeries(client: WebDAVClient) async {
        guard let parent = Self.parentURL(of: currentItem.url),
              let children = try? await client.list(parent) else {
            let offline = DownloadStore.shared.downloadedSiblings(of: currentItem)
            if let index = offline.firstIndex(where: { $0.id == currentItem.id }) {
                series = offline
                seriesIndex = index
            } else {
                series = [currentItem]
                seriesIndex = 0
            }
            return
        }

        let wantsFolders = currentItem.isDirectory
        var candidates = children.filter {
            wantsFolders ? $0.isDirectory : ($0.isArchive || $0.isPDF)
        }

        if !candidates.contains(where: { $0.id == currentItem.id }) {
            candidates.append(currentItem)
        }
        candidates.sort { NaturalSort.less($0.name, $1.name) }

        series = candidates
        seriesIndex = candidates.firstIndex(where: { $0.id == currentItem.id }) ?? 0
    }

    private func prepare(item: WebDAVItem, client: WebDAVClient, silent: Bool = false) async throws -> ComicPageSource {
        // Offline first: a downloaded chapter reads straight off disk, no
        // network round-trip and no waiting.
        if let local = await DownloadStore.shared.localSource(for: item.url) {
            if !silent {
                statusText = "正在读取本地下载…"
                downloadProgress = nil
            }
            return local
        }

        if item.isArchive || item.isPDF {
            let cacheURL = CacheManager.archiveURL(for: item.url)
            if !CacheManager.hasArchive(for: item.url) {
                if !silent { statusText = "正在下载 \(item.displayName)…" }
                try await client.download(item.url, to: cacheURL) { [weak self] value in
                    guard !silent else { return }
                    Task { @MainActor [weak self] in
                        self?.downloadProgress = value
                    }
                }
            }
            if !silent {
                statusText = item.isPDF ? "正在解析 PDF…" : "正在解压目录…"
                downloadProgress = nil
            }
            let url = cacheURL
            let isPDF = item.isPDF
            do {
                return try await Task.detached(priority: .userInitiated) { () -> ComicPageSource in
                    if isPDF { return try PDFComicSource(fileURL: url) }
                    return try ZipComicSource(fileURL: url)
                }.value
            } catch {
                CacheManager.removeArchive(for: item.url)
                throw error
            }
        }

        if !silent { statusText = "正在读取目录…" }
        let children = try await client.list(item.requestURL)
        let images = children
            .filter { !$0.isDirectory && $0.isImage }
            .sorted { NaturalSort.less($0.name, $1.name) }
        guard !images.isEmpty else {
            throw ZipError.unsupported("这个文件夹里没有图片")
        }
        return FolderComicSource(items: images, client: client)
    }

    private func adopt(item: WebDAVItem, source: ComicPageSource, startPage: Int) {
        currentItem = item
        self.source = source
        pageCount = source.pageCount
        index = min(max(0, startPage), max(0, pageCount - 1))
        imageCache.removeAllObjects()
        // Stale in-flight positions from the previous chapter would otherwise
        // block prewarming for the new one.
        prewarming.removeAll()
        pageTasks.removeAll()
        downloadProgress = nil
        chapterError = nil
        // Per-comic enhance/scale, falling back to the global defaults.
        enhance = PerComicPrefs.enhanceEnabled(for: item.url,
                                               default: UserDefaults.standard.bool(forKey: enhanceDefaultsKey))
        aiScale = PerComicPrefs.aiScale(for: item.url,
                                        default: ImageEnhancer.aiScale.rawValue)
    }

    // MARK: - Chapter switching

    /// Pre-loaded next chapter, keyed by its series index.
    private var preparedNext: (index: Int, source: ComicPageSource)?
    private var preloadingNext = false

    /// Background-prepares the next chapter once the reader is near the end,
    /// so tapping/overscrolling into it is instant.
    func preloadNextChapterIfNeeded() {
        guard let client, pageCount > 0, index >= pageCount - 2 else { return }
        let target = seriesIndex + 1
        guard target >= 0, target < series.count else { return }
        guard preparedNext?.index != target, !preloadingNext else { return }

        preloadingNext = true
        let item = series[target]
        Task { [weak self] in
            guard let self else { return }
            if let source = try? await self.prepare(item: item, client: client, silent: true) {
                self.preparedNext = (target, source)
            }
            self.preloadingNext = false
        }
    }

    @discardableResult
    func advanceChapter(direction: Int) async -> Bool {
        guard let client else { return false }
        let target = seriesIndex + direction
        guard target >= 0, target < series.count else { return false }

        // Reuse the pre-loaded next chapter when moving forward.
        if direction == 1, let p = preparedNext, p.index == target {
            adopt(item: series[target], source: p.source, startPage: 0)
            preparedNext = nil
            seriesIndex = target
            return true
        }

        chapterError = nil
        isLoading = true

        do {
            let prepared = try await prepare(item: series[target], client: client)
            adopt(item: series[target], source: prepared, startPage: 0)
            seriesIndex = target
            isLoading = false
            return true
        } catch {
            chapterError = Self.message(for: error)
            isLoading = false
            return false
        }
    }

    // MARK: - Paging

    @discardableResult
    func step(_ delta: Int) -> StepOutcome {
        guard pageCount > 0 else { return .atStart }
        let last = max(0, displayPageCount - 1)
        let target = index + delta

        if target > last {
            if delta == 1, nextItem != nil { return .loadNextChapter }
            index = last
            return .moved
        }
        if target < 0 { return .atStart }
        index = target
        return .moved
    }

    // MARK: - Page images

    func image(at position: Int) async -> UIImage? {
        await preparePage(position)
    }

    /// Decodes already running, keyed by cache key. A visible page used to
    /// start a second decode of the very bytes its pre-render was already
    /// working on — that duplicated work is half of the perceived lag.
    private var pageTasks: [Int: Task<UIImage?, Never>] = [:]

    /// Decodes + enhances a page and stores it in the cache. Used both for the
    /// visible page and for background pre-rendering of upcoming pages.
    @discardableResult
    private func preparePage(_ position: Int) async -> UIImage? {
        guard let source, position >= 0, position < source.pageCount else { return nil }

        let cacheKey = position * 2 + (enhance ? 1 : 0)
        let key = NSNumber(value: cacheKey)
        if let cached = imageCache.object(forKey: key) { return cached }

        // Join the in-flight decode instead of starting another one.
        if let running = pageTasks[cacheKey] {
            return await running.value
        }

        let task = Task<UIImage?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.decode(position: position, source: source, key: key)
        }
        pageTasks[cacheKey] = task
        let image = await task.value
        pageTasks[cacheKey] = nil
        return image
    }

    private func decode(position: Int, source: ComicPageSource, key: NSNumber) async -> UIImage? {
        do {
            let data = try await source.pageData(at: position)
            let wantsEnhance = enhance
            let useAI = wantsEnhance && ImageEnhancer.hasAIModel
            let decoded = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                guard let base = ImageDecoder.downsample(data) else { return nil }
                if useAI { return base }                     // AI gets the clean decode
                guard wantsEnhance else { return base }
                return ImageEnhancer.enhance(base) ?? base
            }.value

            // AI super-resolution on top of the clean decode. Slow (seconds per
            // page) — acceptable because it only runs when enhance is on.
            if useAI, let decoded,
               let ai = await ImageEnhancer.enhanceAI(decoded, scale: AIEnhancer.Scale(rawValue: aiScale) ?? .two) {
                imageCache.setObject(ai, forKey: key, cost: Self.cost(of: ai))
                let size = ai.size
                if size.height > 0 {
                    pageAspects[position] = size.width / size.height
                }
                return ai
            }

            if let decoded {
                imageCache.setObject(decoded, forKey: key, cost: Self.cost(of: decoded))
                let size = decoded.size
                if size.height > 0 {
                    pageAspects[position] = size.width / size.height
                }
            }
            return decoded
        } catch {
            return nil
        }
    }

    /// Pages currently being pre-rendered, so repeated triggers don't queue
    /// duplicate work (onAppear fires often while scrolling).
    private var prewarming: Set<Int> = []

    /// Background pre-renders the next few pages so turning or scrolling is
    /// instant.
    ///
    /// This runs in BOTH modes. It used to be gated on AI enhancement, on the
    /// theory that plain decoding was fast enough — it isn't: decoding a
    /// 2200px webtoon page costs a few hundred milliseconds, which is exactly
    /// the "black page + spinner" you'd see after flicking ahead.
    func prewarm(from index: Int, count: Int = 3) {
        guard source != nil, pageCount > 0 else { return }
        // AI super-resolution takes seconds per page, so don't run ahead as far.
        let wanted = (enhance && ImageEnhancer.hasAIModel) ? min(count, 2) : count
        let end = min(pageCount, index + wanted)
        guard index >= 0, index < end else { return }

        // Cache key depends on the mode — the old code always probed the
        // enhanced slot, so with enhancement off nothing ever counted as
        // "already rendered" and every prewarm re-decoded the page.
        let slot = enhance ? 1 : 0

        for position in index..<end {
            // At most two background decodes at a time: the visible page keeps
            // its CPU share and the memory peak stays sane.
            if prewarming.count >= 2 { break }

            let key = NSNumber(value: position * 2 + slot)
            guard imageCache.object(forKey: key) == nil,
                  !prewarming.contains(position) else { continue }
            prewarming.insert(position)
            Task { [weak self] in
                await self?.preparePage(position)
                self?.prewarming.remove(position)
            }
        }
    }

    /// Decoded byte size, for NSCache's byte-based eviction.
    private static func cost(of image: UIImage) -> Int {
        if let cg = image.cgImage {
            return cg.bytesPerRow * cg.height
        }
        return Int(image.size.width * image.size.height * 4)
    }

    // MARK: - Helpers

    private static func message(for error: Error) -> String {
        NetErrorText.friendly(error)
    }

    static func parentURL(of url: URL) -> URL? {
        var text = url.absoluteString
        while text.hasSuffix("/") && text.count > 8 { text.removeLast() }
        guard let clean = URL(string: text) else { return nil }
        let parent = clean.deletingLastPathComponent()
        guard parent.absoluteString.count >= 8 else { return nil }
        return WebDAVItem.directoryURL(parent)
    }
}
