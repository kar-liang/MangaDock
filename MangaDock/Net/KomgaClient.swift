import Foundation

/// Komga 服务器客户端。
///
/// 把 Komga 的 Library → Series → Book 三层映射成 MangaDock 认识的"目录树"，
/// 靠一套虚拟 URL 表达，上层完全不用改：
///
///     komga://root                    库列表
///     komga://library/{id}            某个库里的系列
///     komga://series/{id}             某个系列里的书
///     komga://book/{id}               一本书（对外当作 .cbz 文件）
///     komga://cover/series/{id}       系列封面
///     komga://cover/book/{id}         单本封面
///     komga://page/{bookId}/{index}   页面数据（index 从 0 开始）
///
/// 认证用 HTTP Basic（用户名 + 密码）。也支持 API Key，改 `authorization`
/// 的实现即可。
final class KomgaClient: RemoteClient {
    private let base: URL
    private let username: String
    private let password: String
    private let session: URLSession

    /// 单次 list 最多拉多少系列。Komga 的 Spring 分页上限是 500。
    private static let pageSize = 500
    /// 最多翻几页，防止一个巨型库把启动拖死。
    private static let maxPages = 4

    init(baseURL: URL, username: String, password: String, timeout: TimeInterval = 20) {
        self.base = baseURL
        self.username = username
        self.password = password
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = 120
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
    }

    // MARK: - RemoteClient

    func list(_ url: URL) async throws -> [WebDAVItem] {
        guard url.scheme == "komga" else { return [] }
        let parts = pathParts(url)

        switch url.host {
        case "root":
            return try await libraries()
        case "library":
            guard let id = parts.first else { return [] }
            return try await series(libraryID: id)
        case "series":
            guard let id = parts.first else { return [] }
            return try await books(seriesID: id)
        default:
            return []
        }
    }

    func ping() async throws {
        _ = try await get("/api/v1/libraries")
    }

    func data(for url: URL) async throws -> Data {
        guard url.scheme == "komga" else { throw KomgaError.badURL }
        let parts = pathParts(url)

        switch url.host {
        case "cover":
            // komga://cover/series/{id} 或 komga://cover/book/{id}
            guard parts.count >= 2 else { throw KomgaError.badURL }
            let kind = parts[0]
            let id = parts[1]
            return try await get("/api/v1/\(kind == "book" ? "books" : "series")/\(id)/thumbnail")

        case "page":
            // komga://page/{bookId}/{index}
            guard parts.count >= 2, let index = Int(parts[1]) else { throw KomgaError.badURL }
            return try await get("/api/v1/books/\(parts[0])/pages/\(index + 1)?convert=jpeg")

        default:
            throw KomgaError.badURL
        }
    }

    /// Komga 不提供字节范围读取，返回 nil 让 RemoteZip 自己回退。
    func data(_ url: URL, byteRange: ClosedRange<Int64>) async throws -> Data? { nil }

    func contentLength(_ url: URL) async throws -> Int64? { nil }

    // MARK: - 具体资源

    /// 一本书的页数。阅读器要用它建 ComicPageSource。
    func pageCount(bookID: String) async throws -> Int {
        let data = try await get("/api/v1/books/\(bookID)")
        let book = try JSONDecoder().decode(KomgaBook.self, from: data)
        return book.media?.pagesCount ?? 0
    }

    private func libraries() async throws -> [WebDAVItem] {
        let data = try await get("/api/v1/libraries")
        let list = try JSONDecoder().decode([KomgaLibrary].self, from: data)
        return list.map {
            WebDAVItem(url: Self.url("komga://library/\($0.id)"),
                       name: $0.name,
                       isDirectory: true,
                       size: 0,
                       modified: nil)
        }
    }

    private func series(libraryID: String) async throws -> [WebDAVItem] {
        var all: [KomgaSeries] = []
        for page in 0..<Self.maxPages {
            let data = try await get("/api/v1/series?library_id=\(libraryID)&page=\(page)&size=\(Self.pageSize)&sort=metadata.titleSort,asc")
            let box = try JSONDecoder().decode(KomgaPage<KomgaSeries>.self, from: data)
            all.append(contentsOf: box.content)
            if all.count >= (box.totalElements ?? 0) || box.content.isEmpty { break }
        }
        return all.map {
            WebDAVItem(url: Self.url("komga://series/\($0.id)"),
                       name: $0.metadata?.title ?? $0.name,
                       isDirectory: true,
                       size: 0,
                       modified: nil)
        }
    }

    private func books(seriesID: String) async throws -> [WebDAVItem] {
        let data = try await get("/api/v1/series/\(seriesID)/books?size=\(Self.pageSize)")
        // 这个接口在不同 Komga 版本里可能返回数组，也可能返回分页对象。
        let books = try Self.decodeBooks(from: data)
        return books
            .sorted { ($0.metadata?.numberSort ?? 0) < ($1.metadata?.numberSort ?? 0) }
            .map {
                let title = $0.metadata?.title ?? $0.name
                // 加 .cbz 后缀，让上层的 isArchive 判断成立（显示时会自动去掉）
                return WebDAVItem(url: Self.url("komga://book/\($0.id)"),
                                  name: title.lowercased().hasSuffix(".cbz") ? title : title + ".cbz",
                                  isDirectory: false,
                                  size: 0,
                                  modified: nil)
            }
    }

    // MARK: - HTTP

    private func get(_ path: String) async throws -> Data {
        guard let url = URL(string: path, relativeTo: base) else { throw KomgaError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let token = Data("\(username):\(password)".utf8).base64EncodedString()
        request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("MangaDock/2.1", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw KomgaError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw KomgaError.status(http.statusCode)
        }
        return data
    }

    // MARK: - Helpers

    /// "komga://series/abc" → ["abc"]；"komga://cover/book/x" → ["book", "x"]
    /// 从虚拟 URL 里取出资源 ID：komga://book/abc → abc，komga://series/abc → abc
    static func bookID(from url: URL) -> String? {
        guard url.scheme == "komga" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        return parts.first
    }

    private func pathParts(_ url: URL) -> [String] {
        url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
    }

    private static func url(_ string: String) -> URL {
        URL(string: string) ?? URL(string: "komga://root")!
    }

    /// 有的接口返回 `{content: [...]}`，有的直接返回 `[...]`，两种都认。
    private static func decodeBooks(from data: Data) throws -> [KomgaBook] {
        let decoder = JSONDecoder()
        if let array = try? decoder.decode([KomgaBook].self, from: data) { return array }
        if let box = try? decoder.decode(KomgaPage<KomgaBook>.self, from: data) { return box.content }
        throw KomgaError.badResponse
    }
}

enum KomgaError: LocalizedError {
    case badURL
    case badResponse
    case status(Int)

    var errorDescription: String? {
        switch self {
        case .badURL: return "Komga 地址不对"
        case .badResponse: return "Komga 返回了看不懂的内容"
        case .status(let code):
            switch code {
            case 401, 403: return "Komga 账号或密码不对（\(code)）"
            case 404: return "Komga 上找不到这个内容（404）"
            default: return "Komga 返回错误 \(code)"
            }
        }
    }
}

// MARK: - DTO

private struct KomgaLibrary: Decodable {
    let id: String
    let name: String
}

private struct KomgaPage<T: Decodable>: Decodable {
    let content: [T]
    let totalElements: Int?

    private enum CodingKeys: String, CodingKey {
        case content, totalElements
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        content = try c.decode([T].self, forKey: .content)
        totalElements = try c.decodeIfPresent(Int.self, forKey: .totalElements)
    }
}

private struct KomgaSeries: Decodable {
    let id: String
    let name: String
    let metadata: Meta?

    struct Meta: Decodable {
        let title: String?
        let readingDirection: String?
    }
}

private struct KomgaBook: Decodable {
    let id: String
    let name: String
    let media: Media?
    let metadata: Meta?

    struct Media: Decodable {
        let pagesCount: Int?
    }

    struct Meta: Decodable {
        let title: String?
        let numberSort: Double?
    }
}
