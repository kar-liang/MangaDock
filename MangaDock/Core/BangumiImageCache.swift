import SwiftUI
import UIKit

/// Bangumi 图片的本地缓存（内存 + 磁盘）。
///
/// 之前用 `AsyncImage`，它只走 URLSession 的共享缓存，封面和角色头像
/// 每次进系列页都要重新下载，所以会闪一下灰块。这里自己管：
/// 内存 → 磁盘 → 网络，同样的图第二次进来直接命中。
@MainActor
final class BangumiImageCache {
    static let shared = BangumiImageCache()

    private var memory: [String: UIImage] = [:]
    private var inFlight: Set<String> = []
    private let folder: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        folder = base.appendingPathComponent("bangumi/img", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// 同步取：内存 → 磁盘。命中就直接画，不会闪。
    func cached(_ url: URL) -> UIImage? {
        let key = url.absoluteString
        if let image = memory[key] { return image }
        guard let data = try? Data(contentsOf: file(for: url)),
              let image = UIImage(data: data) else { return nil }
        memory[key] = image
        return image
    }

    func load(_ url: URL) async -> UIImage? {
        if let image = cached(url) { return image }

        let key = url.absoluteString
        guard !inFlight.contains(key) else { return nil }
        inFlight.insert(key)
        defer { inFlight.remove(key) }

        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .returnCacheDataElseLoad

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let image = UIImage(data: data) else { return nil }

        memory[key] = image
        if let compressed = image.jpegData(compressionQuality: 0.85) {
            try? compressed.write(to: file(for: url), options: .atomic)
        }
        return image
    }

    func clear() {
        memory.removeAll()
        let files = (try? FileManager.default.contentsOfDirectory(at: folder,
                                                                 includingPropertiesForKeys: nil)) ?? []
        for file in files { try? FileManager.default.removeItem(at: file) }
    }

    // MARK: Storage

    /// 稳定的文件名。**不能用 String.hashValue** —— 它在每个进程里带随机种子，
    /// 冷启动后算出来的名字会变，等于缓存全废。
    private func file(for url: URL) -> URL {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in url.absoluteString.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return folder.appendingPathComponent(String(hash, radix: 16))
    }

    private static var userAgent: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "MangaDock/\(version) (https://github.com/kar-liang/MangaDock)"
    }
}

/// 带磁盘缓存的图片。替代 `AsyncImage`，避免每次进来都闪灰块。
struct CachedAsyncImage<Placeholder: View>: View {
    let url: URL?
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable()
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }
            // 先同步查缓存，有就直接上，不留空白
            if let hit = BangumiImageCache.shared.cached(url) {
                image = hit
                return
            }
            image = await BangumiImageCache.shared.load(url)
        }
    }
}
