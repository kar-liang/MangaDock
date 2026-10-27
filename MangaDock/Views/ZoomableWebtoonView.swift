import SwiftUI
import UIKit

/// 条漫（webtoon）模式的原地缩放视图。
///
/// 长条漫画页在垂直滚动流里连续排列，每一页宽度撑满、高度按高宽比算。
/// 「像相册看照片一样」的缩放：图片在自己的固定窗口内捏合放大、拖动看
/// 细节、双击切换，**不弹新图层、不撑开占位**（滚动流稳定，不跳）。
///
/// 实现：内嵌一个 UIScrollView 装 UIImageView，用系统原生缩放。标准范式：
/// imageView.frame = 图片实际尺寸，「正常尺寸」= 宽度撑满（fitScale =
/// bounds.width / 图片宽），捏合在 fitScale ~ 4×fitScale 之间，缩到底即恢复。
///
/// 手势冲突：
/// - fit 时禁用 UIScrollView 的 pan（不跟外层 ScrollView 抢垂直拖动），
///   捏合手势不受影响（pinch 是独立手势）；
/// - 放大后重新启用 pan，单指在图片内平移看细节；
/// - 捏回 fit 自动复位。
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
        let scroll = ZoomScrollView()
        scroll.delegate = context.coordinator
        scroll.onLayout = { [weak coordinator = context.coordinator] in
            coordinator?.relayoutIfNeeded(in: scroll)
        }
        scroll.bouncesZoom = true
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.backgroundColor = .clear
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.delaysContentTouches = false
        // fit 时不跟外层 ScrollView 抢垂直拖动。不要改
        // panGestureRecognizer.delegate（会触发 UIKit 内部断言闪退），
        // 而是直接禁用 pan（不影响捏合，捏合是独立的 pinch 手势）。
        scroll.panGestureRecognizer.isEnabled = false

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
        context.coordinator.initialLayout(in: scroll)
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.parent = self
        guard let imageView = context.coordinator.imageView else { return }
        if imageView.image !== image {
            imageView.image = image
            context.coordinator.initialLayout(in: scroll)
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UIScrollViewDelegate {
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
            let minScale = scroll?.minimumZoomScale ?? 1
            // 双击在「fit（正常）」与「2.5×fit」之间切换
            let target: CGFloat = current > minScale * 1.05 ? minScale : minScale * 2.5
            scroll?.setZoomScale(target, animated: true)
        }

        // MARK: Layout

        /// 标准缩放范式：imageView.frame = 图片实际尺寸。条漫的「正常尺寸」=
        /// 宽度撑满（fitScale = bounds.width / 图片宽），缩到底即恢复原样。
        func initialLayout(in scroll: UIScrollView) {
            guard let imageView, let size = imageView.image?.size,
                  size.width > 0, size.height > 0 else { return }

            imageView.frame = CGRect(origin: .zero, size: size)
            scroll.contentSize = size

            let bounds = scroll.bounds.size
            guard bounds.width > 0, bounds.height > 0 else { return }

            let fitScale = bounds.width / size.width
            scroll.minimumZoomScale = fitScale
            scroll.maximumZoomScale = fitScale * 4
            scroll.zoomScale = fitScale
            centerContent(in: scroll)
        }

        /// 布局完成后（bounds 就绪）补一次 fit 对齐。
        func relayoutIfNeeded(in scroll: UIScrollView) {
            guard let imageView, let size = imageView.image?.size,
                  size.width > 0, size.height > 0 else { return }
            let bounds = scroll.bounds.size
            guard bounds.width > 0, bounds.height > 0 else { return }
            let fitScale = bounds.width / size.width
            // 只在还没 fit 对齐时重设，避免打断用户当前缩放。
            if abs(scroll.minimumZoomScale - fitScale) > 0.001 {
                scroll.minimumZoomScale = fitScale
                scroll.maximumZoomScale = fitScale * 4
                scroll.zoomScale = fitScale
                centerContent(in: scroll)
            }
        }

        private func centerContent(in scroll: UIScrollView) {
            guard let imageView else { return }
            let bounds = scroll.bounds.size
            // 用缩放后的实际尺寸算居中（frame 是未缩放的，要乘 zoomScale）。
            let frame = imageView.frame
            let z = scroll.zoomScale
            let scaledW = frame.width * z
            let scaledH = frame.height * z
            let x = max(0, (bounds.width - scaledW) / 2)
            let y = max(0, (bounds.height - scaledH) / 2)
            scroll.contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
        }

        // MARK: UIScrollViewDelegate

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centerContent(in: scrollView)
            // 放大后启用 pan（拖动看局部），fit 时禁用（让位外层滚动）。
            let zoomed = scrollView.zoomScale > scrollView.minimumZoomScale * 1.01
            scrollView.panGestureRecognizer.isEnabled = zoomed
            parent.onZoomActiveChange?(zoomed)
        }

        /// fit 时 UIScrollView 不接管拖动，让外层 ScrollView 滚。
        func scrollViewShouldBeginDragging(_ scrollView: UIScrollView) -> Bool {
            scrollView.zoomScale > scrollView.minimumZoomScale * 1.01
        }
    }
}
