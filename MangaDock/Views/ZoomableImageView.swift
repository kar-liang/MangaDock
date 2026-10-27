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
    /// 双击 —— 默认在「fit」与「2.5×fit」之间切换
    var onDoubleTap: ((CGFloat) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onTap: onTap, onDoubleTap: onDoubleTap)
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
        scroll.backgroundColor = .black
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.delaysContentTouches = false
        // 1x 时不跟外层 UIPageViewController 抢横向拖动。不要改
        // panGestureRecognizer.delegate（会触发 UIKit 内部断言闪退），
        // 而是直接禁用 pan（fit 时一页一屏本就不需要拖动，翻页由外层处理）。
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
        // 标准范式：frame = 图片实际尺寸，zoomScale 从 fit 比例起算。
        context.coordinator.initialLayout(in: scroll)
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        guard let imageView = context.coordinator.imageView else { return }
        if imageView.image !== image {
            imageView.image = image
            // 换了图片，重新按新图 fit 计算 zoomScale 区间
            context.coordinator.initialLayout(in: scroll)
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UIScrollViewDelegate {
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
            // 双击在「fit（正常）」与「2.5×fit」之间切换
            let minScale = scroll?.minimumZoomScale ?? 1
            let target: CGFloat = current > minScale * 1.05 ? minScale : minScale * 2.5
            scroll?.setZoomScale(target, animated: true)
            onDoubleTap?(target)
        }

        // MARK: Layout

        /// 标准缩放范式（相册同款）：imageView 的 frame = 图片实际像素尺寸，
        /// contentSize 也是图片尺寸。zoomScale 从「fit 比例」起算，缩到底
        /// 就是完整显示（正常尺寸），放大上限 = 4 × fit。
        /// 这样「缩放/缩回正常」天然成立，不存在缩不回 1 的问题。
        func initialLayout(in scroll: UIScrollView) {
            guard let imageView, let size = imageView.image?.size,
                  size.width > 0, size.height > 0 else { return }

            let bounds = scroll.bounds.size
            guard bounds.width > 0, bounds.height > 0 else {
                // makeUIView 时 bounds 可能还没布局好，先按图片尺寸设 frame，
                // 等 layoutSubviews 里再补 fit。
                imageView.frame = CGRect(origin: .zero, size: size)
                scroll.contentSize = size
                return
            }

            imageView.frame = CGRect(origin: .zero, size: size)
            scroll.contentSize = size

            // fit 比例 = 刚好把整张图放进可视区
            let fitScale = min(bounds.width / size.width, bounds.height / size.height)
            scroll.minimumZoomScale = fitScale
            scroll.maximumZoomScale = fitScale * 4
            scroll.zoomScale = fitScale
            centerContent(in: scroll)
        }

        /// 布局完成后（bounds 已知）补一次 fit 对齐。
        func relayoutIfNeeded(in scroll: UIScrollView) {
            guard let imageView, let size = imageView.image?.size,
                  size.width > 0, size.height > 0 else { return }
            let bounds = scroll.bounds.size
            guard bounds.width > 0, bounds.height > 0 else { return }
            let fitScale = min(bounds.width / size.width, bounds.height / size.height)
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
            // 放大后启用 pan（拖动看局部），fit 时禁用（让位外层翻页）。
            let zoomed = scrollView.zoomScale > scrollView.minimumZoomScale * 1.01
            scrollView.panGestureRecognizer.isEnabled = zoomed
        }

        /// fit 时 UIScrollView 不开始拖动，把横向手势让给外层翻页。
        func scrollViewShouldBeginDragging(_ scrollView: UIScrollView) -> Bool {
            scrollView.zoomScale > scrollView.minimumZoomScale * 1.01
        }
    }
}

/// UIScrollView 子类：布局完成后（bounds 就绪）回调，用于补一次 fit 对齐。
/// makeUIView 时 SwiftUI 可能还没给 frame，此时 bounds 为 .zero，无法算 fit。
final class ZoomScrollView: UIScrollView {
    var onLayout: (() -> Void)?
    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}
