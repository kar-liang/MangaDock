import SwiftUI

struct ComicPageView: View {
    @ObservedObject var model: ReaderModel
    let index: Int
    /// Vertical (webtoon) mode taps the page itself to toggle the chrome,
    /// because an overlay would block scrolling.
    var onTap: (() -> Void)? = nil
    /// 条漫模式双击：切换整章缩放（1× / 2×）。
    var onDoubleTap: (() -> Void)? = nil
    /// Vertical mode needs a height that doesn't change after the image arrives,
    /// otherwise reflow above the viewport yanks the scroll offset around.
    var stableHeight: Bool = false
    /// 条漫模式可用宽度，用来算这一页的原始高度（宽度 ÷ 高宽比）。
    var pageWidth: CGFloat = 0
    /// 条漫「整章缩放」倍数（1 = 原尺寸），由 ReaderView 单向传入。分页模式
    /// 用不上，默认 1。
    var zoomRatio: CGFloat = 1

    @State private var image: UIImage?
    @State private var failed = false
    @State private var loadedGeneration = 0

    /// 这一页的原始高度（未缩放）。宽度从外层传来，高度按高宽比算。
    /// 整章缩放时占位高度 = 原始高度 × zoomRatio，图片同步放大，滚动流一起变大。
    private var baseHeight: CGFloat {
        let ratio = model.aspect(for: index)
        guard ratio > 0 else { return 0 }
        return pageWidth / ratio
    }

    var body: some View {
        Group {
            if stableHeight {
                // 条漫模式「整章一起放大」：占位高度 = 原始高度 × 全局缩放倍数，
                // 图片宽度始终撑满屏、高度按比例撑满占位（不用 scaleEffect 叠加，
                // 避免从中心放大导致「只剩中间」）。
                Color.clear
                    .frame(height: baseHeight * zoomRatio)
                    .overlay(alignment: .top) {
                        pageContent
                    }
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
            // 只在条漫模式响应单击（分页模式的翻页由 PagePager 的 UIKit 手势处理）。
            if stableHeight { onTap?() }
        }
        .onTapGesture(count: 2) {
            if stableHeight { onDoubleTap?() }
        }
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
                // 条漫：整章缩放。图片宽度始终撑满屏、高度按比例撑满占位，
                // 直接改尺寸而不是 scaleEffect，放大后内容完整撑满，不居中留白。
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: pageWidth, height: baseHeight * zoomRatio)
                    .clipped()
            } else {
                // 分页：UIScrollView 原生缩放，单击翻页。
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
