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

/// 翻译引擎。
///
/// `auto` 是默认：配了 API 就用大模型，没配就退回端上 —— 这样即使用户
/// 临时清空了 Key，也不会变成"点翻译没反应"。
enum TranslationEngine: String, CaseIterable, Identifiable {
    case auto, llm, onDevice

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "自动（有 Key 用大模型）"
        case .llm: return "大模型"
        case .onDevice: return "系统端上翻译"
        }
    }

    var detail: String {
        switch self {
        case .auto: return "配好接口就走大模型，没配就走系统端上模型"
        case .llm: return "质量最好，但台词文字会发到你填的那个接口"
        case .onDevice: return "完全离线，不出设备；质量一般，长句会翻得生硬"
        }
    }
}

/// 翻译相关的偏好，全部走 UserDefaults，和项目里其它设置一个路子。
/// 例外是 API Key —— 那个进 Keychain，不落 UserDefaults。
enum TranslationPrefs {
    static let enabledKey = "mangadock.translate.enabled"
    static let autoKey = "mangadock.translate.auto"
    static let targetKey = "mangadock.translate.target"
    static let sourceKey = "mangadock.translate.source"
    static let fontSizeKey = "mangadock.translate.fontSize"
    static let refineKey = "mangadock.translate.refine"
    static let engineKey = "mangadock.translate.engine"
    static let baseURLKey = "mangadock.translate.baseURL"
    static let modelKey = "mangadock.translate.model"

    /// Keychain 里的账号名。Key 本身不写进 UserDefaults、不写进任何日志。
    private static let apiKeyAccount = "translate.apiKey"

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

    // MARK: - 引擎

    static var engine: TranslationEngine {
        let raw = UserDefaults.standard.string(forKey: engineKey) ?? ""
        return TranslationEngine(rawValue: raw) ?? .auto
    }

    static var llmBaseURL: String {
        UserDefaults.standard.string(forKey: baseURLKey) ?? ""
    }

    static var llmModel: String {
        UserDefaults.standard.string(forKey: modelKey) ?? ""
    }

    static var llmAPIKey: String {
        Keychain.load(account: apiKeyAccount) ?? ""
    }

    static func saveAPIKey(_ value: String) {
        Keychain.save(value.trimmingCharacters(in: .whitespacesAndNewlines),
                      account: apiKeyAccount)
    }

    static var llmConfig: LLMConfig {
        LLMConfig(baseURL: llmBaseURL, apiKey: llmAPIKey, model: llmModel)
    }

    /// 这一页到底该用哪个引擎。
    static var usesLLM: Bool {
        switch engine {
        case .llm: return true
        case .onDevice: return false
        case .auto: return llmConfig.isConfigured
        }
    }
}
