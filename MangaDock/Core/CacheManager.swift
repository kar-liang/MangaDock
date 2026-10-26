import Foundation
import CryptoKit

/// One user-chosen cover. Needed because the file name is a hash — without this
/// manifest there's no way to know which comic a cached cover belongs to, and
/// no way to sync them across devices.
struct CustomCoverEntry: Codable, Hashable, Identifiable {
    /// Full WebDAV URL of the comic (`WebDAVItem.id`).
    var itemID: String
    /// sha256 hex of `itemID` — the file name on disk and on the server.
    var hash: String
    var updatedAt: Date

    var id: String { hash }
}

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

    /// Marks the cover as user-chosen so we don't silently regenerate it.
    static func manualCoverMarker(key: String) -> URL {
        ensure(coversDirectory)
        return coversDirectory.appendingPathComponent(hash(key) + ".manual")
    }

    static func hasManualCover(key: String) -> Bool {
        FileManager.default.fileExists(atPath: manualCoverMarker(key: key).path)
    }

    static func markManualCover(key: String) {
        try? Data().write(to: manualCoverMarker(key: key))
    }

    static func deleteCover(key: String) {
        try? FileManager.default.removeItem(at: coverURL(key: key))
        try? FileManager.default.removeItem(at: manualCoverMarker(key: key))
    }

    // MARK: - Custom cover manifest

    /// Lists the user's own covers so they can be kept across a cache wipe and
    /// synced to other devices.
    static func customCoverManifestURL() -> URL {
        ensure(coversDirectory)
        return coversDirectory.appendingPathComponent("manifest.json")
    }

    static func loadCustomCoverManifest() -> [CustomCoverEntry] {
        guard let data = try? Data(contentsOf: customCoverManifestURL()),
              let list = try? JSONDecoder().decode([CustomCoverEntry].self, from: data) else {
            return []
        }
        return list
    }

    static func saveCustomCoverManifest(_ list: [CustomCoverEntry]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: customCoverManifestURL(), options: .atomic)
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

    /// Wipes generated cache (archives, loose pages, auto covers).
    ///
    /// User-chosen covers survive: they can't be regenerated, so treating them
    /// as cache silently destroyed work. They get staged out and moved back.
    static func clear() {
        let custom = loadCustomCoverManifest()
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("mangadock-keep-covers", isDirectory: true)
        try? FileManager.default.removeItem(at: staging)
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        for entry in custom {
            let source = coverURL(key: entry.itemID)
            let staged = staging.appendingPathComponent(source.lastPathComponent)
            try? FileManager.default.moveItem(at: source, to: staged)
        }

        try? FileManager.default.removeItem(at: root)
        ensure(booksDirectory)
        ensure(pagesDirectory)
        ensure(coversDirectory)

        for entry in custom {
            let destination = coverURL(key: entry.itemID)
            let staged = staging.appendingPathComponent(destination.lastPathComponent)
            guard FileManager.default.fileExists(atPath: staged.path) else { continue }
            try? FileManager.default.moveItem(at: staged, to: destination)
            markManualCover(key: entry.itemID)
        }
        saveCustomCoverManifest(custom)
        try? FileManager.default.removeItem(at: staging)
    }

    static func removeArchive(for url: URL) {
        try? FileManager.default.removeItem(at: archiveURL(for: url))
    }
}
