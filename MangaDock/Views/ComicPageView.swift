import SwiftUI

/// 分页模式下的单页渲染：UIScrollView 原生双指缩放。单击翻页由外层
/// PagePager 的 tap 手势处理，双击已删除。条漫模式已改用 WebtoonReaderView，
/// 本视图不再承担条漫渲染职责。
struct ComicPageView: View {
    @ObservedObject var model: ReaderModel
    let index: Int
    /// 缩放状态变化（放大 = true），冒泡给 ReaderView 决定是否禁用左右翻页。
    var onZoomChanged: ((Bool) -> Void)? = nil

    @State private var image: UIImage?
    @State private var failed = false
    @State private var loadedGeneration = 0

    var body: some View {
        ZStack {
            Color.black
            pageContent
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
            // Whenever a page becomes visible, start rendering the ones after it
            // in the background.
            model.prewarm(from: index + 1)
            model.preloadNextChapterIfNeeded()
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        if let image {
            ZoomableImageView(image: image, onZoomChanged: onZoomChanged)
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
