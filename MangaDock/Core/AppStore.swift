import Foundation
import SwiftUI

/// 一套服务器配置。WebDAV 和 Komga 各自独立存一份，互不覆盖。
///
/// 密码不进 UserDefaults，单独放 Keychain（account = 类型名），
/// 所以这里的结构体里没有 password 字段。
struct ServerProfile: Codable, Equatable {
    /// 显示名称（选填）。填了就用它当书架的标题。
    var displayName: String = ""
    /// 多行地址，每行一个（局域网 IP + 公网域名）
    var urls: String = ""
    var username: String = ""

    var isEmpty: Bool { lines.isEmpty }

    var lines: [String] {
        urls.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

@MainActor
final class AppStore: ObservableObject {
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let serverURL = "mangadock.serverURL"
        static let serverKind = "mangadock.serverKind"
        static let username = "mangadock.username"
        static let recent = "mangadock.recent"

        /// 每种后端一份独立的配置
        static func profile(_ kind: ServerKind) -> String {
            "mangadock.profile.\(kind.rawValue)"
        }
    }

    @Published var serverURL: String
    @Published var username: String
    @Published var password: String
    /// 显示名称（选填，抽屉/书架标题会用它）
    @Published var serverDisplayName: String
    @Published var recent: [RecentEntry]
    /// 后端类型：WebDAV 目录树，或者 Komga 的 REST API
    @Published var serverKindRaw: String

    init() {
        let d = UserDefaults.standard
        let kind = ServerKind(rawValue: d.string(forKey: Keys.serverKind) ?? "") ?? .webdav
        serverKindRaw = kind.rawValue

        // 老版本只有一套配置（mangadock.serverURL + Keychain "webdav"）。
        // 第一次跑新版本时把它搬进 WebDAV 档案 —— 否则升级完配置会凭空消失。
        if d.data(forKey: Keys.profile(.webdav)) == nil,
           let legacyURL = d.string(forKey: Keys.serverURL),
           !legacyURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let legacy = ServerProfile(displayName: "",
                                       urls: legacyURL,
                                       username: d.string(forKey: Keys.username) ?? "")
            if let data = try? JSONEncoder().encode(legacy) {
                d.set(data, forKey: Keys.profile(.webdav))
            }
        }

        let initial: ServerProfile
        if let data = d.data(forKey: Keys.profile(kind)),
           let decoded = try? JSONDecoder().decode(ServerProfile.self, from: data) {
            initial = decoded
        } else {
            initial = ServerProfile()
        }
        serverDisplayName = initial.displayName
        serverURL = initial.urls
        username = initial.username
        password = Keychain.load(account: kind.rawValue) ?? ""
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

    /// 解析多行地址（换行分隔）为规范化 URL 列表。向后兼容单地址。
    var serverURLs: [URL] {
        serverURL
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .compactMap { Self.normalizedURL($0) }
    }

    /// 探测到的可用地址（内存态，不持久化，每次启动重新探测）。
    private var activeURL: URL?

    /// 上次 Ping 通的地址。冷启动直接用它，省掉一轮探测。
    private var lastGoodURL: URL? {
        get {
            guard let s = UserDefaults.standard.string(forKey: "mangadock.lastGoodURL"),
                  let url = URL(string: s) else { return nil }
            return url
        }
        set {
            UserDefaults.standard.set(newValue?.absoluteString, forKey: "mangadock.lastGoodURL")
        }
    }

    /// 并行探测所有地址，返回第一个能连上的。只有一个地址时直接用（不探测）。
    /// 全部失败则回退到第一个，让后续请求正常报错而非空转。
    @discardableResult
    func probeServers() async -> URL? {
        let urls = serverURLs
        guard !urls.isEmpty else { return nil }
        if urls.count == 1 {
            activeURL = urls[0]
            return urls[0]
        }

        // 冷启动先用上次成功的地址：外网场景下内网地址必然连不上，
        // 串行探测要白等一个超时。这里直接跳过这一轮。
        if let last = lastGoodURL, urls.contains(last) {
            activeURL = last
            return last
        }

        // 并行探测所有地址，谁先通就用谁。原来是串行 for 循环，
        // 每个超时 10 秒 —— 两个地址在外网下最坏要等 20 秒。
        let username = self.username
        let password = self.password
        let found: URL? = await withTaskGroup(of: URL?.self) { group in
            for url in urls {
                group.addTask {
                    let client = WebDAVClient(username: username, password: password,
                                              baseURL: url, timeout: 4)
                    return (try? await client.ping()) != nil ? url : nil
                }
            }
            for await result in group {
                if let result {
                    group.cancelAll()
                    return result
                }
            }
            return nil
        }

        let winner = found ?? urls[0]
        activeURL = winner
        if found != nil { lastGoodURL = winner }
        return winner
    }

    var baseURL: URL? {
        if let activeURL { return activeURL }
        return serverURLs.first
    }

    var isConfigured: Bool {
        !serverURLs.isEmpty
    }

    static func normalizedURL(_ text: String) -> URL? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let lower = t.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") {
            t = "http://" + t
        }
        while t.hasSuffix("/") && t.count > "http://".count + 1 {
            t.removeLast()
        }
        return URL(string: t)
    }

    var baseTitle: String {
        let custom = serverDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { return custom }
        if serverKind == .komga { return "Komga" }
        guard let url = baseURL else { return "漫画坞" }
        let last = url.lastPathComponent
        return last.isEmpty ? (url.host ?? "漫画坞") : last
    }

    var baseItem: WebDAVItem? {
        guard let url = rootURL else { return nil }
        switch serverKind {
        case .webdav:
            let name = url.lastPathComponent.isEmpty ? (url.host ?? "根目录") : url.lastPathComponent
            return WebDAVItem.make(url: WebDAVItem.directoryURL(url), name: name, isDirectory: true)
        case .komga:
            return WebDAVItem.make(url: url, name: "Komga 书库", isDirectory: true)
        }
    }

    var serverKind: ServerKind {
        get { ServerKind(rawValue: serverKindRaw) ?? .webdav }
        set {
            guard newValue != serverKind else { return }
            // 先把当前这类型的输入存回去，再切 —— 否则改了一半切走就丢了
            persistActiveProfile()
            serverKindRaw = newValue.rawValue
            defaults.set(newValue.rawValue, forKey: Keys.serverKind)
            loadActiveProfile(newValue)
            activeURL = nil
            lastGoodURL = nil
        }
    }

    /// 文件页的起点。WebDAV 是服务器根目录，Komga 是虚拟的 komga://root。
    var rootURL: URL? {
        switch serverKind {
        case .webdav:
            return baseURL.map { WebDAVItem.directoryURL($0) }
        case .komga:
            return URL(string: "komga://root")
        }
    }

    func makeClient() -> RemoteClient? {
        guard let base = baseURL else { return nil }
        switch serverKind {
        case .webdav:
            return WebDAVClient(username: username, password: password, baseURL: base)
        case .komga:
            return KomgaClient(baseURL: base, username: username, password: password)
        }
    }

    // MARK: - Profiles

    private func readProfile(_ kind: ServerKind) -> ServerProfile {
        guard let data = defaults.data(forKey: Keys.profile(kind)),
              let profile = try? JSONDecoder().decode(ServerProfile.self, from: data) else {
            return ServerProfile()
        }
        return profile
    }

    private func writeProfile(_ profile: ServerProfile, kind: ServerKind) {
        guard let data = try? JSONEncoder().encode(profile) else { return }
        defaults.set(data, forKey: Keys.profile(kind))
    }

    /// 已保存的配置（给设置页和导入向导判断「这套配过没有」）。
    func savedProfile(_ kind: ServerKind) -> ServerProfile {
        readProfile(kind)
    }

    func hasProfile(_ kind: ServerKind) -> Bool {
        !readProfile(kind).isEmpty
    }

    /// 把内存里的地址/账号/密码写回当前类型。
    private func persistActiveProfile() {
        var profile = readProfile(serverKind)
        profile.displayName = serverDisplayName
        profile.urls = serverURL
        profile.username = username
        writeProfile(profile, kind: serverKind)
        Keychain.save(password, account: serverKind.rawValue)
    }

    /// 从指定类型的存档载入内存。
    private func loadActiveProfile(_ kind: ServerKind) {
        let profile = readProfile(kind)
        serverDisplayName = profile.displayName
        serverURL = profile.urls
        username = profile.username
        password = Keychain.load(account: kind.rawValue) ?? ""
    }

    /// 导入向导专用：一次写入某类型的配置并切过去。
    func activate(kind: ServerKind, displayName: String,
                  serverURL: String, username: String, password: String) {
        if kind != serverKind { serverKind = kind }
        save(serverURL: serverURL, username: username, password: password,
             displayName: displayName)
    }

    // MARK: - Mutations

    func save(serverURL: String, username: String, password: String,
              displayName: String? = nil) {
        var cleaned = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasSuffix("/") && cleaned.count > 8 {
            cleaned.removeLast()
        }
        self.serverURL = cleaned
        self.username = username
        self.password = password
        if let displayName { self.serverDisplayName = displayName }

        var profile = readProfile(serverKind)
        profile.urls = cleaned
        profile.username = username
        profile.displayName = serverDisplayName
        writeProfile(profile, kind: serverKind)
        Keychain.save(password, account: serverKind.rawValue)

        // 旧版本的单配置文件顺手同步一份，回退旧版本时还能读到
        defaults.set(cleaned, forKey: Keys.serverURL)
        defaults.set(username, forKey: Keys.username)
    }

    /// 只清**当前类型**的配置。另一套（WebDAV / Komga）原样保留。
    func clearConfiguration() {
        serverURL = ""
        username = ""
        password = ""
        serverDisplayName = ""
        defaults.removeObject(forKey: Keys.profile(serverKind))
        defaults.removeObject(forKey: Keys.serverURL)
        defaults.removeObject(forKey: Keys.username)
        Keychain.save("", account: serverKind.rawValue)
        activeURL = nil
        lastGoodURL = nil
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
