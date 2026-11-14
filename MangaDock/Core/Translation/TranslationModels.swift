import Foundation
import CoreGraphics

/// 归一化坐标（0…1，**原点左上**）。
///
/// OCR 拿到的 boundingBox 是左下原点的，这里统一翻过来，之后所有层
/// （解码尺寸、fit 后的屏幕尺寸、条漫的整章坐标系）都用同一个矩形换算，
/// 不用再到每处记得翻一次 Y。
struct NormalizedRect: Codable, Equatable {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat

    init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(_ rect: CGRect) {
        self.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }

    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    var center: CGPoint { CGPoint(x: x + width / 2, y: y + height / 2) }

    /// 向外膨胀（画布坐标，不是像素）。
    func inflated(by amount: CGFloat) -> NormalizedRect {
        NormalizedRect(x: x - amount,
                       y: y - amount,
                       width: width + amount * 2,
                       height: height + amount * 2)
    }

    func union(_ other: NormalizedRect) -> NormalizedRect {
        let a = cgRect, b = other.cgRect
        return NormalizedRect(a.union(b))
    }

    func intersects(_ other: NormalizedRect) -> Bool {
        cgRect.intersects(other.cgRect)
    }

    /// 映射到某个实际尺寸的坐标系。
    func scaled(to size: CGSize) -> CGRect {
        CGRect(x: x * size.width,
               y: y * size.height,
               width: width * size.width,
               height: height * size.height)
    }

    /// 把外层坐标系里的一个裁剪矩形还原成归一化矩形（用于裁剪子图）。
    func clamped() -> NormalizedRect {
        let minX = max(0, min(x, 1))
        let minY = max(0, min(y, 1))
        let maxX = max(minX, min(x + width, 1))
        let maxY = max(minY, min(y + height, 1))
        return NormalizedRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// 一页里的一块文字，通常对应一个对话气泡或一个旁白框。
struct TextBlock: Codable, Identifiable, Equatable {
    var id: Int
    /// OCR 原文。
    var source: String
    /// 译文。还在翻译中时是 nil。
    var translated: String?
    var rect: NormalizedRect
    /// 原文是否竖排（日漫/韩漫常见的列书写）。
    var vertical: Bool
    /// 检测到的语种 BCP-47，可能为空。
    var language: String?

    var display: String {
        let text = (translated ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? source : text
    }

    var isTranslated: Bool {
        !((translated ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}

/// 一页的完整结果：文字位置 + 译文。
struct PageTranslation: Codable, Equatable {
    var blocks: [TextBlock]
    /// 整页的主导语种，用来决定 `TranslationSession` 的源语言。
    var dominantLanguage: String?
    var targetLanguage: String
    var updatedAt: Date

    var translatedCount: Int { blocks.filter { $0.isTranslated }.count }
    var isFullyTranslated: Bool {
        !blocks.isEmpty && blocks.allSatisfy { $0.isTranslated }
    }
}

/// 翻译流水线的阶段，UI 用它决定角标文案和转圈。
enum TranslationPhase: Equatable {
    case idle
    case recognizing
    case translating
    case ready
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .recognizing, .translating: return true
        default: return false
        }
    }

    var label: String {
        switch self {
        case .idle: return ""
        case .recognizing: return "识别文字…"
        case .translating: return "翻译中…"
        case .ready: return "已翻译"
        case .failed(let message): return message
        }
    }
}

/// 一页在内存里的状态。
struct PageTranslationState: Equatable {
    var blocks: [TextBlock] = []
    var phase: TranslationPhase = .idle

    var isVisible: Bool { !blocks.isEmpty }
}
