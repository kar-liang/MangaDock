import Foundation
import UIKit
import PDFKit

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
            .filter { PageFiles.isPageFile($0.name) }
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
    private let client: RemoteClient
    let pageCount: Int

    init(items: [WebDAVItem], client: RemoteClient) {
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

/// A downloaded chapter that was originally a WebDAV folder of images. The
/// images live in one local directory, so pages read straight off disk.
final class LocalFolderComicSource: ComicPageSource {
    private let files: [URL]
    let pageCount: Int

    init(directory: URL) throws {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        )) ?? []
        let images = urls
            .filter { PageFiles.isPageFile($0.lastPathComponent) }
            .sorted { NaturalSort.less($0.lastPathComponent, $1.lastPathComponent) }
        guard !images.isEmpty else {
            throw ZipError.unsupported("本地下载目录里没有图片")
        }
        self.files = images
        self.pageCount = images.count
    }

    func pageData(at index: Int) async throws -> Data {
        guard index >= 0, index < pageCount else { throw ZipError.corrupt }
        return try Data(contentsOf: files[index])
    }
}

enum PDFComicError: LocalizedError {
    case unreadable

    var errorDescription: String? {
        "这个 PDF 打不开（可能是加密、损坏，或者不是 PDF）"
    }
}

/// Renders PDF pages to images so the reader doesn't need a second code path.
/// PDFKit isn't documented as thread-safe, so every render goes through one
/// serial queue (also keeps the rasterising off the main thread).
final class PDFComicSource: ComicPageSource {
    private let document: PDFDocument
    private let renderQueue = DispatchQueue(label: "com.karliang.mangadock.pdfrender")
    let pageCount: Int

    init(fileURL: URL) throws {
        guard let document = PDFDocument(url: fileURL) else { throw PDFComicError.unreadable }
        self.document = document
        self.pageCount = document.pageCount
        if pageCount == 0 { throw PDFComicError.unreadable }
    }

    func pageData(at index: Int) async throws -> Data {
        guard index >= 0, index < pageCount else { throw PDFComicError.unreadable }
        let target = index
        return try await withCheckedThrowingContinuation { continuation in
            renderQueue.async { [self] in
                do {
                    continuation.resume(returning: try render(target))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func render(_ index: Int) throws -> Data {
        guard let page = document.page(at: index) else { throw PDFComicError.unreadable }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 1, bounds.height > 1 else { throw PDFComicError.unreadable }

        let maxPixel: CGFloat = 2400
        let scale = min(2.5, max(1, maxPixel / max(bounds.width, bounds.height)))
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            context.cgContext.translateBy(x: 0, y: size.height)
            context.cgContext.scaleBy(x: scale, y: -scale)
            page.draw(with: .mediaBox, to: context.cgContext)
        }

        guard let data = image.jpegData(compressionQuality: 0.92) else {
            throw PDFComicError.unreadable
        }
        return data
    }
}

/// Komga 上的一本书。页数在打开时问一次，之后每页按需请求。
/// Komga 的页接口编号从 1 开始，这里的 index 从 0 开始，在 client 内部换算。
final class KomgaComicSource: ComicPageSource {
    let pageCount: Int

    private let bookID: String
    private let client: KomgaClient

    init(bookID: String, pageCount: Int, client: KomgaClient) {
        self.bookID = bookID
        self.pageCount = pageCount
        self.client = client
    }

    func pageData(at index: Int) async throws -> Data {
        guard index >= 0, index < pageCount else { throw ZipError.corrupt }
        guard let url = URL(string: "komga://page/\(bookID)/\(index)") else {
            throw KomgaError.badURL
        }
        return try await client.data(for: url)
    }
}
