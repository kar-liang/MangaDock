import SwiftUI
import UIKit

/// 条漫（webtoon）模式的原地缩放视图。
///
/// 长条漫画页在垂直滚动流里连续排列，每一页宽度撑满、高度按高宽比算。
/// 「像相册看照片一样」的缩放：图片在自己的固定窗口内捏合放大、拖动看
/// 细节、双击切换，**不弹新图层、不撑开占位**（滚动流稳定，不跳）。
///
/// 实现：内嵌一个 UIScrollView 装 UIImageView，frame 固定 = 这一页的高度，
/// 用系统原生缩放。放大后 contentSize 变大、图片超出窗口，天然产生
/// 「局部查看 + 拖动」的相册手感，边界回弹、松手回弹全免费。
///
/// 手势冲突：
/// - 1x 时让 UIScrollView 的 pan 手势失败，垂直拖动交给外层 ScrollView 滚；
/// - 放大后 UIScrollView 接管拖动，单指在图片内平移看细节；
/// - 捏回 1x 自动复位。
struct ZoomableWebtoonView: UIViewRepresentable {
    let image: UIImage
    /// 单击回调（条漫模式单击用于切换工具栏显隐）
    var onTap: (() -> Void)?
    /// 放大状态变化回调（true = 正在放大）。外层据此禁用整页滚动，
    /// 让单指拖动专注于「看图片局部」而不是「滚页面」。
    var onZoomActiveChange: ((Bool) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.delegate = context.coordinator
        scroll.maximumZoomScale = 4
        scroll.minimumZoomScale = 1
        scroll.bouncesZoom = true
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.backgroundColor = .clear
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.delaysContentTouches = false
        // 1x 时不跟外层 ScrollView 抢垂直拖动
        scroll.panGestureRecognizer.delegate = context.coordinator

        let single = UITapGestureRecognizer(target: context.coordinator,
                                            action: #selector(Coordinator.handleSingleTap(_:)))
        single.numberOfTapsRequired = 1
        scroll.addGestureRecognizer(single)

        let double = UITapGestureRecognizer(target: context.coordinator,
                                            action: #selector(Coordinator.handleDoubleTap(_:)))
        double.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(double)
        single.require(toFail: double)

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        scroll.addSubview(imageView)
        context.coordinator.imageView = imageView
        context.coordinator.scrollView = scroll
        context.coordinator.layout(in: scroll)
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.parent = self
        guard let imageView = context.coordinator.imageView else { return }
        if imageView.image !== image {
            imageView.image = image
            scroll.setZoomScale(1, animated: false)
        }
        context.coordinator.layout(in: scroll)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var parent: ZoomableWebtoonView
        var imageView: UIImageView?
        weak var scrollView: UIScrollView?

        private var pendingSingleTap: Task<Void, Never>?

        init(parent: ZoomableWebtoonView) {
            self.parent = parent
        }

        // MARK: Tap

        @objc func handleSingleTap(_ recognizer: UITapGestureRecognizer) {
            pendingSingleTap?.cancel()
            pendingSingleTap = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                self?.parent.onTap?()
            }
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            pendingSingleTap?.cancel()
            pendingSingleTap = nil
            let scroll = scrollView
            let current = scroll?.zoomScale ?? 1
            let target: CGFloat = current > 1.05 ? 1 : 2.5
            scroll?.setZoomScale(target, animated: true)
        }

        // MARK: Layout

        /// 图片宽度撑满、高度按高宽比算。UIScrollView 的 frame 由外层约束
        /// （等于这一页的原始高度），contentSize 初始 = 图片尺寸。
        func layout(in scroll: UIScrollView) {
            guard let imageView else { return }
            let bounds = scroll.bounds.size
            guard bounds.width > 0, bounds.height > 0 else { return }
            guard let size = imageView.image?.size, size.width > 0, size.height > 0 else { return }

            // 宽度撑满，高度按原始高宽比（长条图就是超高）。
            let fitted = CGSize(width: bounds.width, height: bounds.width * size.height / size.width)
            imageView.frame = CGRect(origin: .zero, size: fitted)
            scroll.contentSize = fitted
            centerContent(in: scroll)
        }

        private func centerContent(in scroll: UIScrollView) {
            guard let imageView else { return }
            let bounds = scroll.bounds.size
            let frame = imageView.frame
            let x = max(0, (bounds.width - frame.width) / 2)
            let y = max(0, (bounds.height - frame.height) / 2)
            scroll.contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
        }

        // MARK: UIScrollViewDelegate

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centerContent(in: scrollView)
            parent.onZoomActiveChange?(scrollView.zoomScale > 1.01)
        }

        /// 没放大时 UIScrollView 不接管拖动，让外层 ScrollView 滚。
        func scrollViewShouldBeginDragging(_ scrollView: UIScrollView) -> Bool {
            scrollView.zoomScale > 1.01
        }

        // MARK: UIGestureRecognizerDelegate

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer === scrollView?.panGestureRecognizer {
                return (scrollView?.zoomScale ?? 1) > 1.01
            }
            return true
        }
    }
}
