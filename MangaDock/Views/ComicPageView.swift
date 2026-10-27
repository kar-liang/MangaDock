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
    /// 条漫模式可用宽度，用来算这一页的原始高度（宽度 ÷ 高宽比）。
    var pageWidth: CGFloat = 0
    /// 放大状态变化回调（true = 正在放大），ReaderView 据此禁用整页滚动。
    var onZoomActiveChange: ((Bool) -> Void)? = nil

    @State private var image: UIImage?
    @State private var failed = false
    @State private var loadedGeneration = 0
    /// 条漫模式当前是否放大，用来抬高 zIndex（盖住相邻页）。
    @State private var isZoomed = false

    /// 这一页的原始高度。宽度从外层传来，高度按高宽比算。占位高度恒定，
    /// 缩放只在页面内部进行，不改变滚动流布局。
    private var baseHeight: CGFloat {
        let ratio = model.aspect(for: index)
        guard ratio > 0 else { return 0 }
        return pageWidth / ratio
    }

    var body: some View {
        Group {
            if stableHeight {
                // 条漫模式：占位高度恒定（不撑开，滚动流稳定），图片在
                // 固定高度的窗口内捏合放大、拖动看细节，像相册一样原地缩放。
                Color.clear
                    .frame(height: baseHeight)
                    .overlay(alignment: .top) {
                        pageContent
                    }
                    .clipped()
                    // 放大的那一页盖在相邻页上面，避免被上下页遮住
                    .zIndex(isZoomed ? 1 : 0)
            } else {
                ZStack {
                    Color.black
                    pageContent
                }
            }
        }
        .contentShape(Rectangle())
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
                // 条漫：内嵌 UIScrollView 原生缩放，固定窗口内放大看细节。
                ZoomableWebtoonView(image: image,
                                    onTap: { onTap?() },
                                    onZoomActiveChange: { active in
                                        isZoomed = active
                                        onZoomActiveChange?(active)
                                    })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
