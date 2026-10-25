import Foundation
import SwiftUI

/// One chapter kept on disk for offline reading.
struct DownloadedChapter: Codable, Identifiable, Hashable {
    /// WebDAV URL it came from — also the identity used everywhere else.
    var sourceURLString: String
    /// Original file/folder name, extension included (used to rebuild items).
    var name: String
    /// Name shown in the UI (no extension).
    var title: String
    /// Sub-directory under `DownloadStore.root`.
    var folderName: String
    /// true = single archive/PDF file, false = folder of images.
    var isArchive: Bool
    /// Archive file name inside `folderName` (nil for image folders).
    var fileName: String?
    var pageCount: Int
    var bytes: Int64
    var downloadedAt: Date

    var id: String { sourceURLString }

    var sourceURL: URL? { URL(string: sourceURLString) }

    /// Rebuilds a `WebDAVItem` standing in for the remote file. Fidelity is
    /// enough for navigation, sorting and opening (the reader resolves
    /// downloaded chapters by URL, not by these fields).
    var item: WebDAVItem? {
        guard let url = sourceURL else { return nil }
        return WebDAVItem(url: url, name: name, isDirectory: !isArchive,
                          size: bytes, modified: downloadedAt)
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Download state for one chapter, as shown in the chapter list.
enum DownloadState: Equatable {
    case none
    case queued
    case downloading(Double)
    case done
}

/// Offline downloads: whole series or single chapters, kept under
/// Application Support (NOT Documents → stays out of the Files app and out of
/// iCloud backup) so they survive restarts but don't bloat backups.
///
/// Reading is offline-first: `ReaderModel` asks this store for a local source
/// before touching the network.
///
/// NOT `@MainActor` on purpose: views need `DownloadStore.shared` in a stored
/// property initializer (`@ObservedObject`), which is a nonisolated context —
/// a main-actor-isolated singleton would not compile there. The methods that
/// mutate published state are marked `@MainActor` individually instead, so all
/// UI-visible writes still happen on the main thread.
final class DownloadStore: ObservableObject {
    static let shared = DownloadStore()

    /// Every finished download, newest state persisted in UserDefaults.
    @Published private(set) var records: [DownloadedChapter] = []
    /// 0…1 for chapters currently downloading, keyed by source URL string.
    @Published private(set) var progress: [String: Double] = [:]
    /// Source URL strings still waiting or in flight (first = current).
    @Published private(set) var queue: [String] = []
    /// Title of the chapter being downloaded right now.
    @Published private(set) var activeTitle: String?
    /// Last failure, shown as a one-liner in the chapter list.
    @Published private(set) var lastError: String?

    private static let defaultsKey = "mangadock.downloads"

    private var worker: Task<Void, Never>?
    private var jobs: [(item: WebDAVItem, client: WebDAVClient)] = []

    private init() {
        records = Self.loadRecords()
        Self.ensureRoot()
    }

    // MARK: - Storage

    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
        return base.appendingPathComponent("Downloads", isDirectory: true)
    }

    private static func ensureRoot() {
        let url = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try? mutable.setResourceValues(values)
    }

    private static func loadRecords() -> [DownloadedChapter] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let list = try? JSONDecoder().decode([DownloadedChapter].self, from: data) else {
            return []
        }
        return list
    }

    private func saveRecords() {
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    // MARK: - Queries

    func record(for url: URL) -> DownloadedChapter? {
        records.first { $0.sourceURLString == url.absoluteString }
    }

    func isDownloaded(_ url: URL) -> Bool {
        record(for: url) != nil
    }

    func state(for url: URL) -> DownloadState {
        let key = url.absoluteString
        if records.contains(where: { $0.sourceURLString == key }) { return .done }
        if let value = progress[key] { return .downloading(value) }
        if queue.contains(key) { return .queued }
        return .none
    }

    var totalBytes: Int64 {
        records.reduce(0) { $0 + $1.bytes }
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    var isBusy: Bool { !queue.isEmpty }

    /// Downloaded chapters in the same remote folder — lets the reader keep
    /// offering chapter-to-chapter switching with no network at all.
    func downloadedSiblings(of item: WebDAVItem) -> [WebDAVItem] {
        downloadedChapters(inFolder: item.url).compactMap { $0.item }
    }

    /// Downloaded chapters that live in `folderURL`. Used as the offline
    /// fallback when the folder itself can't be listed.
    func downloadedChapters(inFolder folderURL: URL) -> [DownloadedChapter] {
        let key = Self.folderKey(folderURL)
        return records
            .filter { rec in
                guard let url = rec.sourceURL else { return false }
                return Self.parentKey(of: url) == key
            }
            .sorted { NaturalSort.less($0.name, $1.name) }
    }

    /// A local page source for a downloaded chapter, or nil if it isn't one.
    func localSource(for url: URL) async -> ComicPageSource? {
        guard let rec = record(for: url) else { return nil }
        let dir = Self.root.appendingPathComponent(rec.folderName, isDirectory: true)
        let isArchive = rec.isArchive
        let fileName = rec.fileName
        let isPDF = fileName.map { ($0 as NSString).pathExtension.lowercased() == "pdf" } ?? false

        return await Task.detached(priority: .userInitiated) { () -> ComicPageSource? in
            if isArchive {
                guard let fileName else { return nil }
                let fileURL = dir.appendingPathComponent(fileName)
                guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
                if isPDF { return try? PDFComicSource(fileURL: fileURL) }
                return try? ZipComicSource(fileURL: fileURL)
            }
            return try? LocalFolderComicSource(
                directory: dir.appendingPathComponent("pages", isDirectory: true)
            )
        }.value
    }

    // MARK: - Queueing

    /// Adds chapters to the download queue (skips ones already downloaded or
    /// already queued) and starts the worker.
    func enqueue(_ items: [WebDAVItem], client: WebDAVClient) {
        var added = false
        for item in items {
            let key = item.url.absoluteString
            if records.contains(where: { $0.sourceURLString == key }) { continue }
            if queue.contains(key) { continue }
            jobs.append((item, client))
            queue.append(key)
            added = true
        }
        guard added else { return }
        lastError = nil
        startWorkerIfNeeded()
    }

    /// Drops everything queued and aborts the chapter in flight. The worker
    /// task is left alive to unwind (it clears itself in `runQueue`), which
    /// also stops a half-cancelled run from being joined by a second worker.
    func cancelAll() {
        worker?.cancel()
        jobs.removeAll()
        queue.removeAll()
        progress.removeAll()
        activeTitle = nil
    }

    /// Cancels one chapter — a queued one is dropped silently, the one in
    /// flight aborts the run (there's only ever one download at a time).
    /// Calling this for a chapter that isn't downloading does nothing, so
    /// deleting an already-finished chapter can't kill an unrelated queue.
    func cancel(_ url: URL) {
        let key = url.absoluteString
        if let index = jobs.firstIndex(where: { $0.item.url.absoluteString == key }) {
            jobs.remove(at: index)
            queue.removeAll { $0 == key }
            progress[key] = nil
            return
        }
        // The running chapter is the head of the queue (`runQueue` removes the
        // job but leaves the key in `queue` until it finishes).
        if queue.first == key { cancelAll() }
    }

    // MARK: - Deleting

    func remove(_ url: URL) {
        cancel(url)
        guard let rec = record(for: url) else { return }
        try? FileManager.default.removeItem(
            at: Self.root.appendingPathComponent(rec.folderName, isDirectory: true)
        )
        records.removeAll { $0.sourceURLString == rec.sourceURLString }
        saveRecords()
    }

    func removeAll() {
        cancelAll()
        try? FileManager.default.removeItem(at: Self.root)
        Self.ensureRoot()
        records = []
        saveRecords()
    }

    // MARK: - Worker

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        worker = Task { @MainActor [weak self] in
            await self?.runQueue()
        }
    }

    @MainActor
    private func runQueue() async {
        while !jobs.isEmpty {
            let job = jobs.removeFirst()
            let key = job.item.url.absoluteString

            activeTitle = job.item.displayName
            progress[key] = 0

            do {
                let rec = try await downloadOne(item: job.item, client: job.client)
                records.removeAll { $0.sourceURLString == key }
                records.append(rec)
                records.sort { NaturalSort.less($0.name, $1.name) }
                saveRecords()
            } catch {
                progress[key] = nil
                queue.removeAll { $0 == key }
                if Task.isCancelled || error is CancellationError { break }
                lastError = "「\(job.item.displayName)」下载失败：\(NetErrorText.friendly(error))"
            }

            progress[key] = nil
            queue.removeAll { $0 == key }
        }

        activeTitle = nil
        worker = nil
        // Jobs queued while the previous run was winding down.
        if !jobs.isEmpty { startWorkerIfNeeded() }
    }

    /// Downloads one chapter into its own folder and returns the record.
    /// `@MainActor` so `progress` updates are safe; the actual byte shuffling
    /// all happens inside awaited network calls and detached writes.
    @MainActor
    private func downloadOne(item: WebDAVItem, client: WebDAVClient) async throws -> DownloadedChapter {
        let key = item.url.absoluteString
        let folderName = CacheManager.hash(key)
        let dir = Self.root.appendingPathComponent(folderName, isDirectory: true)

        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        if item.isArchive || item.isPDF {
            let ext = item.fileExtension.isEmpty ? "bin" : item.fileExtension
            let fileName = "book." + ext
            let destination = dir.appendingPathComponent(fileName)

            // Reuse a copy already sitting in the page cache instead of
            // pulling the same bytes down twice.
            var reusedCache = false
            if CacheManager.hasArchive(for: item.url) {
                do {
                    try FileManager.default.copyItem(at: CacheManager.archiveURL(for: item.url),
                                                     to: destination)
                    reusedCache = true
                    progress[key] = 1
                    // The download is now the durable copy; drop the cache one
                    // so a 500 MB series isn't stored twice.
                    CacheManager.removeArchive(for: item.url)
                } catch {
                    reusedCache = false
                }
            }
            if !reusedCache {
                try await client.download(item.url, to: destination) { [weak self] value in
                    Task { @MainActor [weak self] in
                        self?.progress[key] = value
                    }
                }
            }
            try Task.checkCancellation()

            let pages = await Self.countPages(fileURL: destination, isPDF: item.isPDF)
            guard pages > 0 else { throw ZipError.unsupported("这个文件里没有可显示的页面") }

            return DownloadedChapter(sourceURLString: key,
                                     name: item.name,
                                     title: item.displayName,
                                     folderName: folderName,
                                     isArchive: true,
                                     fileName: fileName,
                                     pageCount: pages,
                                     bytes: Self.fileSize(destination),
                                     downloadedAt: Date())
        }

        // Folder-of-images chapter: grab every page.
        let children = try await client.list(item.requestURL)
        let images = children
            .filter { !$0.isDirectory && $0.isImage }
            .sorted { NaturalSort.less($0.name, $1.name) }
        guard !images.isEmpty else {
            throw ZipError.unsupported("这个文件夹里没有图片")
        }

        let pagesDir = dir.appendingPathComponent("pages", isDirectory: true)
        try FileManager.default.createDirectory(at: pagesDir, withIntermediateDirectories: true)

        var totalBytes: Int64 = 0
        for (index, image) in images.enumerated() {
            try Task.checkCancellation()

            let data: Data
            if let cached = CacheManager.pageData(for: image.url) {
                data = cached
            } else {
                // Deliberately NOT stored in the page cache: the durable copy
                // below is what gets read (offline-first), so caching it too
                // would just double the disk cost of every downloaded series.
                data = try await client.data(for: image.url)
            }

            let ext = image.fileExtension.isEmpty ? "jpg" : image.fileExtension
            let name = String(format: "%04d", index + 1) + "." + ext
            let destination = pagesDir.appendingPathComponent(name)
            try await Task.detached(priority: .utility) { () throws -> Void in
                try data.write(to: destination, options: .atomic)
            }.value

            totalBytes += Int64(data.count)
            progress[key] = Double(index + 1) / Double(images.count)
        }

        return DownloadedChapter(sourceURLString: key,
                                 name: item.name,
                                 title: item.displayName,
                                 folderName: folderName,
                                 isArchive: false,
                                 fileName: nil,
                                 pageCount: images.count,
                                 bytes: totalBytes,
                                 downloadedAt: Date())
    }

    // MARK: - Helpers

    private static func countPages(fileURL: URL, isPDF: Bool) async -> Int {
        await Task.detached(priority: .userInitiated) { () -> Int in
            if isPDF { return (try? PDFComicSource(fileURL: fileURL))?.pageCount ?? 0 }
            return (try? ZipComicSource(fileURL: fileURL))?.pageCount ?? 0
        }.value
    }

    private static func fileSize(_ url: URL) -> Int64 {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return 0 }
        return Int64(size)
    }

    /// Folder a chapter lives in, as a comparable string.
    private static func parentKey(of url: URL) -> String? {
        var text = url.absoluteString
        while text.hasSuffix("/") && text.count > 8 { text.removeLast() }
        guard let clean = URL(string: text) else { return nil }
        return clean.deletingLastPathComponent().absoluteString
    }

    /// Same shape as `parentKey`'s output (trailing slash included).
    private static func folderKey(_ url: URL) -> String {
        var text = url.absoluteString
        while text.hasSuffix("/") && text.count > 8 { text.removeLast() }
        return text + "/"
    }
}
