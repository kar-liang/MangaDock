import Foundation
import SwiftUI

/// Tracks which chapters are finished.
///
/// Two layers:
///  * automatic — reading to the last page counts as read (derived from the
///    reading progress, nothing to store);
///  * manual — an explicit "标为已读 / 标为未读" overrides the automatic answer.
///    Stored as `true`/`false` so "unread despite being at page 18/18" works.
///
/// Not `@MainActor` on purpose: views take it as
/// `@ObservedObject private var reads = ReadStateStore.shared`, and that
/// property initializer is a nonisolated context.
final class ReadStateStore: ObservableObject {
    static let shared = ReadStateStore()

    /// url string → explicit mark. Absent means "let the progress decide".
    @Published private(set) var marks: [String: Bool] = [:]

    private let defaultsKey = "mangadock.readMarks"

    private init() {
        load()
    }

    /// Explicit override, or nil when the automatic rule should be used.
    func mark(for url: URL) -> Bool? {
        marks[url.absoluteString]
    }

    /// Final answer for a chapter: manual override wins, otherwise "reached the
    /// last page".
    func isRead(_ url: URL, progress: RecentEntry?) -> Bool {
        if let manual = mark(for: url) { return manual }
        guard let progress, progress.pageCount > 0 else { return false }
        return progress.page >= progress.pageCount - 1
    }

    @MainActor
    func setRead(_ read: Bool, for url: URL) {
        marks[url.absoluteString] = read
        save()
    }

    /// Drops the override so the progress decides again.
    @MainActor
    func clearOverride(for url: URL) {
        guard marks.removeValue(forKey: url.absoluteString) != nil else { return }
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let dict = try? JSONDecoder().decode([String: Bool].self, from: data) else {
            return
        }
        marks = dict
    }

    private func save() {
        if let data = try? JSONEncoder().encode(marks) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
