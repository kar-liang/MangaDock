import Foundation
import SwiftUI

@MainActor
final class FolderLoader: ObservableObject {
    @Published var items: [WebDAVItem] = []
    @Published var isLoading = true
    @Published var errorMessage: String?

    /// 目录列表两级缓存：内存 → 磁盘 → 网络。
    ///
    /// WebDAV 的 PROPFIND 在几百章的目录上要等一两秒，而章节列表几乎不变。
    /// 所以：能读到旧的就立刻显示，同时后台刷新，刷新完无感替换。
    /// 磁盘那层是为了让**冷启动**也不用等。
    private static var cache: [String: [WebDAVItem]] = [:]
    private static var order: [String] = []
    private static let memoryLimit = 30
    private static let diskLimit = 30

    var imageCount: Int {
        items.filter { !$0.isDirectory && $0.isImage }.count
    }

    func load(url: URL?, client: WebDAVClient?) async {
        guard let url, let client else {
            isLoading = false
            errorMessage = "还没有配置服务器"
            return
        }

        let key = url.absoluteString

        // 1) 内存 → 2) 磁盘
        var cached = Self.cache[key]
        if cached == nil {
            cached = Self.readDisk(key)
            if let cached, !cached.isEmpty {
                Self.cache[key] = cached
                Self.touch(key)
            }
        }

        if let cached, !cached.isEmpty {
            items = cached
            isLoading = false
            errorMessage = nil
        } else {
            isLoading = true
            errorMessage = nil
        }

        // 3) 网络刷新（无论有没有缓存都要刷，新章节才能出来）
        do {
            let fresh = try await client.list(url)
            items = fresh
            Self.remember(key, fresh)
            Self.writeDisk(key, fresh)
            isLoading = false
        } catch {
            isLoading = false
            // 有缓存就留着内容（离线也能翻），没有才报错
            if cached == nil {
                errorMessage = NetErrorText.friendly(error)
            }
        }
    }

    /// 目录内容变了时让缓存失效（内存 + 磁盘）。
    static func invalidate(url: URL?) {
        guard let url else { return }
        let key = url.absoluteString
        cache.removeValue(forKey: key)
        order.removeAll { $0 == key }
        try? FileManager.default.removeItem(at: diskURL(for: key))
    }

    /// 清掉所有目录磁盘缓存。
    static func clearDiskCache() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: diskFolder,
                                                     includingPropertiesForKeys: nil) else { return }
        for file in files { try? fm.removeItem(at: file) }
        cache.removeAll()
        order.removeAll()
    }

    // MARK: Memory

    private static func remember(_ key: String, _ items: [WebDAVItem]) {
        cache[key] = items
        touch(key)
        while order.count > memoryLimit {
            cache.removeValue(forKey: order.removeFirst())
        }
    }

    private static func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    // MARK: Disk

    private static var diskFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        let folder = base.appendingPathComponent("folder-cache", isDirectory: true)
        if !FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder
    }

    /// 稳定文件名。不能用 String.hashValue —— 它每个进程带随机种子。
    private static func diskURL(for key: String) -> URL {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return diskFolder.appendingPathComponent(String(hash, radix: 16) + ".json")
    }

    private static func readDisk(_ key: String) -> [WebDAVItem]? {
        guard let data = try? Data(contentsOf: diskURL(for: key)) else { return nil }
        return try? JSONDecoder().decode([WebDAVItem].self, from: data)
    }

    private static func writeDisk(_ key: String, _ items: [WebDAVItem]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: diskURL(for: key), options: .atomic)
        pruneDisk()
    }

    /// 只保留最近写过的若干个目录，别让缓存无限长。
    private static func pruneDisk() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: diskFolder,
            includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        guard files.count > diskLimit else { return }

        let sorted = files.sorted { lhs, rhs in
            let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            return l < r
        }
        for file in sorted.prefix(files.count - diskLimit) {
            try? fm.removeItem(at: file)
        }
    }
}
