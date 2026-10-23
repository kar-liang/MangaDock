import Foundation
import UIKit
import SwiftUI

private let enhanceDefaultsKey = "mangadock.enhance"

@MainActor
final class ReaderModel: ObservableObject {
    let item: WebDAVItem

    @Published var pageCount: Int = 0
    @Published var index: Int = 0
    @Published var isLoading: Bool = true
    @Published var statusText: String = "正在打开…"
    @Published var downloadProgress: Double? = nil
    @Published var errorMessage: String? = nil
    @Published var enhance: Bool = UserDefaults.standard.bool(forKey: enhanceDefaultsKey)

    private var source: ComicPageSource?
    private let imageCache = NSCache<NSNumber, UIImage>()

    init(item: WebDAVItem) {
        self.item = item
        imageCache.countLimit = 6
    }

    func toggleEnhance() {
        enhance.toggle()
        UserDefaults.standard.set(enhance, forKey: enhanceDefaultsKey)
        imageCache.removeAllObjects()
    }

    func load(client: WebDAVClient, startPage: Int) async {
        isLoading = true
        errorMessage = nil
        downloadProgress = nil
        imageCache.removeAllObjects()

        do {
            let source = try await makeSource(client: client)
            self.source = source
            pageCount = source.pageCount
            index = min(max(0, startPage), max(0, pageCount - 1))
            isLoading = false
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            isLoading = false
        }
    }

    private func makeSource(client: WebDAVClient) async throws -> ComicPageSource {
        if item.isArchive {
            let cacheURL = CacheManager.archiveURL(for: item.url)
            if !CacheManager.hasArchive(for: item.url) {
                statusText = "正在下载 \(item.name)…"
                try await client.download(item.url, to: cacheURL) { [weak self] value in
                    Task { @MainActor [weak self] in
                        self?.downloadProgress = value
                    }
                }
            }
            statusText = "正在解压目录…"
            downloadProgress = nil
            let url = cacheURL
            do {
                return try await Task.detached(priority: .userInitiated) {
                    try ZipComicSource(fileURL: url)
                }.value
            } catch {
                // A half-written archive poisons the cache — drop it so retry re-downloads.
                CacheManager.removeArchive(for: item.url)
                throw error
            }
        } else {
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
    }

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
            }
            return decoded
        } catch {
            return nil
        }
    }

    func step(_ delta: Int) {
        guard pageCount > 0 else { return }
        index = min(max(0, index + delta), pageCount - 1)
    }
}
