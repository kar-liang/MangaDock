import Foundation

/// Multi-device sync via a single JSON file on the WebDAV server.
///
/// iCloud/CloudKit needs a signed developer entitlement (unavailable for
/// sideloaded IPAs), so progress, shelf, and settings sync through the user's
/// own WebDAV server instead. Last-write-wins, compared by `updatedAt`.
struct SyncSettings: Codable, Equatable {
    var appearance: String?
    var readerMode: String?
    var defaultLayout: String?
    var enhance: Bool?
    var tabShelf: Bool?
    var tabFiles: Bool?
    var tabHistory: Bool?
    var aiScale: Int?
}

struct SyncPayload: Codable {
    var serverURL: String
    var username: String
    var recent: [RecentEntry]
    var shelf: [ShelfEntry]
    var settings: SyncSettings
    var updatedAt: Date
}

@MainActor
enum SyncService {
    static let fileName = ".mangadock-sync.json"

    static let enabledKey = "mangadock.syncEnabled"
    static let lastSyncKey = "mangadock.sync.lastSync"
    /// Timestamp of the payload this device last pushed or applied — the basis
    /// for last-write-wins on automatic pulls.
    static let updatedAtKey = "mangadock.sync.updatedAt"

    /// Defaults to ON until the user turns it off explicitly.
    static var isEnabled: Bool {
        let d = UserDefaults.standard
        if d.object(forKey: enabledKey) == nil { return true }
        return d.bool(forKey: enabledKey)
    }

    static var lastSyncDate: Date? {
        UserDefaults.standard.object(forKey: lastSyncKey) as? Date
    }

    /// 同步目录（相对 WebDAV 根）。留空 = 根目录，和 Android 的 `syncDir` 是同一个键。
    static let folderKey = "mangadock.sync.folder"

    static var folder: String {
        (UserDefaults.standard.string(forKey: folderKey) ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    }

    /// 同步文件的位置。两端（iOS / Android）都按「目录 + 固定文件名」拼，
    /// 所以只要目录填成一样，写的就是同一个文件。
    static func syncURL(baseURL: URL) -> URL {
        var url = baseURL
        for comp in folder.split(separator: "/") where !comp.isEmpty {
            url.appendPathComponent(String(comp), isDirectory: true)
        }
        return url.appendingPathComponent(fileName)
    }

    /// 让同步目录存在。自定义目录可能是多级的，逐级 MKCOL；
    /// 已存在的那一层服务器会回 405，`makeCollection` 内部当成功处理。
    /// 不做这一步的话，PUT 到不存在的集合会直接 409。
    static func ensureFolder(client: RemoteClient, baseURL: URL) async {
        guard !folder.isEmpty, let webdav = client as? WebDAVClient else { return }
        var url = baseURL
        for comp in folder.split(separator: "/") where !comp.isEmpty {
            url.appendPathComponent(String(comp), isDirectory: true)
            try? await webdav.makeCollection(url)
        }
    }

    /// 比较服务器地址时忽略尾部斜杠和大小写 —— 换个写法不该被当成"另一个服务器"。
    private static func normalizeServer(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // 协议也去掉：一台设备填 http:// 另一台漏了，不该被当成"另一个服务器"
        for prefix in ["http://", "https://"] where t.hasPrefix(prefix) {
            t.removeFirst(prefix.count)
            break
        }
        while t.hasSuffix("/") && t.count > 4 { t.removeLast() }
        return t
    }

    // MARK: - Snapshot

    static func currentSettings() -> SyncSettings {
        let d = UserDefaults.standard
        return SyncSettings(
            appearance: d.string(forKey: "mangadock.appearance"),
            readerMode: d.string(forKey: "mangadock.readerMode"),
            defaultLayout: d.string(forKey: "mangadock.defaultLayout"),
            enhance: d.object(forKey: "mangadock.enhance") as? Bool,
            tabShelf: d.object(forKey: "mangadock.tab.shelf") as? Bool,
            tabFiles: d.object(forKey: "mangadock.tab.files") as? Bool,
            tabHistory: d.object(forKey: "mangadock.tab.history") as? Bool,
            aiScale: d.integer(forKey: "mangadock.aiScale")
        )
    }

    static func payload(store: AppStore, shelf: [ShelfEntry]) -> SyncPayload {
        SyncPayload(
            serverURL: store.serverURL,
            username: store.username,
            recent: store.recent,
            shelf: shelf,
            settings: currentSettings(),
            updatedAt: Date()
        )
    }

    // MARK: - Push / pull

    static func push(store: AppStore, shelf: [ShelfEntry]) async {
        guard isEnabled, let client = store.client(for: .webdav) as? WebDAVClient,
              let base = store.baseURL(for: .webdav) else { return }
        let payload = payload(store: store, shelf: shelf)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        await ensureFolder(client: client, baseURL: base)
        do {
            let target = syncURL(baseURL: base)
            let body = await carryingForeignSections(data, client: client, from: target)
            try await client.upload(body, to: target)
            // Remember what we just wrote, otherwise the next automatic pull
            // would treat our own payload as "older" and could overwrite it.
            UserDefaults.standard.set(payload.updatedAt, forKey: updatedAtKey)
            UserDefaults.standard.set(Date(), forKey: lastSyncKey)
        } catch {
            // Non-fatal: next change retries.
        }
    }

    /// Manual upload: this device's state replaces the copy on the server, no
    /// timestamp comparison. Returns a one-line result for the settings UI.
    static func pushNow(store: AppStore, shelf: [ShelfEntry]) async -> String {
        guard let client = store.client(for: .webdav) as? WebDAVClient, let base = store.baseURL(for: .webdav) else {
            return "还没有配置服务器"
        }
        let payload = payload(store: store, shelf: shelf)
        guard let data = try? JSONEncoder().encode(payload) else {
            return "本地数据打包失败"
        }
        await ensureFolder(client: client, baseURL: base)
        do {
            let target = syncURL(baseURL: base)
            let body = await carryingForeignSections(data, client: client, from: target)
            try await client.upload(body, to: target)
            UserDefaults.standard.set(payload.updatedAt, forKey: updatedAtKey)
            UserDefaults.standard.set(Date(), forKey: lastSyncKey)
            return "已上传：书架 \(shelf.count) 本 · 进度 \(store.recent.count) 条"
        } catch {
            return "上传失败：\(NetErrorText.friendly(error))"
        }
    }

    /// 把文件里**别的客户端**写的那几段原样搬回来。
    ///
    /// Android 把它的设置放在顶层的 `android` 对象里（Android 用整型下标、
    /// iOS 用枚举字符串，语义对不上，所以各存各的、谁也不解释谁）。麻烦在于
    /// 本端打包时只会写自己认识的键 —— 不搬的话，每次 iOS 上传都会把 Android
    /// 那段整个抹掉，用户看到的是"在 Android 上改的设置没了"。
    ///
    /// 读不到（第一次同步 / 断网）就原样返回，绝不能因此挡住上传。
    private static func carryingForeignSections(
        _ data: Data,
        client: WebDAVClient,
        from url: URL
    ) async -> Data {
        guard let old = try? await client.data(for: url),
              let oldObj = (try? JSONSerialization.jsonObject(with: old)) as? [String: Any],
              let foreign = oldObj["android"],
              var newObj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return data }
        newObj["android"] = foreign
        return (try? JSONSerialization.data(withJSONObject: newObj)) ?? data
    }

    /// Manual download: the server copy replaces local state unconditionally —
    /// the user asked for it explicitly, so "last write wins" must not veto it.
    static func pullNow(store: AppStore, shelfStore: ShelfStore) async -> String {
        guard let client = store.client(for: .webdav) as? WebDAVClient, let base = store.baseURL(for: .webdav) else {
            return "还没有配置服务器"
        }

        let data: Data
        do {
            data = try await client.data(for: syncURL(baseURL: base))
        } catch WebDAVError.badStatus(404) {
            return "服务器上还没有同步文件，先点「上传同步」"
        } catch {
            return "下载失败：\(NetErrorText.friendly(error))"
        }

        guard let remote = try? JSONDecoder().decode(SyncPayload.self, from: data) else {
            return "服务器上的同步文件读不出来（可能已损坏）"
        }
        guard normalizeServer(remote.serverURL) == normalizeServer(store.serverURL) else {
            return "这份数据来自另一个服务器（\(remote.serverURL)），已拒绝覆盖"
        }

        apply(remote, store: store, shelfStore: shelfStore)
        UserDefaults.standard.set(remote.updatedAt, forKey: updatedAtKey)
        UserDefaults.standard.set(Date(), forKey: lastSyncKey)
        let stamp = remote.updatedAt.formatted(date: .abbreviated, time: .shortened)
        return "已下载（云端 \(stamp)）：书架 \(remote.shelf.count) 本 · 进度 \(remote.recent.count) 条"
    }

    /// Fetches the remote payload and applies it if it's newer than local.
    /// Returns true when remote state was applied.
    @discardableResult
    static func pull(store: AppStore, shelfStore: ShelfStore) async -> Bool {
        guard isEnabled, let client = store.client(for: .webdav) as? WebDAVClient,
              let base = store.baseURL(for: .webdav) else { return false }

        guard let data = try? await client.data(for: syncURL(baseURL: base)),
              let remote = try? JSONDecoder().decode(SyncPayload.self, from: data) else {
            return false
        }

        // Only merge the same server config — never clobber a different server.
        guard normalizeServer(remote.serverURL) == normalizeServer(store.serverURL) else { return false }

        // Last-write-wins.
        let localUpdated = UserDefaults.standard.object(forKey: updatedAtKey) as? Date ?? .distantPast
        guard remote.updatedAt > localUpdated else { return false }

        apply(remote, store: store, shelfStore: shelfStore)
        UserDefaults.standard.set(remote.updatedAt, forKey: updatedAtKey)
        UserDefaults.standard.set(Date(), forKey: lastSyncKey)
        return true
    }

    private static func apply(_ remote: SyncPayload, store: AppStore, shelfStore: ShelfStore) {
        // Progress.
        store.replaceRecent(remote.recent)
        // Shelf.
        shelfStore.replaceEntries(remote.shelf)
        // Settings.
        applySettings(remote.settings)
    }

    private static func applySettings(_ s: SyncSettings) {
        let d = UserDefaults.standard
        // 只写不改：nil 表示"这份 payload 没带这个设置"，**不是**"把它删掉"。
        //
        // 这里原本是 nil 就 removeObject，和 Android 端一组合就出事：Android 的
        // 设置语义完全不同（整型下标 vs 这里的枚举字符串），所以它按约定每次都写
        // 一个空的 `settings: {}`。以前那种写法意味着 Android 只要上传一次，
        // iOS 拉回来就会把自己的外观 / 翻页 / 默认布局三项清空，用户看到的是
        // "换个手机读一下，我的设置没了"。
        func setStr(_ key: String, _ value: String?) {
            if let value { d.set(value, forKey: key) }
        }
        setStr("mangadock.appearance", s.appearance)
        setStr("mangadock.readerMode", s.readerMode)
        setStr("mangadock.defaultLayout", s.defaultLayout)
        if let enhance = s.enhance { d.set(enhance, forKey: "mangadock.enhance") }
        if let tabShelf = s.tabShelf { d.set(tabShelf, forKey: "mangadock.tab.shelf") }
        if let tabFiles = s.tabFiles { d.set(tabFiles, forKey: "mangadock.tab.files") }
        if let tabHistory = s.tabHistory { d.set(tabHistory, forKey: "mangadock.tab.history") }
        if let aiScale = s.aiScale { d.set(aiScale, forKey: "mangadock.aiScale") }
    }
}
