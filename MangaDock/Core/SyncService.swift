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

    static func syncURL(baseURL: URL) -> URL {
        baseURL.appendingPathComponent(fileName)
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
        guard isEnabled, let client = store.makeClient(),
              let base = store.baseURL else { return }
        let payload = payload(store: store, shelf: shelf)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        do {
            try await client.upload(data, to: syncURL(baseURL: base))
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
        guard let client = store.makeClient(), let base = store.baseURL else {
            return "还没有配置服务器"
        }
        let payload = payload(store: store, shelf: shelf)
        guard let data = try? JSONEncoder().encode(payload) else {
            return "本地数据打包失败"
        }
        do {
            try await client.upload(data, to: syncURL(baseURL: base))
            UserDefaults.standard.set(payload.updatedAt, forKey: updatedAtKey)
            UserDefaults.standard.set(Date(), forKey: lastSyncKey)
            return "已上传：书架 \(shelf.count) 本 · 进度 \(store.recent.count) 条"
        } catch {
            return "上传失败：\(NetErrorText.friendly(error))"
        }
    }

    /// Manual download: the server copy replaces local state unconditionally —
    /// the user asked for it explicitly, so "last write wins" must not veto it.
    static func pullNow(store: AppStore, shelfStore: ShelfStore) async -> String {
        guard let client = store.makeClient(), let base = store.baseURL else {
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
        guard remote.serverURL == store.serverURL else {
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
        guard isEnabled, let client = store.makeClient(),
              let base = store.baseURL else { return false }

        guard let data = try? await client.data(for: syncURL(baseURL: base)),
              let remote = try? JSONDecoder().decode(SyncPayload.self, from: data) else {
            return false
        }

        // Only merge the same server config — never clobber a different server.
        guard remote.serverURL == store.serverURL else { return false }

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
        func setStr(_ key: String, _ value: String?) {
            if let value { d.set(value, forKey: key) } else { d.removeObject(forKey: key) }
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
