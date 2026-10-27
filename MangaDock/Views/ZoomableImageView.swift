import SwiftUI
import UIKit

/// 分页模式用的可缩放图片视图。
///
/// 用 UIScrollView 装 UIImageView，而不是拿 MagnifyGesture 手搓 —— 系统自带
/// 捏合缩放、边界回弹、松手回弹、缩放后拖动，手感和边界处理都是现成的。
///
/// 手势冲突处理（分页模式）：
/// 1. **翻页**：外层是 UIPageViewController，1x 时 UIScrollView 不能抢横向
///    拖动，否则左右滑动翻页就没了。所以 zoomScale == 1 时让 pan 手势失败。
/// 2. **单击/双击**：双击放大、单击翻页，判定放在 UIKit 侧统一做 —— 单击
///    延迟 250ms 等双击，否则 SwiftUI 同时挂 onTapGesture(count:2) 和
///    onTapGesture 时单击会被系统拖到 300ms 之后才响应。
struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    /// 单击（延迟判定后触发）
    var onTap: (() -> Void)?
    /// 双击 —— 默认在 1x 与 2.5x 之间切换
    var onDoubleTap: ((CGFloat) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onTap: onTap, onDoubleTap: onDoubleTap)
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.delegate = context.coordinator
        scroll.maximumZoomScale = 4
        scroll.minimumZoomScale = 1
        scroll.bouncesZoom = true
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.backgroundColor = .black
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.delaysContentTouches = false
        // 1x 时不跟外层 UIPageViewController 抢横向拖动
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
        guard let imageView = context.coordinator.imageView else { return }
        if imageView.image !== image {
            imageView.image = image
            scroll.setZoomScale(1, animated: false)
        }
        context.coordinator.layout(in: scroll)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var imageView: UIImageView?
        weak var scrollView: UIScrollView?
        var onTap: (() -> Void)?
        var onDoubleTap: ((CGFloat) -> Void)?

        private var pendingSingleTap: Task<Void, Never>?

        init(onTap: (() -> Void)?, onDoubleTap: ((CGFloat) -> Void)?) {
            self.onTap = onTap
            self.onDoubleTap = onDoubleTap
        }

        // MARK: Tap

        @objc func handleSingleTap(_ recognizer: UITapGestureRecognizer) {
            pendingSingleTap?.cancel()
            pendingSingleTap = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                self?.onTap?()
            }
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            pendingSingleTap?.cancel()
            pendingSingleTap = nil
            let scroll = scrollView
            let current = scroll?.zoomScale ?? 1
            let target: CGFloat = current > 1.05 ? 1 : 2.5
            scroll?.setZoomScale(target, animated: true)
            onDoubleTap?(target)
        }

        // MARK: Layout

        /// 图片按 aspect fit 铺在滚动视图里，放大后居中。
        func layout(in scroll: UIScrollView) {
            guard let imageView else { return }
            let bounds = scroll.bounds.size
            guard bounds.width > 0, bounds.height > 0 else { return }
            guard let size = imageView.image?.size, size.width > 0, size.height > 0 else { return }

            let scale = min(bounds.width / size.width, bounds.height / size.height)
            let fitted = CGSize(width: size.width * scale, height: size.height * scale)
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
        }

        /// 没放大时 UIScrollView 不开始拖动，把横向手势让给外层翻页。
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
