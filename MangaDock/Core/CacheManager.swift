import Foundation
import CryptoKit

enum CacheManager {
    static var root: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MangaDock", isDirectory: true)
    }

    static var booksDirectory: URL { root.appendingPathComponent("books", isDirectory: true) }
    static var pagesDirectory: URL { root.appendingPathComponent("pages", isDirectory: true) }
    static var coversDirectory: URL { root.appendingPathComponent("covers", isDirectory: true) }

    static func ensure(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    static func hash(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func archiveURL(for url: URL) -> URL {
        ensure(booksDirectory)
        let ext = (url.pathExtension.isEmpty ? "bin" : url.pathExtension)
        return booksDirectory.appendingPathComponent(hash(url.absoluteString) + "." + ext)
    }

    static func hasArchive(for url: URL) -> Bool {
        FileManager.default.fileExists(atPath: archiveURL(for: url).path)
    }

    // MARK: - Loose page cache (folder-of-images comics)

    static func pageURL(for url: URL) -> URL {
        ensure(pagesDirectory)
        return pagesDirectory.appendingPathComponent(hash(url.absoluteString) + ".img")
    }

    static func pageData(for url: URL) -> Data? {
        let fileURL = pageURL(for: url)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try? Data(contentsOf: fileURL)
    }

    static func storePage(_ data: Data, for url: URL) {
        try? data.write(to: pageURL(for: url), options: .atomic)
    }

    // MARK: - Grid covers

    static func coverURL(key: String) -> URL {
        ensure(coversDirectory)
        return coversDirectory.appendingPathComponent(hash(key) + ".jpg")
    }

    static func coverData(key: String) -> Data? {
        try? Data(contentsOf: coverURL(key: key))
    }

    static func storeCover(_ data: Data, key: String) {
        try? data.write(to: coverURL(key: key), options: .atomic)
    }

    // MARK: - Maintenance

    static func sizeOnDisk() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey])
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }

    static func formattedSize() -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: sizeOnDisk())
    }

    static func clear() {
        try? FileManager.default.removeItem(at: root)
        ensure(booksDirectory)
        ensure(pagesDirectory)
    }

    static func removeArchive(for url: URL) {
        try? FileManager.default.removeItem(at: archiveURL(for: url))
    }
}
