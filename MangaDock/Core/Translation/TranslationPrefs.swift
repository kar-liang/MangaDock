import Foundation

/// 目标语言。全走 Apple 端上模型，可选集合跟着系统走，
/// 这里只列中日英韩四个方向 —— 老大看的就是这四种原文。
enum TranslationTarget: String, CaseIterable, Identifiable {
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case english = "en"
    case japanese = "ja"
    case korean = "ko"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁体中文"
        case .english: return "English"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        }
    }

    var language: Locale.Language { Locale.Language(identifier: rawValue) }
}

/// 原文语种提示。自动模式让 Vision 自己判断，指定模式在识别率上更稳。
enum TranslationSourceHint: String, CaseIterable, Identifiable {
    case auto, japanese, english, korean, chinese

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "自动识别"
        case .japanese: return "日文优先"
        case .english: return "英文优先"
        case .korean: return "韩文优先"
        case .chinese: return "中文优先"
        }
    }

    /// 送给 Vision 的识别语言列表，顺序有意义：靠前的优先。
    var visionLanguages: [String] {
        switch self {
        case .auto: return ["ja-JP", "ko-KR", "zh-Hans", "en-US"]
        case .japanese: return ["ja-JP", "en-US"]
        case .english: return ["en-US"]
        case .korean: return ["ko-KR", "en-US"]
        case .chinese: return ["zh-Hans", "zh-Hant", "en-US"]
        }
    }

    /// 二次精化（裁剪放大重识别）时用的单语言，自动模式下由主导语种决定。
    var forcedLanguage: String? {
        switch self {
        case .auto: return nil
        case .japanese: return "ja-JP"
        case .english: return "en-US"
        case .korean: return "ko-KR"
        case .chinese: return "zh-Hans"
        }
    }
}

/// 翻译相关的偏好，全部走 UserDefaults，和项目里其它设置一个路子。
enum TranslationPrefs {
    static let enabledKey = "mangadock.translate.enabled"
    static let autoKey = "mangadock.translate.auto"
    static let targetKey = "mangadock.translate.target"
    static let sourceKey = "mangadock.translate.source"
    static let fontSizeKey = "mangadock.translate.fontSize"
    static let refineKey = "mangadock.translate.refine"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    /// 打开翻译后翻页自动翻下一页。默认开 —— 手动逐页点太累。
    static var autoTranslate: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: autoKey) == nil { return true }
        return defaults.bool(forKey: autoKey)
    }

    static var target: TranslationTarget {
        let raw = UserDefaults.standard.string(forKey: targetKey) ?? ""
        return TranslationTarget(rawValue: raw) ?? .simplifiedChinese
    }

    static var sourceHint: TranslationSourceHint {
        let raw = UserDefaults.standard.string(forKey: sourceKey) ?? ""
        return TranslationSourceHint(rawValue: raw) ?? .auto
    }

    /// 卡片基准字号（pt，@1x 画布上）。缩放时按比例补偿。
    static var fontSize: CGFloat {
        let stored = UserDefaults.standard.double(forKey: fontSizeKey)
        return stored > 0 ? CGFloat(stored) : 14
    }

    /// 是否对小字区域做裁剪放大二次识别。慢一些，但小气泡明显更准。
    static var refineSmallText: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: refineKey) == nil { return true }
        return defaults.bool(forKey: refineKey)
    }
}
