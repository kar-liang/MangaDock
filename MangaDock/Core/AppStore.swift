import Foundation
import SwiftUI

@MainActor
final class AppStore: ObservableObject {
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let serverURL = "mangadock.serverURL"
        static let username = "mangadock.username"
        static let recent = "mangadock.recent"
    }

    @Published var serverURL: String
    @Published var username: String
    @Published var password: String
    @Published var recent: [RecentEntry]

    init() {
        serverURL = defaults.string(forKey: Keys.serverURL) ?? ""
        username = defaults.string(forKey: Keys.username) ?? ""
        password = Keychain.load(account: "webdav") ?? ""
        if let data = defaults.data(forKey: Keys.recent),
           let list = try? JSONDecoder().decode([RecentEntry].self, from: data) {
            recent = list
        } else {
            recent = []
        }

        // Shelf changes (add/remove) trigger a debounced sync push.
        NotificationCenter.default.addObserver(
            forName: .shelfDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleSyncPush()
            }
        }
    }

    // MARK: - Sync

    private var syncTask: Task<Void, Never>?

    /// Debounced push so rapid page turns don't spam the server.
    func scheduleSyncPush() {
        guard isConfigured else { return }
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self else { return }
            await SyncService.push(store: self, shelf: ShelfStore.shared.entries)
        }
    }

    func pullSync() async {
        guard isConfigured else { return }
        _ = await SyncService.pull(store: self, shelfStore: ShelfStore.shared)
    }

    /// Manual "上传同步": local state replaces the server copy.
    /// Covers ride along as separate image files (see `CoverSyncService`).
    func uploadSync() async -> String {
        guard isConfigured else { return "还没有配置服务器" }
        var parts: [String] = []
        parts.append(await SyncService.pushNow(store: self, shelf: ShelfStore.shared.entries))
        if let coverNote = await CoverSyncService.push(store: self) {
            parts.append(coverNote)
        }
        return parts.joined(separator: "；")
    }

    /// Manual "下载同步": the server copy replaces local state (explicit user
    /// choice, so no last-write-wins veto).
    func downloadSync() async -> String {
        guard isConfigured else { return "还没有配置服务器" }
        var parts: [String] = []
        parts.append(await SyncService.pullNow(store: self, shelfStore: ShelfStore.shared))
        if let coverNote = await CoverSyncService.pull(store: self) {
            parts.append(coverNote)
        }
        return parts.joined(separator: "；")
    }

    // MARK: - Derived

    var baseURL: URL? {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var text = trimmed
        let lower = text.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") {
            text = "http://" + text
        }
        while text.hasSuffix("/") && text.count > "http://".count + 1 {
            text.removeLast()
        }
        return URL(string: text)
    }

    var isConfigured: Bool {
        baseURL != nil
    }

    var baseTitle: String {
        guard let url = baseURL else { return "漫画坞" }
        let last = url.lastPathComponent
        return last.isEmpty ? (url.host ?? "漫画坞") : last
    }

    var baseItem: WebDAVItem? {
        guard let url = baseURL else { return nil }
        let name = url.lastPathComponent.isEmpty ? (url.host ?? "根目录") : url.lastPathComponent
        return WebDAVItem.make(url: WebDAVItem.directoryURL(url), name: name, isDirectory: true)
    }

    func makeClient() -> WebDAVClient? {
        guard let base = baseURL else { return nil }
        return WebDAVClient(username: username, password: password, baseURL: base)
    }

    // MARK: - Mutations

    func save(serverURL: String, username: String, password: String) {
        var cleaned = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasSuffix("/") && cleaned.count > 8 {
            cleaned.removeLast()
        }
        self.serverURL = cleaned
        self.username = username
        self.password = password
        defaults.set(cleaned, forKey: Keys.serverURL)
        defaults.set(username, forKey: Keys.username)
        Keychain.save(password, account: "webdav")
    }

    /// Wipe the server config so the app returns to the first-run setup screen.
    func clearConfiguration() {
        serverURL = ""
        username = ""
        password = ""
        defaults.removeObject(forKey: Keys.serverURL)
        defaults.removeObject(forKey: Keys.username)
        Keychain.save("", account: "webdav")
    }

    // MARK: - Reading progress

    func recentPage(for url: URL) -> Int {
        recent.first(where: { $0.urlString == url.absoluteString })?.page ?? 0
    }

    func recentEntry(for url: URL) -> RecentEntry? {
        recent.first(where: { $0.urlString == url.absoluteString })
    }

    func recordPage(url: URL, name: String, page: Int, pageCount: Int, isFolder: Bool = false) {
        guard pageCount > 0 else { return }
        var list = recent.filter { $0.urlString != url.absoluteString }
        list.insert(
            RecentEntry(urlString: url.absoluteString, name: name, page: page,
                        pageCount: pageCount, updatedAt: Date(), isFolder: isFolder),
            at: 0
        )
        if list.count > 30 { list = Array(list.prefix(30)) }
        recent = list
        if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: Keys.recent)
        }
        // Finishing a chapter must also clear a manual "unread" mark.
        ReadStateStore.shared.noteFinished(url, page: page, pageCount: pageCount)
        scheduleSyncPush()
    }

    func removeRecent(_ entry: RecentEntry) {
        recent = recent.filter { $0.urlString != entry.urlString }
        if let data = try? JSONEncoder().encode(recent) {
            defaults.set(data, forKey: Keys.recent)
        }
        scheduleSyncPush()
    }

    /// Replaces the whole recent list (used by multi-device sync).
    func replaceRecent(_ list: [RecentEntry]) {
        recent = list
        if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: Keys.recent)
        }
    }

    func clearRecent() {
        recent = []
        defaults.removeObject(forKey: Keys.recent)
    }
}
