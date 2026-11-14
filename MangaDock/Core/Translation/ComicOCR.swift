import Foundation
import UIKit
import Vision
import NaturalLanguage

/// 端上 OCR。全部走 Apple Vision，不联网、不传图。
///
/// 两遍识别：
/// 1. **整页**：拿到所有文本行的位置。这一步位置准、字数全，但小字容易糊。
/// 2. **逐气泡精化**：把每个合并后的气泡裁出来、放大 2.5 倍、用单语言再识别一次。
///    这一遍是小字能否认出字的关键 —— 每个字只有几像素的时候，整页识别必崩。
///
/// 第二遍改成单语言（由第一遍判断出的主导语种决定），顺带解决了
/// 「日文汉字被当成简体中文」这个最常见的误判。
enum ComicOCR {

    struct Result {
        var blocks: [TextBlock]
        var dominantLanguage: String?
    }

    struct OCRError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// 整页识别 + 精化。
    /// - Parameters:
    ///   - image: 已经限制过尺寸的页面图。
    ///   - hint: 用户在设置里选的原文语种提示。
    ///   - refine: 是否做第二遍。关掉能快一半，代价是小字漏识别。
    static func recognize(image: UIImage,
                          hint: TranslationSourceHint,
                          refine: Bool) async -> Result {
        guard let cgImage = image.cgImage else {
            return Result(blocks: [], dominantLanguage: nil)
        }

        // 第一遍：整页。
        let languages = hint.visionLanguages
        let firstPass = (try? recognizeLines(in: cgImage, languages: languages)) ?? []
        guard !firstPass.isEmpty else {
            return Result(blocks: [], dominantLanguage: nil)
        }

        var groups = BubbleGrouper.group(firstPass)
        guard !groups.isEmpty else {
            return Result(blocks: [], dominantLanguage: nil)
        }

        // 主导语种：先看假名，再退回 NaturalLanguage。
        let joined = groups.map { $0.text }.joined(separator: " ")
        let dominant = dominantLanguage(of: joined, hint: hint)

        // 第二遍：逐气泡裁剪放大重识别。
        if refine {
            let forced = hint.forcedLanguage ?? visionLanguage(for: dominant)
            if let forced,
               let refined = await refineGroups(groups,
                                                in: cgImage,
                                                imageSize: image.size,
                                                language: forced) {
                groups = refined
            }
        }

        var blocks: [TextBlock] = []
        blocks.reserveCapacity(groups.count)
        for (index, group) in groups.enumerated() {
            let text = group.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            blocks.append(TextBlock(id: index,
                                    source: text,
                                    translated: nil,
                                    rect: group.rect.clamped(),
                                    vertical: group.vertical,
                                    language: dominant))
        }

        return Result(blocks: blocks, dominantLanguage: dominant)
    }

    // MARK: - 第二遍

    /// 每个气泡裁出来放大重识别。并发 3 路 —— Vision 吃满 GPU 会互相拖慢，
    /// 3 路在 A17 上差不多是吞吐最高的点。
    private static func refineGroups(_ groups: [BubbleGrouper.Group],
                                     in cgImage: CGImage,
                                     imageSize: CGSize,
                                     language: String) async -> [BubbleGrouper.Group]? {
        let pixelWidth = CGFloat(cgImage.width)
        let pixelHeight = CGFloat(cgImage.height)
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }

        var output = groups
        var changed = false

        await withTaskGroup(of: (Int, String?).self) { group in
            var pending = Array(groups.indices)
            let concurrency = 3

            func addNext(_ taskGroup: inout TaskGroup<(Int, String?)>) -> Bool {
                guard let index = pending.first else { return false }
                pending.removeFirst()
                let source = groups[index]
                taskGroup.addTask {
                    let text = refinedText(for: source,
                                           cgImage: cgImage,
                                           pixelSize: CGSize(width: pixelWidth, height: pixelHeight),
                                           language: language)
                    return (index, text)
                }
                return true
            }

            for _ in 0..<concurrency { if !addNext(&group) { break } }

            for await (index, text) in group {
                if let text, !text.isEmpty {
                    let before = groups[index].text.count
                    // 新结果明显更短说明裁剪时切掉了内容（气泡压线、跨框），
                    // 这种情况保留第一遍的整段，宁可少几个字也别丢半句。
                    if text.count >= max(2, Int(Double(before) * 0.6)) {
                        output[index].text = text
                        changed = true
                    }
                }
                _ = addNext(&group)
            }
        }

        return changed ? output : nil
    }

    private static func refinedText(for group: BubbleGrouper.Group,
                                    cgImage: CGImage,
                                    pixelSize: CGSize,
                                    language: String) -> String? {
        // 往外扩一圈，避免字被切边。竖排偏瘦的气泡横向多给一点。
        let padX = max(group.rect.width * 0.12, 0.004)
        let padY = max(group.rect.height * 0.06, 0.004)
        let padded = group.rect.inflated(by: max(padX, padY) * 0.6).clamped()
        let pixelRect = padded.scaled(to: pixelSize).integral
        guard pixelRect.width >= 12, pixelRect.height >= 12,
              let cropped = cgImage.cropping(to: pixelRect) else { return nil }

        guard let scaled = upscale(cropped, factor: upscaleFactor(for: pixelRect)) else { return nil }

        let lines = (try? recognizeLines(in: scaled, languages: [language])) ?? []
        guard !lines.isEmpty else { return nil }
        let joined = BubbleGrouper.join(lines, vertical: group.vertical)
        return joined.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 小区域放得越狠越好，但上限 3 倍 —— 再多只是变慢，字不会更清楚。
    private static func upscaleFactor(for pixelRect: CGRect) -> CGFloat {
        let shortSide = min(pixelRect.width, pixelRect.height)
        if shortSide < 120 { return 3 }
        if shortSide < 260 { return 2.5 }
        if shortSide < 500 { return 2 }
        return 1
    }

    private static func upscale(_ image: CGImage, factor: CGFloat) -> CGImage? {
        guard factor > 1.01 else { return image }
        let width = Int(CGFloat(image.width) * factor)
        let height = Int(CGFloat(image.height) * factor)
        guard width > 0, height > 0, width * height < 40_000_000 else { return image }

        guard let context = CGContext(data: nil,
                                     width: width,
                                     height: height,
                                     bitsPerComponent: 8,
                                     bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return image
        }
        context.interpolationQuality = .high
        // 白底：漫画扫描件常带透明边，OCR 在透明底上会掉字。
        context.setFillColor(UIColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    // MARK: - Vision 封装

    private static func recognizeLines(in cgImage: CGImage,
                                       languages: [String]) throws -> [BubbleGrouper.Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // 自动语言检测和显式语言列表互斥，这里走显式列表：漫画一页通常单语种，
        // 显式指定比自动检测稳，也不会把日文汉字判成中文。
        request.automaticallyDetectsLanguage = false
        request.recognitionLanguages = supportedLanguages(preferred: languages)

        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        try handler.perform([request])

        guard let observations = request.results else { return [] }
        return observations.compactMap { observation -> BubbleGrouper.Line? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            // Vision 的 boundingBox 是左下原点，统一翻成左上原点。
            let rect = NormalizedRect(x: box.minX,
                                      y: 1 - box.maxY,
                                      width: box.width,
                                      height: box.height)
            return BubbleGrouper.Line(text: candidate.string,
                                      rect: rect,
                                      confidence: candidate.confidence)
        }
    }

    /// 传入的语言里有系统不支持的会直接抛异常，这里先跟系统对一遍。
    private static func supportedLanguages(preferred: [String]) -> [String] {
        let supported = (try? VNRecognizeTextRequest.supportedRecognitionLanguages(
            for: .accurate,
            revision: VNRecognizeTextRequestRevision3
        )) ?? []
        guard !supported.isEmpty else { return preferred }
        let filtered = preferred.filter { supported.contains($0) }
        return filtered.isEmpty ? ["en-US"] : filtered
    }

    // MARK: - 语种判断

    /// 判断整页主导语种。
    ///
    /// 优先数假名：日文里的汉字和简体中文长得一样，NaturalLanguage 在
    /// 短文本上经常判成 zh，但只要有几个假名就一定不是中文。
    private static func dominantLanguage(of text: String, hint: TranslationSourceHint) -> String? {
        let meaningful = text.filter { !$0.isWhitespace }
        guard meaningful.count >= 4 else { return nil }

        let kana = meaningful.filter { character in
            guard let scalar = character.unicodeScalars.first else { return false }
            return (0x3040...0x30FF).contains(scalar.value)
        }.count
        if kana >= 3 { return "ja" }

        let hangul = meaningful.filter { character in
            guard let scalar = character.unicodeScalars.first else { return false }
            return (0xAC00...0xD7AF).contains(scalar.value)
        }.count
        if hangul >= 3 { return "ko" }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(meaningful)
        if let detected = recognizer.dominantLanguage {
            switch detected {
            case .japanese: return "ja"
            case .korean: return "ko"
            case .simplifiedChinese, .traditionalChinese: return "zh"
            case .english: return "en"
            default:
                if hint.forcedLanguage == nil { return detected.rawValue }
            }
        }
        return hint.forcedLanguage.map { visionLanguage(for: $0) ?? $0 }
    }

    /// "ja" / "ja-JP" 统一成 Vision 认的写法。
    static func visionLanguage(for code: String?) -> String? {
        guard let code, !code.isEmpty else { return nil }
        if code.contains("-") { return code }
        switch code.lowercased() {
        case "ja": return "ja-JP"
        case "ko": return "ko-KR"
        case "zh", "zh-hans": return "zh-Hans"
        case "zh-hant": return "zh-Hant"
        case "en": return "en-US"
        default: return code
        }
    }
}
