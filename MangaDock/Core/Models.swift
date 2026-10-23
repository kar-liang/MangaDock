import Foundation

struct WebDAVItem: Identifiable, Hashable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modified: Date?

    var id: String { url.absoluteString }

    var fileExtension: String {
        (name as NSString).pathExtension.lowercased()
    }

    var isImage: Bool {
        ComicFileTypes.imageExtensions.contains(fileExtension)
    }

    var isArchive: Bool {
        ComicFileTypes.archiveExtensions.contains(fileExtension)
    }

    /// Directory URLs must end with a slash or many WebDAV servers answer with a 301.
    var requestURL: URL {
        WebDAVItem.directoryURL(url)
    }

    static func directoryURL(_ url: URL) -> URL {
        if url.absoluteString.hasSuffix("/") { return url }
        return URL(string: url.absoluteString + "/") ?? url
    }

    static func make(url: URL, name: String, isDirectory: Bool) -> WebDAVItem {
        WebDAVItem(url: url, name: name, isDirectory: isDirectory, size: 0, modified: nil)
    }
}

enum ComicFileTypes {
    static let archiveExtensions: Set<String> = ["cbz", "zip"]
    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "webp", "gif", "heic", "heif", "bmp", "tif", "tiff"
    ]
}

enum NavTarget: Hashable {
    case folder(WebDAVItem)
    case comic(WebDAVItem)
}

struct RecentEntry: Identifiable, Codable, Hashable {
    var urlString: String
    var name: String
    var page: Int
    var pageCount: Int
    var updatedAt: Date

    var id: String { urlString }

    var item: WebDAVItem? {
        guard let url = URL(string: urlString) else { return nil }
        return WebDAVItem.make(url: url, name: name, isDirectory: false)
    }

    var progressText: String {
        let total = max(pageCount, 1)
        let current = min(page + 1, total)
        return "第 \(current) / \(total) 页"
    }
}
