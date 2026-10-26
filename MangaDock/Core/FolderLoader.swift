import Foundation
import SwiftUI

@MainActor
final class FolderLoader: ObservableObject {
    @Published var items: [WebDAVItem] = []
    @Published var isLoading = true
    @Published var errorMessage: String?

    /// 进程内的目录缓存。章节列表不会一秒一变，但 WebDAV 的 PROPFIND
    /// 在几百章的目录上要等一两秒 —— 每次进页面都干等就是这么来的。
    /// 命中缓存先秒开，同时后台刷新，刷新完无感替换。
    private static var cache: [String: [WebDAVItem]] = [:]
    private static var order: [String] = []
    private static let cacheLimit = 30

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
        let cached = Self.cache[key]

        if let cached, !cached.isEmpty {
            // 有缓存：立刻显示，不出现「正在读取章节」
            items = cached
            isLoading = false
            errorMessage = nil
        } else {
            isLoading = true
            errorMessage = nil
        }

        do {
            let fresh = try await client.list(url)
            items = fresh
            Self.remember(key, fresh)
            isLoading = false
        } catch {
            isLoading = false
            // 有缓存就保留内容（离线也能翻列表），没有才报错
            if cached == nil {
                errorMessage = NetErrorText.friendly(error)
            }
        }
    }

    /// 手动刷新（下拉）时强制走后端，但仍保留旧内容直到拿到新数据。
    func refresh(url: URL?, client: WebDAVClient?) async {
        await load(url: url, client: client)
    }

    /// 目录内容变了（比如刚下载完某章）时手动让缓存失效。
    static func invalidate(url: URL?) {
        guard let url else { return }
        let key = url.absoluteString
        cache.removeValue(forKey: key)
        order.removeAll { $0 == key }
    }

    private static func remember(_ key: String, _ items: [WebDAVItem]) {
        cache[key] = items
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > cacheLimit {
            let oldest = order.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }
}
