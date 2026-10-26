import Foundation

// MARK: - Models

/// 一个 Bangumi 条目（漫画/书籍）。
struct BangumiSubject: Codable, Identifiable, Hashable {
    let id: Int
    let name: String
    let nameCN: String?
    let summary: String?
    let date: String?
    let images: Images?
    let rating: Rating?
    let tags: [Tag]?
    let infobox: [InfoBox]?

    struct Images: Codable, Hashable {
        let large: String?
        let common: String?
        let medium: String?
        let small: String?
        let grid: String?
    }

    struct Rating: Codable, Hashable {
        let score: Double?
        let total: Int?
    }

    struct Tag: Codable, Hashable {
        let name: String
        let count: Int?
    }

    struct InfoBox: Codable, Hashable {
        let key: String
        let value: InfoValue
    }

    enum CodingKeys: String, CodingKey {
        case id, name, summary, date, images, rating, tags, infobox
        case nameCN = "name_cn"
    }

    /// 中文名优先，没有就退回原名。
    var displayTitle: String {
        if let cn = nameCN, !cn.trimmingCharacters(in: .whitespaces).isEmpty {
            return cn
        }
        return name
    }

    /// 封面地址，挑一个分辨率够用又不浪费流量的。
    var coverURL: URL? {
        for candidate in [images?.common, images?.medium, images?.large, images?.small] {
            if let s = candidate, let url = URL(string: s) { return url }
        }
        return nil
    }

    /// 从 infobox 里捞作者/出版社这类信息。
    func infoValue(for key: String) -> String? {
        guard let entry = infobox?.first(where: { $0.key == key }) else { return nil }
        let text = entry.value.display.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    var authors: String? {
        infoValue(for: "作者") ?? infoValue(for: "原作")
    }

    var publisher: String? {
        infoValue(for: "出版社") ?? infoValue(for: "连载杂志")
    }
}

/// infobox 的 value 有时是字符串，有时是 `[{v: "...", k: "..."}]`。
enum InfoValue: Codable, Hashable {
    case text(String)
    case list([Item])

    struct Item: Codable, Hashable {
        let v: String?
        let k: String?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self = .text(string)
            return
        }
        if let items = try? container.decode([Item].self) {
            self = .list(items)
            return
        }
        self = .text("")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let string): try container.encode(string)
        case .list(let items): try container.encode(items)
        }
    }

    var display: String {
        switch self {
        case .text(let s):
            return s
        case .list(let items):
            return items.compactMap { $0.v ?? $0.k }.joined(separator: " / ")
        }
    }
}

/// 条目下的一个角色。
struct BangumiCharacter: Codable, Identifiable, Hashable {
    let id: Int
    let name: String
    let summary: String?
    /// 「主角」/「配角」/「客串」，API 直接给中文。
    let relation: String?
    let type: Int?
    let images: BangumiSubject.Images?

    var portraitURL: URL? {
        for candidate in [images?.medium, images?.large, images?.small, images?.grid] {
            if let s = candidate, let url = URL(string: s) { return url }
        }
        return nil
    }
}

// MARK: - Client

/// Bangumi v0 API 客户端。
///
/// 只做只读的元数据（搜索 + 详情），不碰收藏/进度，所以不需要 OAuth。
/// 官方的硬性要求：必须带自定义 User-Agent，否则 403；请求间隔 ~0.5s。
final class BangumiClient {
    static let shared = BangumiClient()

    /// 允许改基地址：这条线路直连 api.bgm.tv 会超时，
    /// 换成自建转发就能用（见设置里的「Bangumi 接口地址」）。
    static let defaultBase = "https://api.bgm.tv/v0"

    private let session: URLSession
    private let cacheFolder: URL
    private let mappingKey = "mangodock.bangumi.map"

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 20
        session = URLSession(configuration: config)

        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        cacheFolder = base.appendingPathComponent("bangumi", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
    }

    // MARK: Settings

    private var baseURL: String {
        let saved = UserDefaults.standard.string(forKey: "mangadock.bangumi.base") ?? ""
        return saved.isEmpty ? Self.defaultBase : saved
    }

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "mangadock.bangumi.enabled") as? Bool ?? true
    }

    /// 每个系列对应的 subject id。-1 表示"找过但没有可信匹配"，避免反复请求。
    private var mapping: [String: Int] {
        get {
            (UserDefaults.standard.dictionary(forKey: mappingKey) as? [String: Int]) ?? [:]
        }
        set {
            UserDefaults.standard.set(newValue, forKey: mappingKey)
        }
    }

    /// 之前搜过但没找到可信匹配（-1）。UI 用它来决定是否直接给手动入口。
    func hasGivenUp(seriesURL: String) -> Bool {
        mapping[seriesURL] == -1
    }

    /// 这条线路连不上 api.bgm.tv 时，别每次进系列页都等满超时。
    private var lastNetworkFailure: Date?

    func shouldSkipForNow() -> Bool {
        guard let last = lastNetworkFailure else { return false }
        return Date().timeIntervalSince(last) < 300
    }

    func linkedSubjectID(for seriesURL: String) -> Int? {
        guard let id = mapping[seriesURL], id > 0 else { return nil }
        return id
    }

    /// 手动指定（用户在候选列表里选了一个）。
    func link(seriesURL: String, subjectID: Int) {
        var map = mapping
        map[seriesURL] = subjectID
        mapping = map
        // 手动选的优先，把旧缓存冲掉
        if let url = cacheURL(id: subjectID) { try? FileManager.default.removeItem(at: url) }
    }

    func unlink(seriesURL: String) {
        var map = mapping
        map.removeValue(forKey: seriesURL)
        mapping = map
    }

    // MARK: Lookup

    /// 给一个系列名拿到元数据。优先用缓存的映射，其次自动搜索。
    /// 返回 nil 表示没找到可信条目（调用方可以提示用户手动关联）。
    func subject(forSeriesNamed name: String, seriesURL: String) async -> BangumiSubject? {
        guard isEnabled, !shouldSkipForNow() else { return nil }

        // 之前试过但没匹配上，别每次都重新搜
        if let cached = mapping[seriesURL] {
            guard cached > 0 else { return nil }
            return await detail(id: cached)
        }

        guard let found = await search(name: name) else {
            var map = mapping
            map[seriesURL] = -1
            mapping = map
            return nil
        }

        var map = mapping
        map[seriesURL] = found.id
        mapping = map
        return await detail(id: found.id)
    }

    /// 手动搜索：返回候选列表，交给用户挑。
    func candidates(for name: String) async -> [BangumiSubject] {
        await searchAll(name: name, limit: 12)
    }

    func detail(id: Int) async -> BangumiSubject? {
        if let cached = loadCached(id: id) { return cached }

        guard let url = URL(string: "\(baseURL)/subjects/\(id)") else { return nil }
        guard let data = await get(url) else { return nil }
        guard let subject = try? JSONDecoder().decode(BangumiSubject.self, from: data) else {
            return nil
        }
        saveCached(id: id, data: data)
        return subject
    }

    // MARK: Characters

    func characters(subjectID: Int) async -> [BangumiCharacter] {
        if let cached = loadCachedCharacters(subjectID: subjectID) { return cached }

        guard let url = URL(string: "\(baseURL)/subjects/\(subjectID)/characters") else { return [] }
        guard let data = await get(url) else { return [] }
        guard let list = try? JSONDecoder().decode([BangumiCharacter].self, from: data) else {
            return []
        }
        saveCachedCharacters(subjectID: subjectID, data: data)
        return list
    }

    // MARK: Search

    private struct SearchResponse: Codable {
        let data: [BangumiSubject]?
    }

    private func search(name: String) async -> BangumiSubject? {
        let list = await searchAll(name: name, limit: 6)
        guard let first = list.first else { return nil }
        // 只在名字对得上时才自动采用。对不上就让用户手动选，
        // 免得把「一人之下」链接成完全无关的条目。
        guard titleMatches(query: name, subject: first) else { return nil }
        return first
    }

    private func searchAll(name: String, limit: Int) async -> [BangumiSubject] {
        guard let url = URL(string: "\(baseURL)/search/subjects?limit=\(limit)") else { return [] }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        // type 1 = 书籍（漫画归在这里）
        let body: [String: Any] = ["keyword": name, "filter": ["type": [1]]]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let data = await get(request) else { return [] }
        return (try? JSONDecoder().decode(SearchResponse.self, from: data))?.data ?? []
    }

    /// 宽松匹配：包含关系就算对上（"一人之下" vs "一人之下"）。
    private func titleMatches(query: String, subject: BangumiSubject) -> Bool {
        let q = Self.normalize(query)
        guard !q.isEmpty else { return false }
        for candidate in [subject.displayTitle, subject.name] {
            let c = Self.normalize(candidate)
            guard !c.isEmpty else { continue }
            if c == q || c.contains(q) || q.contains(c) { return true }
        }
        return false
    }

    private static func normalize(_ s: String) -> String {
        let dropped = s.unicodeScalars.filter { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar)
                && !CharacterSet.punctuationCharacters.contains(scalar)
                && !CharacterSet.symbols.contains(scalar)
        }
        return String(String.UnicodeScalarView(dropped)).lowercased()
    }

    // MARK: Transport

    private static var userAgent: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "MangaDock/\(version) (https://github.com/kar-liang/MangaDock)"
    }

    private func get(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        return await get(request)
    }

    private func get(_ request: URLRequest) async -> Data? {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                lastNetworkFailure = Date()
                return nil
            }
            lastNetworkFailure = nil
            return data
        } catch {
            lastNetworkFailure = Date()
            return nil
        }
    }

    // MARK: Disk cache

    private func cacheURL(id: Int) -> URL? {
        cacheFolder.appendingPathComponent("\(id).json")
    }

    private func loadCached(id: Int) -> BangumiSubject? {
        guard let url = cacheURL(id: id),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(BangumiSubject.self, from: data)
    }

    private func saveCached(id: Int, data: Data) {
        guard let url = cacheURL(id: id) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func characterCacheURL(id: Int) -> URL {
        cacheFolder.appendingPathComponent("characters-\(id).json")
    }

    private func loadCachedCharacters(subjectID: Int) -> [BangumiCharacter]? {
        guard let data = try? Data(contentsOf: characterCacheURL(id: subjectID)) else { return nil }
        return try? JSONDecoder().decode([BangumiCharacter].self, from: data)
    }

    private func saveCachedCharacters(subjectID: Int, data: Data) {
        try? data.write(to: characterCacheURL(id: subjectID), options: .atomic)
    }

    /// 清掉磁盘上的条目缓存（映射保留）。
    func clearCache() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: cacheFolder,
                                                                     includingPropertiesForKeys: nil) else { return }
        for file in files { try? FileManager.default.removeItem(at: file) }
    }
}
