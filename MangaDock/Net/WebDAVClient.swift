import Foundation

enum WebDAVError: LocalizedError {
    case invalidURL
    case badStatus(Int)
    case emptyResponse
    case parseFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "服务器地址无效"
        case .badStatus(let code):
            switch code {
            case 401: return "用户名或密码不对（401）"
            case 403: return "没有权限访问这个目录（403）"
            case 404: return "路径不存在（404）"
            case 405: return "这个地址不是 WebDAV 服务（405）"
            case 502, 503: return "服务器暂时不可用（\(code)）"
            default: return "服务器返回 \(code)"
            }
        case .emptyResponse:
            return "服务器没有返回内容"
        case .parseFailed:
            return "目录内容解析失败，可能不是标准 WebDAV"
        }
    }
}

final class WebDAVClient: @unchecked Sendable {
    private let username: String
    private let password: String
    private let baseURL: URL
    private let session: URLSession
    private let sessionDelegate: WebDAVSessionDelegate

    init(username: String, password: String, baseURL: URL) {
        self.username = username
        self.password = password
        self.baseURL = baseURL

        let delegate = WebDAVSessionDelegate(username: username, password: password)
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 900
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 4
        self.sessionDelegate = delegate
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    // MARK: - Requests

    private var authorizationHeader: String {
        let raw = "\(username):\(password)"
        return "Basic " + Data(raw.utf8).base64EncodedString()
    }

    private func makeRequest(url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        request.setValue("MangaDock/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        return request
    }

    // MARK: - Listing

    func list(_ url: URL) async throws -> [WebDAVItem] {
        let target = WebDAVItem.directoryURL(url)
        var request = makeRequest(url: target, method: "PROPFIND")
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.propfindBody.utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WebDAVError.emptyResponse }
        let accepted = (200...299).contains(http.statusCode) || http.statusCode == 207
        guard accepted else { throw WebDAVError.badStatus(http.statusCode) }
        guard !data.isEmpty else { throw WebDAVError.emptyResponse }

        let rawItems = try PropfindParser().parse(data)
        let selfPath = Self.normalizedPath(target)

        var items: [WebDAVItem] = []
        for raw in rawItems {
            guard let itemURL = resolve(href: raw.href) else { continue }
            if Self.normalizedPath(itemURL) == selfPath { continue }
            let name = Self.displayName(raw: raw, url: itemURL)
            if name.isEmpty { continue }
            items.append(WebDAVItem(url: itemURL,
                                    name: name,
                                    isDirectory: raw.isDirectory,
                                    size: raw.size,
                                    modified: raw.modified))
        }

        items.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return NaturalSort.less(lhs.name, rhs.name)
        }
        return items
    }

    // MARK: - Fetching

    func data(for url: URL) async throws -> Data {
        let request = makeRequest(url: url, method: "GET")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WebDAVError.emptyResponse }
        guard (200...299).contains(http.statusCode) else { throw WebDAVError.badStatus(http.statusCode) }
        return data
    }

    func download(_ url: URL, to destination: URL,
                  progress: @escaping @Sendable (Double) -> Void) async throws {
        let request = makeRequest(url: url, method: "GET")
        let reporter = DownloadProgressDelegate(onProgress: progress)

        let (temporaryURL, response) = try await session.download(for: request, delegate: reporter)
        guard let http = response as? HTTPURLResponse else { throw WebDAVError.emptyResponse }
        guard (200...299).contains(http.statusCode) else { throw WebDAVError.badStatus(http.statusCode) }

        let manager = FileManager.default
        try manager.createDirectory(at: destination.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
        if manager.fileExists(atPath: destination.path) {
            try manager.removeItem(at: destination)
        }
        try manager.moveItem(at: temporaryURL, to: destination)
    }

    /// Fetches a byte range. Returns nil when the server ignores Range (answers 200
    /// with the whole file) — callers then fall back instead of buffering 50 MB.
    func data(_ url: URL, byteRange: ClosedRange<Int64>) async throws -> Data? {
        var request = makeRequest(url: url, method: "GET")
        request.setValue("bytes=\(byteRange.lowerBound)-\(byteRange.upperBound)",
                         forHTTPHeaderField: "Range")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 206 else { return nil }
        return data
    }

    func contentLength(_ url: URL) async throws -> Int64? {
        let head = makeRequest(url: url, method: "HEAD")
        let (_, headResponse) = try await session.data(for: head)
        if let http = headResponse as? HTTPURLResponse,
           http.statusCode == 200 || http.statusCode == 206,
           let value = http.value(forHTTPHeaderField: "Content-Length"),
           let length = Int64(value), length > 0 {
            return length
        }

        // Some WebDAV backends reject HEAD; ask for one byte and read Content-Range.
        var probe = makeRequest(url: url, method: "GET")
        probe.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let (_, probeResponse) = try await session.data(for: probe)
        if let http = probeResponse as? HTTPURLResponse,
           http.statusCode == 206,
           let range = http.value(forHTTPHeaderField: "Content-Range"),
           let total = range.split(separator: "/").last,
           let length = Int64(total) {
            return length
        }
        return nil
    }

    /// Cheap connectivity probe: PROPFIND with Depth 0 on the configured root.
    func probe() async throws -> String {
        let items = try await list(baseURL)
        return "连接成功，根目录有 \(items.count) 项"
    }

    // MARK: - Helpers

    private static let propfindBody = """
    <?xml version="1.0" encoding="utf-8"?>
    <d:propfind xmlns:d="DAV:">
      <d:prop>
        <d:displayname/>
        <d:resourcetype/>
        <d:getcontentlength/>
        <d:getlastmodified/>
      </d:prop>
    </d:propfind>
    """

    private func resolve(href: String) -> URL? {
        var text = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        text = text.replacingOccurrences(of: " ", with: "%20")
        text = Self.percentSanitized(text)

        if text.lowercased().hasPrefix("http://") || text.lowercased().hasPrefix("https://") {
            return URL(string: text)
        }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = ""
        components.query = nil
        components.fragment = nil
        guard let origin = components.url else { return nil }
        return URL(string: text, relativeTo: origin)?.absoluteURL
    }

    /// Some servers (Alist with certain settings, older nginx dav) return raw
    /// UTF-8 Chinese in <href>. URL(string:) then fails and the whole folder
    /// looks empty, so percent-encode non-ASCII while leaving "%" alone.
    private static func percentSanitized(_ text: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.insert(charactersIn: ":/?#[]@!$&'()*+,;=%~")
        var output = ""
        for scalar in text.unicodeScalars {
            if allowed.contains(scalar) {
                output.unicodeScalars.append(scalar)
            } else if let encoded = String(scalar).addingPercentEncoding(withAllowedCharacters: allowed) {
                output += encoded
            }
        }
        return output
    }

    private static func normalizedPath(_ url: URL) -> String {
        var path = url.path
        if path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path.removingPercentEncoding ?? path
    }

    private static func displayName(raw: PropfindRawItem, url: URL) -> String {
        let trimmed = raw.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let last = url.lastPathComponent
        return (last.removingPercentEncoding ?? last)
    }
}

// MARK: - Session delegate (Basic / Digest auth)

final class WebDAVSessionDelegate: NSObject, URLSessionTaskDelegate {
    private let username: String
    private let password: String

    init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest,
             NSURLAuthenticationMethodNTLM:
            let credential = URLCredential(user: username, password: password, persistence: .forSession)
            completionHandler(.useCredential, credential)
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

// MARK: - Download progress

final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
    private let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // Handled by the async `download(for:delegate:)` return value.
    }
}

// MARK: - PROPFIND parsing

struct PropfindRawItem {
    var href: String = ""
    var displayName: String = ""
    var isDirectory: Bool = false
    var size: Int64 = 0
    var modified: Date?
}

final class PropfindParser: NSObject, XMLParserDelegate {
    private var items: [PropfindRawItem] = []
    private var current: PropfindRawItem?
    private var insideResponse = false
    private var buffer = ""

    func parse(_ data: Data) throws -> [PropfindRawItem] {
        items = []
        current = nil
        insideResponse = false
        buffer = ""

        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = self
        guard parser.parse() else { throw WebDAVError.parseFailed }
        return items
    }

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        buffer = ""
        if elementName == "response" {
            insideResponse = true
            current = PropfindRawItem()
        } else if insideResponse && elementName == "collection" {
            current?.isDirectory = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        guard insideResponse else { return }
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)

        switch elementName {
        case "href":
            if !text.isEmpty { current?.href = text }
        case "displayname":
            current?.displayName = text
        case "getcontentlength":
            current?.size = Int64(text) ?? 0
        case "getlastmodified":
            current?.modified = Self.parseDate(text)
        case "response":
            if let item = current, !item.href.isEmpty {
                items.append(item)
            }
            current = nil
            insideResponse = false
        default:
            break
        }
        buffer = ""
    }

    private static let rfc1123: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parseDate(_ text: String) -> Date? {
        if let date = rfc1123.date(from: text) { return date }
        if let date = iso.date(from: text) { return date }
        return nil
    }
}
