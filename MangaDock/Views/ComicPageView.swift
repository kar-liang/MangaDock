import SwiftUI

/// 分页模式下的单页渲染：UIScrollView 原生缩放 + 单击翻页（翻页手势由
/// PagePager 的 UIKit 手势统一处理）。条漫模式已改用 WebtoonReaderView，
/// 本视图不再承担条漫渲染职责。
struct ComicPageView: View {
    @ObservedObject var model: ReaderModel
    @ObservedObject private var translation = TranslationService.shared
    let index: Int
    /// 缩放状态变化（放大 = true），冒泡给 ReaderView 决定是否禁用左右翻页。
    var onZoomChanged: ((Bool) -> Void)? = nil

    @State private var image: UIImage?
    @State private var failed = false
    @State private var loadedGeneration = 0
    /// 放大后隐藏译文层：此刻用户是想看原图细节，盖一层卡片纯属碍事。
    @State private var isZoomed = false
    @AppStorage(TranslationPrefs.enabledKey) private var translationEnabled = false

    private var pageKey: String {
        TranslationService.key(chapter: model.currentItem.url, page: index)
    }

    private var pageState: PageTranslationState {
        translation.state(for: pageKey)
    }

    var body: some View {
        ZStack {
            // 2.0.29 说要把这层改成白，但那次提交根本没动这个文件（黑底一直留着）。
            // 2.0.47 统一三种模式白底时一并补上。
            Color.white
            pageContent
            translatedOverlay
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
        .task(id: "\(pageKey)-\(translationEnabled)-\(image != nil)") {
            await translateIfNeeded()
        }
        .onAppear {
            // Whenever a page becomes visible, start rendering the ones after it
            // in the background.
            model.prewarm(from: index + 1)
            model.preloadNextChapterIfNeeded()
        }
    }

    // MARK: - 译文层

    @ViewBuilder
    private var translatedOverlay: some View {
        if translationEnabled, !isZoomed, image != nil, pageState.isVisible {
            GeometryReader { geometry in
                let fitted = fittedSize(in: geometry.size)
                TranslationLayer(blocks: pageState.blocks,
                                 size: fitted,
                                 zoomScale: 1,
                                 fontSize: TranslationPrefs.fontSize)
                    .frame(width: fitted.width, height: fitted.height)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    // 绝不能吃手势：翻页是 PagePager 在 UIPageViewController 上装的
                    // 手势识别器，这里一旦可交互，左右滑动就全废了。
                    .allowsHitTesting(false)
            }
            .transition(.opacity)
        }
    }

    /// 图片按 aspectFit 摆在容器中间，译文层必须严格贴着这块区域，
    /// 否则位置就整体偏移。
    private func fittedSize(in container: CGSize) -> CGSize {
        guard let image, image.size.width > 0, image.size.height > 0,
              container.width > 0, container.height > 0 else { return .zero }
        let scale = min(container.width / image.size.width,
                        container.height / image.size.height)
        return CGSize(width: image.size.width * scale, height: image.size.height * scale)
    }

    // MARK: - 翻译触发

    private func translateIfNeeded() async {
        guard translationEnabled, TranslationPrefs.autoTranslate, image != nil else { return }
        if pageState.phase == .ready { return }
        guard let data = await model.rawPageData(at: index) else { return }
        await translation.translate(chapter: model.currentItem.url, page: index, data: data)
    }

    // MARK: - 页面

    @ViewBuilder
    private var pageContent: some View {
        if let image {
            ZoomableImageView(image: image, onTap: nil, onZoomChanged: { zoomed in
                withAnimation(.easeInOut(duration: 0.12)) { isZoomed = zoomed }
                onZoomChanged?(zoomed)
            })
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
            diag("paint", "paged p\(index + 1)/\(model.pageCount) ready")
        } else {
            failed = true
        }
    }
}
