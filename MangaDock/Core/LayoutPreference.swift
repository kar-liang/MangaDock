import Foundation

enum LayoutMode: String {
    case list
    case grid
}

/// Remembers list/grid per folder — home can be a grid while a chapter list
/// stays a plain list.
@MainActor
final class LayoutPreference {
    static let shared = LayoutPreference()

    private let mapKey = "mangadock.layoutByFolder"
    private let defaultKey = "mangadock.defaultLayout"
    private let defaults = UserDefaults.standard
    private var map: [String: String]

    private init() {
        map = (defaults.dictionary(forKey: mapKey) as? [String: String]) ?? [:]
    }

    var defaultMode: LayoutMode {
        get { LayoutMode(rawValue: defaults.string(forKey: defaultKey) ?? "") ?? .grid }
        set { defaults.set(newValue.rawValue, forKey: defaultKey) }
    }

    private let shelfKey = "mangadock.shelfLayout"

    var shelfMode: LayoutMode {
        get { LayoutMode(rawValue: defaults.string(forKey: shelfKey) ?? "") ?? .grid }
        set { defaults.set(newValue.rawValue, forKey: shelfKey) }
    }

    func mode(for folderKey: String) -> LayoutMode {
        LayoutMode(rawValue: map[folderKey] ?? "") ?? defaultMode
    }

    func setMode(_ mode: LayoutMode, for folderKey: String) {
        map[folderKey] = mode.rawValue
        defaults.set(map, forKey: mapKey)
    }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "明亮"
        case .dark: return "黑暗"
        }
    }
}

enum ReaderMode: String, CaseIterable, Identifiable {
    /// 普通模式：从左往右翻（欧美/国漫习惯）
    case paged
    /// 日漫模式：从右往左翻（书从右装订）
    case rightToLeft
    /// 条漫模式：上下连续滚动
    case vertical

    var id: String { rawValue }

    var title: String {
        switch self {
        case .paged: return "普通模式"
        case .rightToLeft: return "日漫模式"
        case .vertical: return "条漫模式"
        }
    }

    var detail: String {
        switch self {
        case .paged: return "左右翻页，从左往右"
        case .rightToLeft: return "左右翻页，从右往左（日漫）"
        case .vertical: return "上下连续滚动"
        }
    }

    /// 是否左右翻页（普通 + 日漫）
    var isPaged: Bool { self != .vertical }
}

/// 后端服务器类型。
enum ServerKind: String, CaseIterable, Identifiable {
    case webdav
    case komga

    var id: String { rawValue }

    var title: String {
        switch self {
        case .webdav: return "WebDAV"
        case .komga: return "Komga"
        }
    }

    var detail: String {
        switch self {
        case .webdav: return "直接读服务器上的漫画文件夹（NAS 常见）"
        case .komga: return "读 Komga 的书库，封面和分类由 Komga 管理"
        }
    }
}
