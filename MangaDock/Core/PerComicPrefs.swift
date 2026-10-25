import Foundation

/// Per-comic preferences keyed by the comic's URL. Chapter order and AI
/// enhancement are remembered per comic instead of globally; the global
/// settings act as the default for comics never touched.
enum PerComicPrefs {
    private static func key(_ field: String, _ url: URL) -> String {
        "mangadock.percomic.\(field).\(url.absoluteString)"
    }

    // MARK: - Chapter order (true = descending)

    static func chapterOrderDescending(for url: URL) -> Bool {
        UserDefaults.standard.bool(forKey: key("order", url))
    }

    static func setChapterOrder(_ descending: Bool, for url: URL) {
        UserDefaults.standard.set(descending, forKey: key("order", url))
    }

    // MARK: - Enhance on/off

    static func enhanceEnabled(for url: URL, default defaultValue: Bool) -> Bool {
        if let v = UserDefaults.standard.object(forKey: key("enhance", url)) as? Bool {
            return v
        }
        return defaultValue
    }

    static func setEnhance(_ on: Bool, for url: URL) {
        UserDefaults.standard.set(on, forKey: key("enhance", url))
    }

    // MARK: - AI scale (2 or 4)

    static func aiScale(for url: URL, default defaultValue: Int) -> Int {
        let raw = UserDefaults.standard.integer(forKey: key("scale", url))
        return (raw == 4 || raw == 2) ? raw : defaultValue
    }

    static func setAIScale(_ scale: Int, for url: URL) {
        UserDefaults.standard.set(scale, forKey: key("scale", url))
    }
}
