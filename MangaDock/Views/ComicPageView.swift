import SwiftUI

/// 只在没放大时裁剪。放大后要允许内容溢出到容器外面。
private struct ClipUnlessZoomed: ViewModifier {
    let zoomed: Bool

    func body(content: Content) -> some View {
        if zoomed {
            content
        } else {
            content.clipped()
        }
    }
}

struct ComicPageView: View {
    @ObservedObject var model: ReaderModel
    let index: Int
    /// Vertical (webtoon) mode taps the page itself to toggle the chrome,
    /// because an overlay would block scrolling.
    var onTap: (() -> Void)? = nil
    /// Vertical mode needs a height that doesn't change after the image arrives,
    /// otherwise reflow above the viewport yanks the scroll offset around.
    var stableHeight: Bool = false
    /// 条漫模式可用宽度。用来算这一页的原始高度（宽度 ÷ 高宽比），
    /// 有了原始高度才能在放大时把占位一起撑开。
    var pageWidth: CGFloat = 0
    /// 放大状态变化时回调（true = 正在放大，ReaderView 据此禁用整页滚动）
    var onZoomActiveChange: ((Bool) -> Void)? = nil

    @State private var image: UIImage?
    @State private var failed = false
    @State private var loadedGeneration = 0

    // 条漫模式的原地缩放
    @State private var scale: CGFloat = 1
    @State private var zoomOffset: CGSize = .zero
    @State private var dragAnchor: CGSize = .zero

    /// 放大后的容器高度。宽度还没测到时返回 nil，交给 aspectRatio 兜底。
    private var zoomedHeight: CGFloat? {
        guard baseHeight > 0 else { return nil }
        return baseHeight * scale
    }

    /// 这一页的原始高度（未放大时）
    private var baseHeight: CGFloat {
        let ratio = model.aspect(for: index)
        guard ratio > 0, pageWidth > 0 else { return 0 }
        return pageWidth / ratio
    }

    var body: some View {
        Group {
            if stableHeight {
                // 高度自己算：放大时占位一起撑开，后面的内容被推下去。
                // 用 pageWidth ÷ 高宽比 得到原始高度，不做嵌套测量 ——
                // 测量会跟 frame 形成循环。
                Color.clear
                    .aspectRatio(model.aspect(for: index), contentMode: .fit)
                    .frame(height: zoomedHeight)
                    .overlay(alignment: .top) {
                        pageContent
                            .scaleEffect(scale, anchor: .top)
                            .offset(zoomOffset)
                    }
                    // 放大后不能裁 —— 否则放大的部分会被切掉。
                    // SwiftUI 没有 clipped(Bool) 这个重载（只有 clipped(antialiased:)），
                    // 条件裁剪得自己包一层。
                    .modifier(ClipUnlessZoomed(zoomed: scale > 1.01))
                    // 放大的那一页要盖在相邻页上面
                    .zIndex(scale > 1.01 ? 1 : 0)
            } else {
                ZStack {
                    Color.black
                    pageContent
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // 分页模式下单击/双击由 ZoomableImageView 统一判定（单击要等双击
            // 窗口结束），这里只在没有缩放组件时兜底。
            if stableHeight || image == nil { onTap?() }
        }
        .simultaneousGesture(
            // 条漫模式：双指捏合就地缩放这一页。MagnifyGesture 是双指，
            // 和 ScrollView 的单指滚动不打架。
            MagnifyGesture()
                .onChanged { value in
                    guard stableHeight else { return }
                    let next = min(max(value.magnification, 1), 4)
                    scale = next
                    onZoomActiveChange?(next > 1.01)
                    if next <= 1.01 { resetZoom() }
                }
        )
        .simultaneousGesture(
            // 放大后单指拖动 = 平移查看局部
            DragGesture()
                .onChanged { value in
                    guard stableHeight, scale > 1.01 else { return }
                    zoomOffset = clampedOffset(
                        CGSize(width: dragAnchor.width + value.translation.width,
                               height: dragAnchor.height + value.translation.height),
                        scale: scale)
                }
                .onEnded { _ in
                    dragAnchor = zoomOffset
                }
        )
        .task(id: "\(index)-\(model.enhanceGeneration)") {
            // Only drop the decoded image when the enhance mode actually changed.
            if loadedGeneration != model.enhanceGeneration {
                image = nil
            }
            loadedGeneration = model.enhanceGeneration
            await load()
        }
        .onAppear {
            // Works for both paging and webtoon scrolling: whenever a page becomes
            // visible, start rendering the ones after it in the background.
            model.prewarm(from: index + 1)
            model.preloadNextChapterIfNeeded()
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        if let image {
            if stableHeight {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // 分页模式：交给 UIScrollView，支持捏合 + 双击放大
                ZoomableImageView(image: image, onTap: onTap)
            }
        } else if failed {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundColor(.white.opacity(0.6))
                Text("第 \(index + 1) 页加载失败")
                    .foregroundColor(.white.opacity(0.8))
                Button("重试") {
                    Task { await load() }
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }
        } else {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
        }
    }

    /// 拖动范围：不能把图拖得完全离开原来的位置，否则会「丢失」它。
    private func clampedOffset(_ offset: CGSize, scale: CGFloat) -> CGSize {
        let maxX = baseHeight * (scale - 1) / 2
        let maxY = baseHeight * (scale - 1) / 2
        return CGSize(width: min(max(offset.width, -maxX), maxX),
                      height: min(max(offset.height, -maxY), maxY))
    }

    private func resetZoom() {
        withAnimation(.easeOut(duration: 0.15)) {
            scale = 1
            zoomOffset = .zero
            dragAnchor = .zero
        }
        onZoomActiveChange?(false)
    }

    private func load() async {
        guard image == nil else { return }
        failed = false
        if let loaded = await model.image(at: index) {
            image = loaded
        } else {
            failed = true
        }
    }
}
