import UIKit

/// 译文卡片画布。分页和条漫两种模式共用这一块。
///
/// 用 UIKit 而不是 SwiftUI：条漫那边一话几十页，每页挂一个 SwiftUI 宿主
/// 太重；分页这边本身就在 UIScrollView 里，UIKit 子视图能直接吃到它的缩放。
///
/// 关键点：**画布坐标系就是图片坐标系**。传进来的 rect 已经是画布 point，
/// 缩放由外层 scrollView 负责，画布只负责「缩放变大时字号别跟着炸」——
/// 所以字号要除以 zoomScale。
final class TranslationCanvasView: UIView {

    struct Placed: Equatable {
        /// 画布坐标（和图片一样大）。
        var rect: CGRect
        var text: String
        var vertical: Bool
    }

    var placed: [Placed] = [] {
        didSet {
            guard placed != oldValue else { return }
            rebuild()
        }
    }

    /// 外层 scrollView 当前的缩放倍数。缩小时字号按比例放大，视觉大小才稳定。
    var zoomScale: CGFloat = 1 {
        didSet {
            guard abs(zoomScale - oldValue) > 0.02 else { return }
            rebuild()
        }
    }

    var baseFontSize: CGFloat = 14 {
        didSet {
            guard baseFontSize != oldValue else { return }
            rebuild()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false     // 绝不能挡住翻页/缩放手势
        backgroundColor = .clear
        clipsToBounds = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// SwiftUI 的 UIViewRepresentable 是「先 updateUIView、后布局」，第一次进来
    /// bounds 还是零，那时候画出来是空的。这里补一次：宽度真正定下来之后再画。
    private var laidOutWidth: CGFloat = 0
    override func layoutSubviews() {
        super.layoutSubviews()
        guard !placed.isEmpty, bounds.width > 1,
              abs(bounds.width - laidOutWidth) > 0.5 else { return }
        laidOutWidth = bounds.width
        rebuild()
    }

    // MARK: - 绘制

    private func rebuild() {
        subviews.forEach { $0.removeFromSuperview() }
        guard !placed.isEmpty, bounds.width > 1 else { return }

        for item in placed {
            let label = makeLabel(for: item)
            addSubview(label)
        }
    }

    private func makeLabel(for item: Placed) -> UILabel {
        let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let box = item.rect

        // 缩放补偿：图片放大 2 倍时字号减半，屏幕上看起来还是那么大。
        let compensated = baseFontSize / max(zoomScale, 0.05)
        // 上下都留个口子：太小读不了，太大会糊住画面。
        let startSize = min(max(compensated, 5), 34)

        // 宽度给个下限 —— OCR 的包围盒常常比文字实际需要窄，
        // 死守框宽会把中文译文挤成一列一个字。
        let minWidth = max(startSize * 4.2, 58 / max(zoomScale, 0.05))
        let width = max(box.width, minWidth)
        let height = max(box.height, startSize * 1.3)

        let label = UILabel()
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = UIColor.black.withAlphaComponent(0.92)
        label.backgroundColor = UIColor.white.withAlphaComponent(0.90)
        label.layer.cornerRadius = max(3, startSize * 0.32)
        label.layer.masksToBounds = true
        label.layer.borderWidth = max(0.5, 1 / max(zoomScale, 0.5))
        label.layer.borderColor = UIColor.systemOrange.withAlphaComponent(0.45).cgColor
        label.text = text

        // 字号自适应：从基准往下试，能塞进框（允许溢出 40%）就用它。
        var size = startSize
        while size > 5.5 {
            let font = UIFont.systemFont(ofSize: size, weight: .medium)
            let fitting = (text as NSString).boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font],
                context: nil
            )
            if fitting.height <= height * 1.45 { break }
            size -= 0.8
        }

        label.font = UIFont.systemFont(ofSize: size, weight: .medium)
        // 用 sizeThatFits 而不是 sizeToFit：多行 label 的 sizeToFit 会按单行算，
        // 高度直接塌成一行，长句就被裁掉只剩第一行。
        let fitted = label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        label.frame = CGRect(x: 0, y: 0,
                             width: width,
                             height: max(fitted.height + size * 0.35, height * 0.8))

        // 以原文字块中心为准摆，再夹回画布内，别跑到画面外去。
        var center = CGPoint(x: box.midX, y: box.midY)
        let halfW = label.frame.width / 2
        let halfH = label.frame.height / 2
        center.x = min(max(center.x, halfW), max(halfW, bounds.width - halfW))
        center.y = min(max(center.y, halfH), max(halfH, bounds.height - halfH))
        label.center = center

        return label
    }
}
