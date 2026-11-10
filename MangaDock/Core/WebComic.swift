import Foundation
import CoreFoundation

// MARK: - Models

struct WebComicChapter: Codable, Identifiable, Hashable {
    var urlString: String
    var title: String

    var id: String { urlString }
    var url: URL? { URL(string: urlString) }
}

struct WebComicSource: Codable, Identifiable, Hashable {
    var urlString: String
    var title: String
    var coverString: String?
    var addedAt: Date
    /// Reading position remembered across sessions. Page is the index of the
    /// first visible page (0-based); pageCount is the number of parsed pages.
    var lastPage: Int = 0
    var pageCount: Int = 0
    /// When non-empty this source is a multi-chapter title parsed from an index
    /// page; the shelf opens a chapter list instead of jumping into the reader.
    var chapters: [WebComicChapter] = []

    var id: String { urlString }
    var url: URL? { URL(string: urlString) }
    var cover: URL? { coverString.flatMap(URL.init(string:)) }

    var isSeries: Bool { !chapters.isEmpty }

    var hasProgress: Bool { pageCount > 0 }
    var progressText: String {
        guard pageCount > 0 else { return "" }
        let current = min(lastPage + 1, pageCount)
        return "第 \(current) / \(pageCount) 页"
    }

    init(urlString: String, title: String, coverString: String?, addedAt: Date,
         lastPage: Int = 0, pageCount: Int = 0, chapters: [WebComicChapter] = []) {
        self.urlString = urlString
        self.title = title
        self.coverString = coverString
        self.addedAt = addedAt
        self.lastPage = lastPage
        self.pageCount = pageCount
        self.chapters = chapters
    }

    /// Tolerant decode so pre-1.8.0 archives (missing progress/chapter keys)
    /// still load instead of throwing away the whole list.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        urlString = try c.decode(String.self, forKey: .urlString)
        title = try c.decode(String.self, forKey: .title)
        coverString = try c.decodeIfPresent(String.self, forKey: .coverString)
        addedAt = try c.decode(Date.self, forKey: .addedAt)
        lastPage = try c.decodeIfPresent(Int.self, forKey: .lastPage) ?? 0
        pageCount = try c.decodeIfPresent(Int.self, forKey: .pageCount) ?? 0
        chapters = try c.decodeIfPresent([WebComicChapter].self, forKey: .chapters) ?? []
    }
}

final class WebComicStore: ObservableObject {
    static let shared = WebComicStore()

    @Published private(set) var sources: [WebComicSource] = []

    private let key = "mangadock.webcomics"

    private init() { load() }

    func contains(_ url: URL) -> Bool {
        sources.contains { $0.urlString == url.absoluteString }
    }

    func add(_ source: WebComicSource) {
        guard !contains(URL(string: source.urlString) ?? URL(fileURLWithPath: "/")) else { return }
        sources.insert(source, at: 0)
        save()
    }

    func remove(_ source: WebComicSource) {
        sources.removeAll { $0.urlString == source.urlString }
        save()
    }

    func remove(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) where index < sources.count {
            sources.remove(at: index)
        }
        save()
    }

    func recordProgress(url: URL, page: Int, pageCount: Int) {
        guard pageCount > 0 else { return }
        guard let index = sources.firstIndex(where: { $0.urlString == url.absoluteString }) else { return }
        sources[index].lastPage = min(max(0, page), pageCount - 1)
        sources[index].pageCount = pageCount
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(sources) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([WebComicSource].self, from: data) else { return }
        sources = list
    }
}

// MARK: - Parser

enum WebComicParser {
    struct Result {
        let title: String
        let pages: [URL]
    }

    enum ParseError: LocalizedError {
        case noImages
        case badURL

        var errorDescription: String? {
            switch self {
            case .noImages:
                return "这个页面里没解析到漫画图片。可能是 JS 动态加载、需要登录、或者被 Cloudflare 拦了。"
            case .badURL:
                return "网址格式不对"
            }
        }
    }

    private static let ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    static func normalize(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let lower = text.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") {
            text = "https://" + text
        }
        return URL(string: text)
    }

    static func fetchHTML(_ url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue(ua, forHTTPHeaderField: "User-Agent")
        request.setValue(url.absoluteString, forHTTPHeaderField: "Referer")
        request.timeoutInterval = 25

        let (data, _) = try await ABSSession.shared.data(for: request)
        if let text = String(data: data, encoding: .utf8) { return text }

        let gb = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let text = String(data: data, encoding: String.Encoding(rawValue: gb)) { return text }
        return String(decoding: data, as: UTF8.self)
    }

    static func parse(_ url: URL) async throws -> Result {
        let html = try await fetchHTML(url)
        let title = pageTitle(html) ?? url.host ?? "在线漫画"
        let pages = imageURLs(in: html, base: url)
        guard !pages.isEmpty else { throw ParseError.noImages }
        return Result(title: title, pages: pages)
    }

    // MARK: Index page (multi-chapter)

    struct IndexResult {
        let title: String
        let chapters: [WebComicChapter]
        let cover: URL?
    }

    /// Parses an index/toc page: finds links whose text or URL looks like a
    /// chapter/episode and returns them in document order (de-duplicated).
    static func parseIndex(_ url: URL) async throws -> IndexResult {
        let html = try await fetchHTML(url)
        let title = pageTitle(html) ?? url.host ?? "在线漫画"
        let chapters = chapterLinks(in: html, base: url)
        guard !chapters.isEmpty else {
            throw ParseError.noImages  // reuse: nothing useful found
        }
        let cover = imageURLs(in: html, base: url).first
        return IndexResult(title: title, chapters: chapters, cover: cover)
    }

    /// Chapter-name hints. Text like "第12话", "Episode 3", "ch. 7", "第 07 卷".
    private static let chapterTextPattern =
        "第\\s*\\d+\\s*[话話章节卷回]|episode\\s*\\d+|chapter\\s*\\d+|ch\\.\\s*\\d+|ep\\.\\s*\\d+"

    private static func chapterLinks(in html: String, base: URL) -> [WebComicChapter] {
        guard let linkRegex = try? NSRegularExpression(
            pattern: "<a\\b[^>]*href\\s*=\\s*[\"']([^\"']+)[\"'][^>]*>([\\s\\S]*?)</a>",
            options: [.caseInsensitive]) else { return [] }

        let ns = html as NSString
        let textRegex = try? NSRegularExpression(pattern: chapterTextPattern, options: [.caseInsensitive])

        var seen = Set<String>()
        var result: [WebComicChapter] = []

        for match in linkRegex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            guard let hrefRange = Range(match.range(at: 1), in: html),
                  let textRange = Range(match.range(at: 2), in: html) else { continue }
            let href = String(html[hrefRange])
            var text = String(html[textRange])
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !href.hasPrefix("#"), !href.hasPrefix("javascript:"), !href.isEmpty else { continue }
            guard let absolute = URL(string: href, relativeTo: base)?.absoluteURL,
                  let scheme = absolute.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { continue }

            // The link is a chapter candidate if its text OR URL carries a hint.
            let urlText = absolute.absoluteString.lowercased()
            let textHits = textRegex?.firstMatch(
                in: text, range: NSRange(text.startIndex..., in: text)) != nil
            let urlHits = textRegex?.firstMatch(
                in: urlText, range: NSRange(urlText.startIndex..., in: urlText)) != nil
            guard textHits || urlHits else { continue }

            if text.isEmpty { text = absolute.lastPathComponent }

            if seen.insert(absolute.absoluteString).inserted {
                result.append(WebComicChapter(urlString: absolute.absoluteString, title: text))
            }
        }

        result.sort { NaturalSort.less($0.title, $1.title) }
        return result
    }

    // MARK: HTML helpers

    private static func pageTitle(_ html: String) -> String? {
        if let regex = try? NSRegularExpression(pattern: "<title[^>]*>([\\s\\S]*?)</title>",
                                                options: [.caseInsensitive]),
           let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let range = Range(match.range(at: 1), in: html) {
            let raw = String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !raw.isEmpty { return raw }
        }
        if let regex = try? NSRegularExpression(pattern: "property=[\"']og:title[\"'][^>]*content=[\"']([^\"']+)",
                                                options: [.caseInsensitive]),
           let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let range = Range(match.range(at: 1), in: html) {
            return String(html[range])
        }
        return nil
    }

    /// Collects candidate image URLs in document order, skipping obvious chrome
    /// (logos, icons, tracking pixels, base64 placeholders).
    static func imageURLs(in html: String, base: URL) -> [URL] {
        guard let tagRegex = try? NSRegularExpression(pattern: "<img\\b[^>]*>",
                                                      options: [.caseInsensitive]) else { return [] }

        let ns = html as NSString
        let matches = tagRegex.matches(in: html, range: NSRange(location: 0, length: ns.length))

        var seen = Set<String>()
        var result: [URL] = []

        let attrNames = ["data-original", "data-src", "data-lazy-src", "data-echo", "src", "srcset"]
        let attrRegex = try? NSRegularExpression(
            pattern: "(data-original|data-src|data-lazy-src|data-echo|srcset|src)\\s*=\\s*[\"']([^\"']+)[\"']",
            options: [.caseInsensitive])

        for match in matches {
            let tag = ns.substring(with: match.range)

            // Skip small decorative images when the tag says so.
            if let width = intAttribute("width", in: tag), width > 0, width < 200 { continue }
            if let height = intAttribute("height", in: tag), height > 0, height < 200 { continue }

            guard let attrRegex else { continue }
            let tagRange = NSRange(tag.startIndex..., in: tag)
            for attr in attrRegex.matches(in: tag, range: tagRange) {
                guard let nameRange = Range(attr.range(at: 1), in: tag),
                      let valueRange = Range(attr.range(at: 2), in: tag) else { continue }
                let name = String(tag[nameRange]).lowercased()
                var value = String(tag[valueRange])

                if name == "srcset" {
                    // take the last (usually largest) candidate
                    if let last = value.split(separator: ",").last {
                        value = String(last).trimmingCharacters(in: .whitespaces)
                        value = String(value.split(separator: " ").first ?? "")
                    }
                }

                guard !value.hasPrefix("data:"), !value.isEmpty else { continue }

                let decoded = value.replacingOccurrences(of: "&amp;", with: "&")
                guard let absolute = URL(string: decoded, relativeTo: base)?.absoluteURL else { continue }

                guard let scheme = absolute.scheme?.lowercased(),
                      scheme == "http" || scheme == "https" else { continue }

                let lower = absolute.absoluteString.lowercased()
                if lower.hasSuffix(".svg") || lower.hasSuffix(".gif") { continue }
                if ["logo", "avatar", "icon", "qr", "banner", "advert"].contains(where: { lower.contains($0) }) {
                    continue
                }

                if seen.insert(absolute.absoluteString).inserted {
                    result.append(absolute)
                }
            }
        }

        // Prefer the ordered attribute priority above; if nothing matched, fall
        // back to any http(s) image-looking URL in the raw HTML.
        if result.isEmpty {
            let fallback = try? NSRegularExpression(
                pattern: "https?://[^\"'\\s<>]+\\.(jpg|jpeg|png|webp)",
                options: [.caseInsensitive])
            let nsHTML = html as NSString
            for match in fallback?.matches(in: html, range: NSRange(location: 0, length: nsHTML.length)) ?? [] {
                let raw = nsHTML.substring(with: match.range)
                if let url = URL(string: raw), seen.insert(raw).inserted {
                    result.append(url)
                }
            }
        }

        return result
    }

    private static func intAttribute(_ name: String, in tag: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: "\(name)\\s*=\\s*[\"']?(\\d+)",
                                                   options: [.caseInsensitive]),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
              let range = Range(match.range(at: 1), in: tag) else { return nil }
        return Int(tag[range])
    }
}
