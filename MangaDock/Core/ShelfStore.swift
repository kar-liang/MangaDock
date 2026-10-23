import Foundation
import SwiftUI

struct ShelfEntry: Codable, Identifiable, Hashable {
    var urlString: String
    var name: String
    var isDirectory: Bool
    var size: Int64
    var addedAt: Date

    var id: String { urlString }

    var item: WebDAVItem? {
        guard let url = URL(string: urlString) else { return nil }
        return WebDAVItem(url: url, name: name, isDirectory: isDirectory, size: size, modified: nil)
    }
}

/// The bookshelf is a curated list stored locally — the WebDAV tree stays raw.
/// Entries keep enough metadata to render without touching the network.
final class ShelfStore: ObservableObject {
    static let shared = ShelfStore()

    @Published private(set) var entries: [ShelfEntry] = []
    @Published private(set) var lastMessage: String?

    private let storageKey = "mangadock.shelf"
    private let defaults = UserDefaults.standard

    private init() {
        load()
    }

    var items: [WebDAVItem] {
        entries.compactMap { $0.item }
    }

    var count: Int { entries.count }

    func contains(_ item: WebDAVItem) -> Bool {
        entries.contains { $0.urlString == item.url.absoluteString }
    }

    func toggle(_ item: WebDAVItem) {
        if contains(item) {
            remove(item)
        } else {
            add(item)
        }
    }

    func add(_ item: WebDAVItem) {
        guard item.isDirectory || item.isArchive || item.isPDF else { return }
        guard !contains(item) else { return }

        let entry = ShelfEntry(urlString: item.url.absoluteString,
                               name: item.name,
                               isDirectory: item.isDirectory,
                               size: item.size,
                               addedAt: Date())
        entries.insert(entry, at: 0)
        lastMessage = "已加入书架：\(item.displayName)"
        save()
    }

    func remove(_ item: WebDAVItem) {
        let before = entries.count
        entries.removeAll { $0.urlString == item.url.absoluteString }
        guard entries.count != before else { return }
        lastMessage = "已移出书架：\(item.displayName)"
        save()
    }

    func remove(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) where index < entries.count {
            entries.remove(at: index)
        }
        lastMessage = "已移出书架"
        save()
    }

    func clear() {
        guard !entries.isEmpty else { return }
        entries.removeAll()
        lastMessage = "书架已清空"
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: storageKey)
        }
    }

    private func load() {
        guard let data = defaults.data(forKey: storageKey),
              let list = try? JSONDecoder().decode([ShelfEntry].self, from: data) else { return }
        entries = list
    }
}
