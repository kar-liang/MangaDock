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

    /// Title without the format suffix — "第01话.cbz" reads as "第01话".
    var displayName: String {
        if isDirectory { return name }
        let stripped = (name as NSString).deletingPathExtension
        return stripped.isEmpty ? name : stripped
    }

    var isImage: Bool {
        ComicFileTypes.imageExtensions.contains(fileExtension)
    }

    var isArchive: Bool {
        ComicFileTypes.archiveExtensions.contains(fileExtension)
    }

    var isPDF: Bool {
        ComicFileTypes.pdfExtensions.contains(fileExtension)
    }

    /// Anything the reader can open.
    var isReadable: Bool {
        isArchive || isPDF || isImage
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
    static let pdfExtensions: Set<String> = ["pdf"]
    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "webp", "gif", "heic", "heif", "bmp", "tif", "tiff"
    ]
}

enum NavTarget: Hashable {
    /// Raw directory browsing (文件 tab).
    case folder(WebDAVItem)
    /// A shelf series: opening it shows the chapter list.
    case series(WebDAVItem)
    /// Straight into the reader.
    case comic(WebDAVItem)
    /// FaceID-gated hidden shelf.
    case privateShelf
    /// Local files imported from the Files app.
    case localLibrary
}

struct RecentEntry: Identifiable, Codable, Hashable {
    var urlString: String
    var name: String
    var page: Int
    var pageCount: Int
    var updatedAt: Date
    /// nil for entries written before 1.1
    var isFolder: Bool?

    var id: String { urlString }

    var displayName: String {
        if isFolder == true { return name }
        let stripped = (name as NSString).deletingPathExtension
        return stripped.isEmpty ? name : stripped
    }

    var item: WebDAVItem? {
        guard let url = URL(string: urlString) else { return nil }
        return WebDAVItem(url: url, name: name, isDirectory: isFolder ?? false,
                          size: 0, modified: nil)
    }

    var progressText: String {
        let total = max(pageCount, 1)
        let current = min(page + 1, total)
        return "第 \(current) / \(total) 页"
    }
}
