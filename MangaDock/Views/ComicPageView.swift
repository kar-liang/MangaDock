import SwiftUI

/// 分页模式下的单页渲染：UIScrollView 原生缩放 + 单击翻页（翻页手势由
/// PagePager 的 UIKit 手势统一处理）。条漫模式已改用 WebtoonReaderView，
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
            // 2.0.29 说要把这层改成白，但那次提交根本没动这个文件（黑底一直留着）。
            // 2.0.47 统一三种模式白底时一并补上。
            Color.white
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
            ZoomableImageView(image: image, onTap: nil, onZoomChanged: onZoomChanged)
        } else if failed {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundColor(.primary.opacity(0.6))
                Text("第 \(index + 1) 页加载失败")
                    .foregroundColor(.primary.opacity(0.8))
                Button("重试") {
                    Task { await load() }
                }
                .buttonStyle(.bordered)
                .tint(.primary)
            }
        } else {
            VStack(spacing: 12) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.primary.opacity(0.55))
                Text("正在加载 第 \(index + 1) / \(model.pageCount) 页")
                    .font(.footnote)
                    .foregroundColor(.primary.opacity(0.65))
            }
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
