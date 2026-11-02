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
    var serverURLs: [URL] { addresses(for: serverKind) }

    /// 每种后端各自探测到的可用地址（内存态，每次启动重新探测）。
    private var activeURLs: [ServerKind: URL] = [:]

    /// 某套后端配的地址列表（多行 → URL）
    func addresses(for kind: ServerKind) -> [URL] {
        readProfile(kind).lines.compactMap { Self.normalizedURL($0) }
    }

    /// 这套后端配过没有
    func isReady(_ kind: ServerKind) -> Bool {
        !addresses(for: kind).isEmpty
    }

    /// 已配置的所有后端。文件页按这个列出源。
    var configuredKinds: [ServerKind] {
        ServerKind.allCases.filter { isReady($0) }
    }

    func baseURL(for kind: ServerKind) -> URL? {
        if let url = activeURLs[kind] { return url }
        return addresses(for: kind).first
    }

    /// 按类型取客户端。凭据读那套自己的 profile —— 不受「当前激活的是谁」影响，
    /// 这样两套服务器可以同时在线，各自的条目用各自的 client。
    func client(for kind: ServerKind) -> RemoteClient? {
        guard let base = baseURL(for: kind) else { return nil }
        let profile = readProfile(kind)
        let pass = Keychain.load(account: kind.rawValue) ?? ""
        switch kind {
        case .webdav:
            return WebDAVClient(username: profile.username, password: pass, baseURL: base)
        case .komga:
            return KomgaClient(baseURL: base, username: profile.username, password: pass)
        }
    }

    /// 条目属于哪套后端。komga:// 是 Komga，其余一律当 WebDAV。
    func kind(for url: URL) -> ServerKind {
        url.scheme == "komga" ? .komga : .webdav
    }

    /// 按条目 URL 取客户端 —— 两套并存的关键：谁家的条目用谁家的 client。
    func client(for url: URL) -> RemoteClient? {
        client(for: kind(for: url))
    }

    /// 某套后端的根目录
    func rootURL(for kind: ServerKind) -> URL? {
        switch kind {
        case .webdav:
            return baseURL(for: .webdav).map { WebDAVItem.directoryURL($0) }
        case .komga:
            return URL(string: "komga://root")
        }
    }

    /// 上次 Ping 通的地址（按类型分开记，两套各自有各自的）
    private func lastGood(for kind: ServerKind) -> URL? {
        guard let s = UserDefaults.standard.string(forKey: "mangadock.lastGoodURL.\(kind.rawValue)"),
              let url = URL(string: s) else { return nil }
        return url
    }

    private func setLastGood(_ url: URL?, for kind: ServerKind) {
        UserDefaults.standard.set(url?.absoluteString,
                                  forKey: "mangadock.lastGoodURL.\(kind.rawValue)")
    }

    /// 探测**所有已配置**的后端，并行互不阻塞。
    /// 两套并存时启动一次就把两边都探好，切源时不用再等。
    @discardableResult
    func probeServers() async -> URL? {
        let kinds = configuredKinds
        guard !kinds.isEmpty else { return nil }
        await withTaskGroup(of: Void.self) { group in
            for kind in kinds {
                group.addTask { await self.probe(kind) }
            }
        }
        return baseURL(for: serverKind)
    }

    /// 单套后端的地址探测：并行试所有地址，谁先通就用谁。
    private func probe(_ kind: ServerKind) async {
        let urls = addresses(for: kind)
        guard !urls.isEmpty else { return }
        if urls.count == 1 {
            activeURLs[kind] = urls[0]
            return
        }
        // 冷启动先用上次成功的地址：外网场景下内网地址必然连不上，
        // 串行探测要白等一个超时。
        if let last = lastGood(for: kind), urls.contains(last) {
            activeURLs[kind] = last
            return
        }

        let profile = readProfile(kind)
        let user = profile.username
        let pass = Keychain.load(account: kind.rawValue) ?? ""
        let found: URL? = await withTaskGroup(of: URL?.self) { group in
            for url in urls {
                group.addTask {
                    switch kind {
                    case .webdav:
                        let c = WebDAVClient(username: user, password: pass,
                                             baseURL: url, timeout: 4)
                        return (try? await c.ping()) != nil ? url : nil
                    case .komga:
                        let c = KomgaClient(baseURL: url, username: user,
                                            password: pass, timeout: 4)
                        return (try? await c.ping()) != nil ? url : nil
                    }
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
        activeURLs[kind] = winner
        if found != nil { setLastGood(winner, for: kind) }
    }

    var baseURL: URL? { baseURL(for: serverKind) }

    /// 当前激活后端的根目录
    var rootURL: URL? { rootURL(for: serverKind) }

    /// 任意一套配过就算配置好了 —— 两套并存，能进主界面就行
    var isConfigured: Bool { !configuredKinds.isEmpty }

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
        }
    }

    /// 当前激活后端的客户端。只给「不关心是哪一套」的旧代码用 ——
    /// 涉及具体条目的地方一律走 `client(for: item.url)`。
    func makeClient() -> RemoteClient? {
        client(for: serverKind)
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
        activeURLs[serverKind] = nil
        setLastGood(nil, for: serverKind)
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
