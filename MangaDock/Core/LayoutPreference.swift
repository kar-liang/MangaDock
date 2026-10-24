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
    case paged
    case vertical

    var id: String { rawValue }

    var title: String {
        switch self {
        case .paged: return "左右翻页"
        case .vertical: return "上下滚动"
        }
    }
}
