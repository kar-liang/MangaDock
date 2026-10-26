import Foundation
import SwiftUI

/// On-device diagnostic log.
///
/// Exists because "点开 770 话进去了别的章节" can't be diagnosed from a
/// screenshot: we need the actual URL, the series index the reader computed,
/// and where the page bytes came from (download / cache / network).
///
/// Small ring buffer in memory, appended to a file so a relaunch or crash
/// doesn't lose the trail, and shown in Settings so it can be copied out.
/// Not `@MainActor` on purpose: views need `DiagLog.shared` in a stored
/// property initializer (`@ObservedObject`), which is a nonisolated context.
/// The mutating methods are annotated instead.
final class DiagLog: ObservableObject {
    static let shared = DiagLog()

    struct Entry: Identifiable, Hashable {
        let id = UUID()
        let at: Date
        let category: String
        let text: String
    }

    @Published private(set) var entries: [Entry] = []

    /// 日志默认关闭。一直开着会持续写盘，翻页时尤其明显；
    /// 需要抓问题时在设置里打开，抓完关掉。
    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
        }
    }

    static let enabledKey = "mangadock.diagnostics.enabled"

    private let maxEntries = 300
    private let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("diagnostics.log")
    }

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        loadTail()
    }

    // MARK: - Writing

    @MainActor
    func log(_ category: String, _ text: String) {
        guard isEnabled else { return }
        let entry = Entry(at: Date(), category: category, text: text)
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        appendToFile(entry)
    }

    private func appendToFile(_ entry: Entry) {
        let line = "\(stampFormatter.string(from: entry.at)) [\(entry.category)] \(entry.text)\n"
        let url = fileURL
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func loadTail() {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n").suffix(maxEntries)
        entries = lines.map { line in
            // Lines are "HH:mm:ss.SSS [cat] text"; timestamp isn't parseable
            // across days, so keep the text and mark it as restored.
            Entry(at: Date(), category: "restored", text: String(line))
        }
    }

    // MARK: - Reading

    /// Everything as plain text, newest last — what gets copied/shared.
    var exportText: String {
        entries.map { entry in
            "\(stampFormatter.string(from: entry.at)) [\(entry.category)] \(entry.text)"
        }.joined(separator: "\n")
    }

    @MainActor
    func clear() {
        entries.removeAll()
        try? FileManager.default.removeItem(at: fileURL)
    }
}

// MARK: - Convenience

/// Short name so call sites stay readable.
@MainActor
func diag(_ category: String, _ text: @autoclosure () -> String) {
    DiagLog.shared.log(category, text())
}
