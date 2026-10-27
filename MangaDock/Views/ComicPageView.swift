import SwiftUI

struct ComicPageView: View {
    @ObservedObject var model: ReaderModel
    let index: Int
    /// Vertical (webtoon) mode taps the page itself to toggle the chrome,
    /// because an overlay would block scrolling.
    var onTap: (() -> Void)? = nil
    /// Vertical mode needs a height that doesn't change after the image arrives,
    /// otherwise reflow above the viewport yanks the scroll offset around.
    var stableHeight: Bool = false
    /// 条漫模式：双指捏合这一页时回调，由阅读器浮出可自由缩放的图层。
    /// 原地放大，不跳到别的页面去。
    var onZoomRequest: ((UIImage) -> Void)? = nil

    @State private var image: UIImage?
    @State private var failed = false
    @State private var loadedGeneration = 0

    var body: some View {
        Group {
            if stableHeight {
                Color.clear
                    .aspectRatio(model.aspect(for: index), contentMode: .fit)
                    .overlay { pageContent }
                    .clipped()
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
            // 条漫模式：双指捏合就地放大这一页。MagnifyGesture 是双指，
            // 和 ScrollView 的单指滚动不打架。
            MagnifyGesture()
                .onChanged { value in
                    guard stableHeight, let image else { return }
                    if value.magnification > 1.06 {
                        onZoomRequest?(image)
                    }
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
