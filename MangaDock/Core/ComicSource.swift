import Foundation

/// One readable comic: a page count plus a way to get page bytes.
protocol ComicPageSource: AnyObject {
    var pageCount: Int { get }
    func pageData(at index: Int) async throws -> Data
}

/// CBZ / ZIP on local disk (already downloaded to the cache).
final class ZipComicSource: ComicPageSource {
    private let archive: ZipArchive
    private let pages: [ZipEntry]
    let pageCount: Int

    init(fileURL: URL) throws {
        let archive = try ZipArchive(fileURL: fileURL)
        self.archive = archive
        self.pages = archive.entries
            .filter { ComicPageSource.isPageFile($0.name) }
            .sorted { NaturalSort.less($0.name, $1.name) }
        self.pageCount = pages.count
        if pageCount == 0 {
            throw ZipError.unsupported("压缩包里没有图片，检查一下是不是只有文件夹或 PDF")
        }
    }

    func pageData(at index: Int) async throws -> Data {
        guard index >= 0, index < pageCount else { throw ZipError.corrupt }
        return try archive.data(for: pages[index])
    }
}

/// A WebDAV folder whose children are images.
final class FolderComicSource: ComicPageSource {
    private let items: [WebDAVItem]
    private let client: WebDAVClient
    let pageCount: Int

    init(items: [WebDAVItem], client: WebDAVClient) {
        self.items = items
        self.client = client
        self.pageCount = items.count
    }

    func pageData(at index: Int) async throws -> Data {
        guard index >= 0, index < pageCount else { throw ZipError.corrupt }
        let item = items[index]
        if let cached = CacheManager.pageData(for: item.url) {
            return cached
        }
        let data = try await client.data(for: item.url)
        CacheManager.storePage(data, for: item.url)
        return data
    }
}
