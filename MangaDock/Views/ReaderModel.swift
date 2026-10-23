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
    @Published var enhance: Bool = UserDefaults.standard.bool(forKey: enhanceDefaultsKey)

    private var source: ComicPageSource?
    private var client: WebDAVClient?
    private let imageCache = NSCache<NSNumber, UIImage>()
    /// Remembered width/height per page so vertical scrolling keeps stable heights
    /// even after LazyVStack throws the page view away.
    private var pageAspects: [Int: CGFloat] = [:]

    init(item: WebDAVItem) {
        currentItem = item
        imageCache.countLimit = 10
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
        enhance.toggle()
        UserDefaults.standard.set(enhance, forKey: enhanceDefaultsKey)
        imageCache.removeAllObjects()
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

    /// Sibling chapters come from the parent folder. Same kind only — a folder of
    /// image chapters walks to other folders, a CBZ walks to other CBZ files.
    private func buildSeries(client: WebDAVClient) async {
        guard let parent = Self.parentURL(of: currentItem.url),
              let children = try? await client.list(parent) else {
            series = [currentItem]
            seriesIndex = 0
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

    private func prepare(item: WebDAVItem, client: WebDAVClient) async throws -> ComicPageSource {
        if item.isArchive || item.isPDF {
            let cacheURL = CacheManager.archiveURL(for: item.url)
            if !CacheManager.hasArchive(for: item.url) {
                statusText = "正在下载 \(item.displayName)…"
                try await client.download(item.url, to: cacheURL) { [weak self] value in
                    Task { @MainActor [weak self] in
                        self?.downloadProgress = value
                    }
                }
            }
            statusText = item.isPDF ? "正在解析 PDF…" : "正在解压目录…"
            downloadProgress = nil
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

        statusText = "正在读取目录…"
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
        downloadProgress = nil
        chapterError = nil
    }

    // MARK: - Chapter switching

    @discardableResult
    func advanceChapter(direction: Int) async -> Bool {
        guard let client else { return false }
        let target = seriesIndex + direction
        guard target >= 0, target < series.count else { return false }

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
        // Two cache slots per page: plain and enhanced, so toggling is instant.
        let key = NSNumber(value: position * 2 + (enhance ? 1 : 0))
        if let cached = imageCache.object(forKey: key) { return cached }
        guard let source, position >= 0, position < source.pageCount else { return nil }

        do {
            let data = try await source.pageData(at: position)
            let wantsEnhance = enhance
            let decoded = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                guard let base = ImageDecoder.downsample(data) else { return nil }
                guard wantsEnhance else { return base }
                return ImageEnhancer.enhance(base) ?? base
            }.value
            if let decoded {
                imageCache.setObject(decoded, forKey: key)
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

    // MARK: - Helpers

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
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
