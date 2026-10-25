import Foundation

/// Comics imported from the iPhone Files app, stored in the app's Documents
/// directory. Read locally — no WebDAV involved.
enum LocalLibrary {
    static var directory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("LocalComics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Scans the local library for readable comics (CBZ / ZIP / PDF).
    static func items() -> [WebDAVItem] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
        return files
            .filter { isSupported($0) }
            .sorted { NaturalSort.less($0.lastPathComponent, $1.lastPathComponent) }
            .map { WebDAVItem(url: $0, name: $0.lastPathComponent,
                              isDirectory: false, size: 0, modified: nil) }
    }

    static func isSupported(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ComicFileTypes.archiveExtensions.contains(ext)
            || ComicFileTypes.pdfExtensions.contains(ext)
    }

    /// Copies a security-scoped file into the library. Returns false on an
    /// unsupported type or a copy failure.
    @discardableResult
    static func importFile(from source: URL) -> Bool {
        guard isSupported(source) else { return false }

        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }

        var final = directory.appendingPathComponent(source.lastPathComponent)
        var counter = 1
        while FileManager.default.fileExists(atPath: final.path) {
            let base = source.deletingPathExtension().lastPathComponent
            let ext = source.pathExtension
            final = directory.appendingPathComponent("\(base)-\(counter).\(ext)")
            counter += 1
        }

        do {
            try FileManager.default.copyItem(at: source, to: final)
            return true
        } catch {
            return false
        }
    }

    static func remove(_ item: WebDAVItem) {
        try? FileManager.default.removeItem(at: item.url)
    }
}
