import Foundation
import CoreGraphics

/// 把 Vision 吐出来的一堆「行」重新合并成「气泡」。
///
/// 为什么必须做这一步：Vision 对竖排日文/韩文会把**每一列**当成一个独立文本行，
/// 一页 8–15 个气泡会散成几十块。直接拿这些碎块去翻译，每个气泡的台词会被拆成
/// 三四段各自翻译，读出来完全不是人话。而且翻译接口要求「同一批文本语种一致」，
/// 碎块多了语言检测也更容易翻车。
///
/// 合并依据只有几何位置：膨胀后的矩形相交就认为是同一个气泡。膨胀量按块的
/// 短边比例算 —— 字越小膨胀越小，免得把相邻的两个气泡糊成一个。
enum BubbleGrouper {

    /// Vision 一行的原始结果。
    struct Line {
        var text: String
        var rect: NormalizedRect
        var confidence: Float

        /// 高明显大于宽，按竖排处理。阈值 1.25 是因为单个汉字/假名接近正方形，
        /// 2 个字以上的竖列才会明显瘦高。
        var looksVertical: Bool { rect.height > rect.width * 1.25 }
    }

    /// 合并后的一个气泡。
    struct Group {
        var text: String
        var rect: NormalizedRect
        var vertical: Bool
        var lineCount: Int
        var confidence: Float
    }

    /// 膨胀比例：短边的 0.75 倍。归一化坐标下一行字高约 0.02–0.05，
    /// 也就是往外扩约 0.015–0.037，够连上同一气泡内的列，又不至于跨气泡。
    private static let inflateRatio: CGFloat = 0.75
    private static let inflateMin: CGFloat = 0.005
    private static let inflateMax: CGFloat = 0.022

    /// 低于这个置信度的行直接丢掉 —— 但阈值不能高，漫画手写体普遍偏低，
    /// 卡太狠会把拟声词和强调字体全滤掉。
    private static let minConfidence: Float = 0.12

    // MARK: - 入口

    static func group(_ lines: [Line]) -> [Group] {
        let usable = lines.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.confidence >= minConfidence
                && $0.rect.width > 0 && $0.rect.height > 0
        }
        guard !usable.isEmpty else { return [] }
        guard usable.count > 1 else {
            let line = usable[0]
            return [Group(text: line.text, rect: line.rect, vertical: line.looksVertical,
                          lineCount: 1, confidence: line.confidence)]
        }

        // 并查集：膨胀后相交就连起来。
        var parent = Array(0..<usable.count)
        func find(_ i: Int) -> Int {
            var x = i
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
        }

        let padded = usable.map { line -> NormalizedRect in
            let base = min(line.rect.width, line.rect.height) * inflateRatio
            let pad = min(max(base, inflateMin), inflateMax)
            return line.rect.inflated(by: pad)
        }

        for i in 0..<usable.count {
            for j in (i + 1)..<usable.count where padded[i].intersects(padded[j]) {
                union(i, j)
            }
        }

        var buckets: [Int: [Line]] = [:]
        for i in 0..<usable.count {
            buckets[find(i), default: []].append(usable[i])
        }

        return buckets.values.compactMap { members in
            guard !members.isEmpty else { return nil }
            let rect = members.dropFirst().reduce(members[0].rect) { $0.union($1.rect) }
            let verticalCount = members.filter { $0.looksVertical }.count
            let vertical = verticalCount * 2 > members.count
            let text = join(members, vertical: vertical)
            guard !text.isEmpty else { return nil }
            let avgConfidence = members.reduce(Float(0)) { $0 + $1.confidence } / Float(members.count)
            return Group(text: text, rect: rect, vertical: vertical,
                         lineCount: members.count, confidence: avgConfidence)
        }
        // 阅读顺序：从上到下，同一高度从左到右。影响的是「先翻哪个气泡」，
        // 对阅读本身不重要，但列表和调试输出看着顺眼。
        .sorted {
            if abs($0.rect.y - $1.rect.y) > 0.02 { return $0.rect.y < $1.rect.y }
            return $0.rect.x < $1.rect.x
        }
    }

    // MARK: - 拼接

    /// 组内按阅读方向排序后拼成一段。
    static func join(_ lines: [Line], vertical: Bool) -> String {
        guard !lines.isEmpty else { return "" }
        let ordered: [Line]

        if vertical {
            // 竖排：从右往左读列，同一列内从上往下。
            // 同一列的判据是 x 中心接近 —— 竖排列宽差别大的时候按 minX 排会错，
            // 用中心点更稳。
            ordered = lines.sorted { a, b in
                let dx = abs(a.rect.center.x - b.rect.center.x)
                if dx > 0.025 { return a.rect.center.x > b.rect.center.x }
                return a.rect.y < b.rect.y
            }
        } else {
            // 横排：从上往下，同一行内从左往右。
            ordered = lines.sorted { a, b in
                let dy = abs(a.rect.center.y - b.rect.center.y)
                if dy > 0.025 { return a.rect.y < b.rect.y }
                return a.rect.x < b.rect.x
            }
        }

        var out = ""
        for line in ordered {
            let piece = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }
            if out.isEmpty {
                out = piece
            } else if needsSpace(between: out.last, and: piece.first, vertical: vertical) {
                out += " " + piece
            } else {
                out += piece
            }
        }
        return out
    }

    /// 中日韩之间不加空格，拉丁文之间加。混排时按「前一个字符」判断就够了。
    private static func needsSpace(between left: Character?, and right: Character?, vertical: Bool) -> Bool {
        guard let left, let right else { return false }
        if isCJK(left) || isCJK(right) { return false }
        // 竖排原文本身就是一列连贯的假名/汉字，拆列时也不需要补空格。
        if vertical { return false }
        return true
    }

    static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return true }
        let value = scalar.value
        return (0x3000...0x30FF).contains(value)     // 假名、日文标点
            || (0x3400...0x4DBF).contains(value)     // 扩展 A
            || (0x4E00...0x9FFF).contains(value)     // 基本汉字
            || (0xAC00...0xD7AF).contains(value)     // 韩文音节
            || (0xF900...0xFAFF).contains(value)     // 兼容汉字
            || (0xFF00...0xFFEF).contains(value)     // 全角
    }

    /// 粗判一段文字里 CJK 的占比，用来决定库里存的语种提示。
    static func cjkRatio(_ text: String) -> Double {
        let characters = text.filter { !$0.isWhitespace && !$0.isPunctuation }
        guard !characters.isEmpty else { return 0 }
        let cjk = characters.filter { isCJK($0) }.count
        return Double(cjk) / Double(characters.count)
    }
}
