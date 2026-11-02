import Foundation
import SwiftUI

/// 一套服务器配置，也就是「一个账号」。
///
/// 同一类型（WebDAV / Komga）可以存多套，每套一个账号、一组地址。
/// 密码不进 UserDefaults，单独放 Keychain（**account = id**），
/// 所以这里的结构体里没有 password 字段。
struct ServerProfile: Codable, Equatable, Identifiable {
    /// 唯一标识，同时是 Keychain 的 account。
    /// 旧版本存档没有这个字段，迁移时会被设成类型名（"webdav"），
    /// 这样旧 Keychain 里的密码不需要搬动就能继续用。
    var id: String = UUID().uuidString
    /// 显示名称（选填）。填了就用它当书架的标题。
    var displayName: String = ""
    /// 多行地址，每行一个（局域网 IP + 公网域名）
    var urls: String = ""
    var username: String = ""

    init(id: String = UUID().uuidString,
         displayName: String = "",
         urls: String = "",
         username: String = "") {
        self.id = id
        self.displayName = displayName
        self.urls = urls
        self.username = username
    }

    /// 旧存档没有 id 字段，解码时补一个。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        urls = try container.decodeIfPresent(String.self, forKey: .urls) ?? ""
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
    }

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

        /// 旧版本：每种后端只有一份配置（保留下来做迁移检测）
        static func profile(_ kind: ServerKind) -> String {
            "mangadock.profile.\(kind.rawValue)"
        }
        /// 新版本：每种后端一个账号列表
        static func accounts(_ kind: ServerKind) -> String {
            "mangadock.accounts.\(kind.rawValue)"
        }
        /// 该类型当前用的是哪个账号
        static func activeAccount(_ kind: ServerKind) -> String {
            "mangadock.activeAccount.\(kind.rawValue)"
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

        // 读当前账号：优先新版的账号列表，退回旧版单份配置。
        // （真正的「旧→新」迁移在第一次调 profiles(for:) 时发生。）
        let initial: ServerProfile
        if let data = d.data(forKey: Keys.accounts(kind)),
           let list = try? JSONDecoder().decode([ServerProfile].self, from: data),
           !list.isEmpty {
            let activeID = d.string(forKey: Keys.activeAccount(kind))
            initial = list.first(where: { $0.id == activeID }) ?? list[0]
        } else if let data = d.data(forKey: Keys.profile(kind)),
                  let single = try? JSONDecoder().decode(ServerProfile.self, from: data) {
            initial = single
        } else {
            initial = ServerProfile()
        }
        serverDisplayName = initial.displayName
        serverURL = initial.urls
        username = initial.username
        // 旧存档的 id 是空的，密码还挂在类型名下面
        password = Keychain.load(account: initial.id.isEmpty ? kind.rawValue : initial.id) ?? ""
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
        client(kind: kind, profile: readProfile(kind))
    }

    /// 用指定账号构造客户端。多账号下「这条目属于谁」靠它决定。
    private func client(kind: ServerKind, profile: ServerProfile) -> RemoteClient? {
        guard let base = baseURL(kind: kind, profile: profile) else { return nil }
        let pass = Keychain.load(account: profile.id) ?? ""
        switch kind {
        case .webdav:
            return WebDAVClient(username: profile.username, password: pass, baseURL: base)
        case .komga:
            return KomgaClient(baseURL: base, username: profile.username, password: pass)
        }
    }

    /// 某套配置的基地址。当前账号用探测过的结果，其他账号先取第一条地址。
    private func baseURL(kind: ServerKind, profile: ServerProfile) -> URL? {
        if profile.id == activeAccountID(kind), let cached = activeURLs[kind] { return cached }
        return profile.lines.compactMap { Self.normalizedURL($0) }.first
    }

    /// WebDAV 的条目是真实的 http(s) 地址，靠 host 就能认出它属于哪个账号 ——
    /// 两个账号挂不同域名/不同 IP 时，各自的条目走各自的凭据。
    private func profileOwning(_ url: URL) -> ServerProfile? {
        guard let host = url.host else { return nil }
        return profiles(for: .webdav).first { profile in
            profile.lines.contains { line in
                Self.normalizedURL(line)?.host == host
            }
        }
    }

    /// 条目属于哪套后端。komga:// 是 Komga，其余一律当 WebDAV。
    func kind(for url: URL) -> ServerKind {
        url.scheme == "komga" ? .komga : .webdav
    }

    /// 按条目 URL 取客户端 —— 两套并存的关键：谁家的条目用谁家的 client。
    func client(for url: URL) -> RemoteClient? {
        let kind = kind(for: url)
        if kind == .webdav, let owner = profileOwning(url) {
            return client(kind: .webdav, profile: owner)
        }
        return client(for: kind)
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

    nonisolated static func normalizedURL(_ text: String) -> URL? {
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

    // MARK: - Accounts (multi-account per kind)

    /// 某个类型下保存的全部账号。
    ///
    /// 第一次读到旧版单份配置时会自动迁移成数组 —— 旧存档的 `id` 设成类型名
    /// （"webdav" / "komga"），这样 Keychain 里原来那份密码不用搬就能接着用。
    func profiles(for kind: ServerKind) -> [ServerProfile] {
        if let data = defaults.data(forKey: Keys.accounts(kind)),
           let list = try? JSONDecoder().decode([ServerProfile].self, from: data) {
            return list
        }

        // 迁移：老版本每种类型只存一个 ServerProfile
        guard let legacyData = defaults.data(forKey: Keys.profile(kind)),
              let legacy = try? JSONDecoder().decode(ServerProfile.self, from: legacyData),
              !legacy.isEmpty else {
            return []
        }
        var migrated = legacy
        migrated.id = kind.rawValue
        saveProfiles([migrated], kind: kind)
        defaults.set(migrated.id, forKey: Keys.activeAccount(kind))
        return [migrated]
    }

    private func saveProfiles(_ list: [ServerProfile], kind: ServerKind) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        defaults.set(data, forKey: Keys.accounts(kind))
    }

    /// 一个可选的账号（类型 + 配置）。文件页的分段控件按它列。
    struct AccountRef: Identifiable, Hashable {
        let kind: ServerKind
        let profile: ServerProfile
        var id: String { profile.id }

        /// 显示名：填了就用，没填就用主机名，再不行用类型名。
        var title: String {
            let name = profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
            if let host = profile.lines.first.flatMap({ URL(string: $0)?.host }) { return host }
            return kind.title
        }
    }

    /// 所有已配置的账号，跨类型。
    var allAccounts: [AccountRef] {
        ServerKind.allCases.flatMap { kind in
            profiles(for: kind).map { AccountRef(kind: kind, profile: $0) }
        }
    }

    /// 按账号构造客户端（文件页切换源时用）。
    func client(for account: AccountRef) -> RemoteClient? {
        client(kind: account.kind, profile: account.profile)
    }

    /// 某个账号的根目录。
    func rootURL(for account: AccountRef) -> URL? {
        switch account.kind {
        case .webdav:
            return baseURL(kind: .webdav, profile: account.profile)
                .map { WebDAVItem.directoryURL($0) }
        case .komga:
            return URL(string: "komga://root")
        }
    }

    /// 当前使用中的账号 id
    func activeAccountID(_ kind: ServerKind) -> String? {
        let list = profiles(for: kind)
        let stored = defaults.string(forKey: Keys.activeAccount(kind))
        if let stored, list.contains(where: { $0.id == stored }) { return stored }
        return list.first?.id
    }

    /// 当前使用中的那套配置（没有就返回空 profile）。
    private func readProfile(_ kind: ServerKind) -> ServerProfile {
        let list = profiles(for: kind)
        guard let id = activeAccountID(kind), let hit = list.first(where: { $0.id == id }) else {
            return list.first ?? ServerProfile()
        }
        return hit
    }

    /// 写回某套配置（按 id 覆盖，找不到就追加）。
    private func writeProfile(_ profile: ServerProfile, kind: ServerKind) {
        var list = profiles(for: kind)
        if let index = list.firstIndex(where: { $0.id == profile.id }) {
            list[index] = profile
        } else {
            list.append(profile)
        }
        saveProfiles(list, kind: kind)
    }

    /// 切到这个类型的另一个账号。会先把当前账号的改动存下来。
    func switchAccount(to id: String, kind: ServerKind) {
        guard id != activeAccountID(kind) else { return }
        persistActiveProfile()               // 先把当前账号的输入存好
        defaults.set(id, forKey: Keys.activeAccount(kind))
        serverKindRaw = kind.rawValue
        loadActiveProfile(kind)
        activeURLs[kind] = nil               // 让地址重新探测
        Task { await probeServers() }
    }

    /// 删掉一个账号。删的是当前账号时，自动切到剩下的第一个。
    func deleteAccount(_ id: String, kind: ServerKind) {
        var list = profiles(for: kind)
        guard list.count > 1 else { return }   // 至少留一个，不然整个 App 会掉回首次设置页
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        list.remove(at: index)
        saveProfiles(list, kind: kind)
        Keychain.save("", account: id)

        if defaults.string(forKey: Keys.activeAccount(kind)) == id {
            let next = list[0].id
            defaults.set(next, forKey: Keys.activeAccount(kind))
            if kind == serverKind { loadActiveProfile(kind) }
        }
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
        Keychain.save(password, account: profile.id)
    }

    /// 从指定类型的存档载入内存。
    private func loadActiveProfile(_ kind: ServerKind) {
        let profile = readProfile(kind)
        serverDisplayName = profile.displayName
        serverURL = profile.urls
        username = profile.username
        password = Keychain.load(account: profile.id) ?? ""
    }

    /// 导入向导专用：**新建**一个账号并切过去。
    ///
    /// 注意是新建不是覆盖 —— 同一个类型下可以有多个账号（不同服务器 / 不同人），
    /// 想改现有账号请走设置页的「保存」（那个才写回当前账号）。
    func activate(kind: ServerKind, displayName: String,
                  serverURL: String, username: String, password: String) {
        var cleaned = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasSuffix("/") && cleaned.count > 8 { cleaned.removeLast() }

        let profile = ServerProfile(displayName: displayName,
                                    urls: cleaned,
                                    username: username)
        writeProfile(profile, kind: kind)
        Keychain.save(password, account: profile.id)
        defaults.set(profile.id, forKey: Keys.activeAccount(kind))

        if kind != serverKind { serverKindRaw = kind.rawValue }
        serverDisplayName = displayName
        self.serverURL = cleaned
        self.username = username
        self.password = password
        activeURLs[kind] = nil
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
        Keychain.save(password, account: profile.id)

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
        let current = readProfile(serverKind)
        var list = profiles(for: serverKind)
        list.removeAll { $0.id == current.id }
        saveProfiles(list, kind: serverKind)
        Keychain.save("", account: current.id)
        defaults.removeObject(forKey: Keys.serverURL)
        defaults.removeObject(forKey: Keys.username)
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
