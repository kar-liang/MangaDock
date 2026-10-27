import SwiftUI
import UIKit

/// 可缩放的图片。
///
/// 用 UIScrollView 装，而不是自己拿 MagnifyGesture 手搓 —— 系统自带捏合缩放、
/// 边界回弹、松手回弹、缩放后拖动，手感和边界处理都是现成的。
///
/// 两个手势冲突要处理：
/// 1. **翻页**：外层是 TabView(.page)，1x 时 UIScrollView 不能抢横向拖动，
///    否则左右滑动翻页就没了。所以 zoomScale == 1 时直接让 pan 手势失败。
/// 2. **单击翻页**：双击会放大，单击要翻页，判定放在 UIKit 侧统一做，
///    单击延迟 250ms 等双击 —— 在 SwiftUI 里同时挂 onTapGesture(count: 2)
///    和 onTapGesture，单击会被系统拖到 300ms 之后才响应。
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
        // 1x 时不让 UIScrollView 接管拖动，横向手势留给外层 TabView 翻页。
        // 只关 pan 手势：isScrollEnabled=false 会连 pinch 缩放一起废掉；
        // 覆盖 panGestureRecognizer.delegate 会被 UIKit 内部依赖搞崩。
        // 禁用手势不是改 delegate，UIKit 内部关系不受影响。
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

    // 不要给 Coordinator 加 @MainActor —— UIScrollViewDelegate 的方法是
    // nonisolated 的，整个类标了会让协议实现签名对不上，编译直接失败
    // （error: parameter of 'scrollViewDidEndZooming' has different optionality）。
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
            let target: CGFloat = current > 1.05 ? 1 : 2.5
            scroll?.setZoomScale(target, animated: true)
            scroll?.panGestureRecognizer.isEnabled = target > 1.01
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

        /// 缩放过程中的统一处理点。
        ///
        /// 之前把逻辑拆到 scrollViewWillBeginZooming / scrollViewDidEndZooming 里，
        /// 但这两个可选方法在 Swift 里的实现签名和 SDK 声明对不上
        /// （error: parameter of 'scrollViewDidEndZooming' has different
        /// optionality than required by protocol），编译直接失败。
        /// didZoom 在整个缩放过程中（含开始和结束）都会回调，够用了。
        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            pendingSingleTap?.cancel()
            pendingSingleTap = nil
            centerContent(in: scrollView)
            // 放大后才允许拖动看细节；1x 时把拖动让给翻页
            scrollView.panGestureRecognizer.isEnabled = scrollView.zoomScale > 1.01
        }

    }
}

/// 单页全屏缩放查看。条漫模式下用：长条页面在滚动流里没法放大，
/// 双击进这里看细节。
struct PageZoomSheet: View {
    let image: UIImage

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ZoomableImageView(image: image) {
                dismiss()
            }
            .ignoresSafeArea()
        }
        .statusBarHidden()
    }
}
