import Foundation

/// 翻译结果的磁盘缓存。
///
/// 分两层存：
/// - **OCR 层**：只存识别出来的原文和位置，和语种无关。换目标语言不用重跑识别。
/// - **译文层**：按目标语言分开存。
///
/// 粒度是**整章一个文件**，不是一页一个。一话 20 页就是 20 个小 JSON 文件，
/// 看一千话能攒出两万个 inode —— iOS 上没必要这么糟蹋。整章一个文件，
/// 读改写的代价完全能接受（一页几 KB）。
enum TranslationCache {

    private static var directory: URL {
        CacheManager.root.appendingPathComponent("translate", isDirectory: true)
    }

    private struct OCRFile: Codable {
        var pages: [String: [TextBlock]]
    }

    private struct TextFile: Codable {
        var target: String
        var pages: [String: [String: String]]   // page -> blockID -> 译文
    }

    // MARK: - OCR 层

    static func loadOCR(chapter: String, page: Int) -> [TextBlock]? {
        guard let file = loadOCRFile(chapter: chapter) else { return nil }
        return file.pages[String(page)]
    }

    static func storeOCR(chapter: String, page: Int, blocks: [TextBlock]) {
        var file = loadOCRFile(chapter: chapter) ?? OCRFile(pages: [:])
        file.pages[String(page)] = blocks
        write(file, to: ocrURL(chapter: chapter))
    }

    private static func loadOCRFile(chapter: String) -> OCRFile? {
        guard let data = try? Data(contentsOf: ocrURL(chapter: chapter)) else { return nil }
        return try? JSONDecoder().decode(OCRFile.self, from: data)
    }

    // MARK: - 译文层

    /// 取回某一页的译文映射。键是 `TextBlock.id`。
    static func loadTranslations(chapter: String,
                                 page: Int,
                                 target: String) -> [Int: String] {
        guard let file = loadTextFile(chapter: chapter, target: target),
              let pageMap = file.pages[String(page)] else { return [:] }
        var result: [Int: String] = [:]
        for (key, value) in pageMap {
            if let id = Int(key) { result[id] = value }
        }
        return result
    }

    static func storeTranslations(chapter: String,
                                  page: Int,
                                  target: String,
                                  translations: [Int: String]) {
        guard !translations.isEmpty else { return }
        var file = loadTextFile(chapter: chapter, target: target) ?? TextFile(target: target, pages: [:])
        var pageMap = file.pages[String(page)] ?? [:]
        for (id, text) in translations { pageMap[String(id)] = text }
        file.pages[String(page)] = pageMap
        write(file, to: textURL(chapter: chapter, target: target))
    }

    private static func loadTextFile(chapter: String, target: String) -> TextFile? {
        guard let data = try? Data(contentsOf: textURL(chapter: chapter, target: target)) else { return nil }
        return try? JSONDecoder().decode(TextFile.self, from: data)
    }

    // MARK: - 文件

    private static func ocrURL(chapter: String) -> URL {
        directory.appendingPathComponent("ocr-" + CacheManager.hash(chapter) + ".json")
    }

    private static func textURL(chapter: String, target: String) -> URL {
        directory.appendingPathComponent("txt-" + CacheManager.hash(chapter + "#" + target) + ".json")
    }

    private static func write<T: Encodable>(_ value: T, to url: URL) {
        CacheManager.ensure(directory)
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - 维护

    static func sizeOnDisk() -> Int64 {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for file in files {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }

    static func formattedSize() -> String {
        let bytes = sizeOnDisk()
        guard bytes > 0 else { return "0 MB" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: directory)
    }
}
