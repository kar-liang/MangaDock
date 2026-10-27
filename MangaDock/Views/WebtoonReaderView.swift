import SwiftUI
import UIKit

/// 条漫模式的整章缩放视图。
///
/// 把整个章节当成「一张超长图」来缩放：所有页面垂直拼成一个 contentView，
/// 用 UIScrollView 的原生 zoomScale 做整章缩放——捏合、拖动、边界回弹、
/// 滚动锚点全部是系统原生行为，跟相册看单张图一模一样。
///
/// 关键点：
/// - viewForZooming 返回 contentView，缩放的是「整章」而不是某一页。
/// - 页面按需加载（可视区 ± 缓冲），远处页卸载 image 释放内存（NSCache 兜底）。
/// - 进度跟踪：scrollViewDidScroll 里根据 contentOffset 算出当前可视页回写。
/// - 底部 overshoot 触发换章（只在 zoomScale ≈ 1 时，放大看细节不误触发）。
struct WebtoonReaderView: UIViewRepresentable {
    @ObservedObject var model: ReaderModel
    /// 屏宽，用于算每页高度（宽度撑满）。
    let pageWidth: CGFloat
    /// 单击（切换工具栏显隐）。
    var onTap: (() -> Void)?
    /// 进度变化：当前可视页回写，供保存阅读进度。
    var onPageChange: ((Int) -> Void)?
    /// 底部 overshoot 触发换下一章。
    var onNextChapter: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.delegate = context.coordinator
        scroll.backgroundColor = .black
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.bounces = true
        scroll.alwaysBounceVertical = true

        // 缩放范围：1 = 宽度撑满（原尺寸），最大 4 倍。
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 4
        scroll.bouncesZoom = true

        let content = UIView()
        content.backgroundColor = .black
        scroll.addSubview(content)
        context.coordinator.contentView = content
        context.coordinator.scrollView = scroll

        // 单击：切换工具栏显隐。双击已删除（双指缩放够用）。
        let single = UITapGestureRecognizer(target: context.coordinator,
                                            action: #selector(Coordinator.handleSingleTap(_:)))
        single.numberOfTapsRequired = 1
        scroll.addGestureRecognizer(single)

        context.coordinator.buildPages(in: scroll)
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.parent = self
        // 章节变化（pageCount 或 currentItem 变）时重建页面。
        if context.coordinator.chapterKey != model.currentItem.url.absoluteString
            || context.coordinator.pageCount != model.pageCount {
            context.coordinator.buildPages(in: scroll)
        } else if context.coordinator.layoutWidth != pageWidth, pageWidth > 0 {
            // pageWidth 首次量出来（初始为 0）或屏宽变化时重排，否则首屏黑边。
            context.coordinator.layoutWidth = pageWidth
            context.coordinator.relayout()
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: WebtoonReaderView
        weak var scrollView: UIScrollView?
        var contentView: UIView?

        /// 章节标识，用于判断是否需要重建页面。
        var chapterKey: String = ""
        var pageCount: Int = 0

        /// 每页的 UIImageView，frame 由 relayout 统一算。
        private var pageViews: [UIImageView] = []
        /// 每页布局时用的宽高比缓存（用于检测 aspect 变化后重排）。
        private var layoutAspects: [CGFloat] = []
        /// 上次布局用的宽度，检测 pageWidth 变化后重排（初始 pageWidth 可能为 0）。
        /// 非 private：updateUIView（结构体侧）需要读写它。
        var layoutWidth: CGFloat = 0
        /// 已加载（持有 image）的页集合，用于按需卸载。
        private var loadedPages: Set<Int> = []
        /// 正在加载的页任务，避免重复加载。
        private var loadingTasks: [Int: Task<Void, Never>] = [:]

        init(parent: WebtoonReaderView) {
            self.parent = parent
        }

        // MARK: - Build

        /// 根据当前章节重建所有页面的占位 imageView 并布局。
        func buildPages(in scroll: UIScrollView) {
            guard let contentView else { return }
            chapterKey = parent.model.currentItem.url.absoluteString
            pageCount = parent.model.pageCount

            // 清掉旧页。
            pageViews.forEach { $0.removeFromSuperview() }
            pageViews.removeAll()
            layoutAspects.removeAll()
            loadedPages.removeAll()
            loadingTasks.values.forEach { $0.cancel() }
            loadingTasks.removeAll()

            let count = pageCount
            for i in 0..<count {
                let iv = UIImageView()
                // frame 高度按图片真实宽高比精确算，scaleToFill 正好 1:1 铺满，
                // 不会像 scaleAspectFit 那样在边缘留黑边。
                iv.contentMode = .scaleToFill
                iv.clipsToBounds = true
                iv.backgroundColor = .black
                contentView.addSubview(iv)
                pageViews.append(iv)
                layoutAspects.append(parent.model.aspect(for: i))
            }

            relayout()
            // 重置滚动到顶部 + 缩放回 1（换章从头看）。
            scroll.setZoomScale(1, animated: false)
            scroll.contentOffset = .zero
            loadVisiblePages()
        }

        /// 计算所有页 frame 和 contentView 高度。
        func relayout() {
            guard let contentView, let scrollView else { return }
            let width = parent.pageWidth
            guard width > 0 else { return }
            layoutWidth = width

            var y: CGFloat = 0
            for i in 0..<pageViews.count {
                let aspect = layoutAspects[i]
                let height = aspect > 0 ? width / aspect : width / 0.72
                pageViews[i].frame = CGRect(x: 0, y: y, width: width, height: height)
                y += height
            }
            // 末尾留一段空白，容纳「本话看完 / 下一话」的 overshoot 区。
            let footer: CGFloat = 300
            contentView.frame = CGRect(x: 0, y: 0, width: width, height: y + footer)
            scrollView.contentSize = CGSize(width: width, height: y + footer)
        }

        // MARK: - Page loading (on-demand)

        /// 加载可视区 ± 缓冲的页，卸载范围外的页。
        func loadVisiblePages() {
            guard let scrollView, pageCount > 0 else { return }
            let bounds = scrollView.bounds
            let zoom = scrollView.zoomScale
            // 可视内容范围（缩放后坐标系换算回 1x）。
            let top = scrollView.contentOffset.y / zoom
            let bottom = (scrollView.contentOffset.y + bounds.height) / zoom
            let buffer = bounds.height / zoom  // 上下各留一屏缓冲

            var first = pageCount
            var last = -1
            for i in 0..<pageViews.count {
                let f = pageViews[i].frame
                if f.maxY >= top - buffer && f.minY <= bottom + buffer {
                    first = min(first, i)
                    last = max(last, i)
                }
            }

            guard last >= first else { return }

            // 卸载范围外的页。
            for i in loadedPages where i < first || i > last {
                pageViews[i].image = nil
                loadedPages.remove(i)
            }

            // 加载范围内的页。
            for i in first...last {
                loadPage(i)
            }

            // 预加载下一话（沿用既有逻辑）。
            if last >= pageCount - 1 {
                parent.model.preloadNextChapterIfNeeded()
            }
        }

        private func loadPage(_ index: Int) {
            guard index >= 0, index < pageCount else { return }
            guard !loadedPages.contains(index), loadingTasks[index] == nil else { return }
            guard pageViews[index].image == nil else {
                loadedPages.insert(index)
                return
            }

            loadingTasks[index] = Task { [weak self] in
                guard let self else { return }
                let image = await self.parent.model.image(at: index)
                guard !Task.isCancelled else { return }
                self.loadingTasks[index] = nil
                guard let image, index < self.pageViews.count else { return }
                self.pageViews[index].image = image
                self.loadedPages.insert(index)

                // 用图片真实尺寸算精确宽高比（不依赖 model 的 pageAspects，
                // 它可能因 decode 时序滞后导致估算高度留黑边），变化则重排。
                let newAspect = image.size.width / max(image.size.height, 1)
                if abs(newAspect - self.layoutAspects[index]) > 0.001 {
                    self.layoutAspects[index] = newAspect
                    self.relayout()
                }
            }
        }

        // MARK: - Tap

        @objc func handleSingleTap(_ recognizer: UITapGestureRecognizer) {
            // 单击立即触发（双击已删除，无需延迟等双击判定）。
            parent.onTap?()
        }

        // MARK: - UIScrollViewDelegate

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            contentView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            // 缩放后重新加载可视页（缩放改变了可视范围）。
            loadVisiblePages()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            loadVisiblePages()
            updateProgress(scrollView)

            // 底部 overshoot 换章（只在 1x 时，放大看细节不误触发）。
            guard scrollView.zoomScale < 1.05 else { return }
            let bottom = scrollView.contentSize.height - scrollView.bounds.height
            if scrollView.contentOffset.y > bottom + 30 {
                parent.onNextChapter?()
            }
        }

        /// 根据 contentOffset 算出当前可视页，回写进度。
        func updateProgress(_ scrollView: UIScrollView) {
            guard pageCount > 0 else { return }
            let zoom = scrollView.zoomScale
            let midY = (scrollView.contentOffset.y + scrollView.bounds.height * 0.3) / zoom
            var current = 0
            for i in 0..<pageViews.count {
                if pageViews[i].frame.minY <= midY {
                    current = i
                } else {
                    break
                }
            }
            current = min(current, pageCount - 1)
            if current != parent.model.index {
                parent.onPageChange?(current)
            }
        }
    }
}
