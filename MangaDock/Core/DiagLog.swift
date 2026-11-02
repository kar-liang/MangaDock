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

// MARK: - Timing helpers

/// 从某个时间点到现在的毫秒数，日志里的耗时字段统一用它。
func diagElapsed(_ since: Date) -> String {
    "\(Int(Date().timeIntervalSince(since) * 1000))ms"
}

/// 字节数的人类可读形式。网络日志里 1200000 不如 1.2MB 直观。
func diagBytes(_ count: Int) -> String {
    let kb = Double(count) / 1024
    if kb < 1 { return "\(count)B" }
    if kb < 1024 { return String(format: "%.0fKB", kb) }
    return String(format: "%.1fMB", kb / 1024)
}

/// 在非主线程 / 非 MainActor 上下文里记日志（网络层、解码层都在后台）。
///
/// `diag` 是 `@MainActor` 的，跨 actor 直接 await 会把请求路径拖慢一个 hop，
/// 所以这里 fire-and-forget：日志顺序可能差个几毫秒，但绝不影响请求本身。
func diagAsync(_ category: String, _ text: @autoclosure @escaping () -> String) {
    guard DiagLog.shared.isEnabled else { return }
    Task { @MainActor in
        DiagLog.shared.log(category, text())
    }
}

// MARK: - Crash / memory

extension DiagLog {
    /// 「这一轮 App 还活着」的标记。
    /// 崩溃或被系统强杀时没人来清它，下次启动看到它还在 = 上次是异常退出。
    static let sessionKey = "mangadock.diagnostics.sessionActive"

    /// 启动时调一次：判断上一轮是不是正常结束的。
    @MainActor
    static func markSessionStart() {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: sessionKey) {
            shared.log("crash", "上次未正常退出（崩溃、被系统回收，或强杀）· mem=\(memoryFootprint())")
        }
        defaults.set(true, forKey: sessionKey)
        shared.log("app", "启动 · mem=\(memoryFootprint())")
    }

    /// 进后台时调：这一轮算正常收尾，把标记清掉。
    static func markSessionClean() {
        UserDefaults.standard.set(false, forKey: sessionKey)
    }

    /// 当前进程占用的物理内存。iPad mini 6 那种闪退基本都跟它有关，
    /// 光看「崩了」没用，得知道崩的时候占了多少。
    static func memoryFootprint() -> String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size
                                           / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return "?" }
        return String(format: "%.0fMB", Double(info.phys_footprint) / 1024 / 1024)
    }
}
