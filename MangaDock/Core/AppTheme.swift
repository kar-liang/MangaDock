import SwiftUI

/// 主题色。只改强调色（按钮、选中态、图标、标签），不动深浅模式 ——
/// 深浅是另一套（AppearanceMode），两者独立。
enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case blue
    case purple
    case pink
    case red
    case orange
    case green
    case teal
    case graphite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .blue: return "海蓝"
        case .purple: return "紫罗兰"
        case .pink: return "樱粉"
        case .red: return "朱红"
        case .orange: return "暖橙"
        case .green: return "森林绿"
        case .teal: return "青碧"
        case .graphite: return "石墨"
        }
    }

    /// 用于预览的色块。`system` 用系统强调色。
    var color: Color {
        switch self {
        case .system: return .accentColor
        case .blue: return .blue
        case .purple: return .purple
        case .pink: return .pink
        case .red: return .red
        case .orange: return .orange
        case .green: return .green
        case .teal: return .teal
        case .graphite: return Color(white: 0.42)
        }
    }

    /// 交给 `.tint()` 的值。`system` 返回 nil，保持系统默认。
    var tint: Color? {
        self == .system ? nil : color
    }
}
