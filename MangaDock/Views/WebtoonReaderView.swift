import SwiftUI
import UIKit

/// 能在布局完成后回调的 UIScrollView。
///
/// 首帧的 `bounds` 只有在 `layoutSubviews` 里才是准的：`makeUIView` 那一刻是零，
/// `DispatchQueue.main.async` 也未必赶得上（SwiftUI 的布局是在更后面的 runloop 做的）。
/// 条漫「首进全黑三四秒」就是因为宽度一直是 0，所有页都是零尺寸。
final class LayoutReportingScrollView: UIScrollView {
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

/// 条漫模式的整章缩放视图。
///
/// 把整个章节当成「一张超长图」来缩放：所有页面垂直拼成一个 contentView，
/// 用 UIScrollView 的原生 zoomScale 做整章缩放——捏合、双击、拖动、边界回弹、
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
        let scroll = LayoutReportingScrollView()
        scroll.delegate = context.coordinator
        scroll.backgroundColor = .white
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
        content.backgroundColor = .white
        scroll.addSubview(content)
        context.coordinator.contentView = content
        context.coordinator.scrollView = scroll

        // 单击：切换工具栏显隐（双击已删除）。
        let single = UITapGestureRecognizer(target: context.coordinator,
                                            action: #selector(Coordinator.handleSingleTap(_:)))
        single.numberOfTapsRequired = 1
        single.delegate = context.coordinator
        scroll.addGestureRecognizer(single)

        let coord = context.coordinator
        scroll.onLayout = { [weak coord] in coord?.handleLayout() }

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
        // 转圈是手动摆位置的，bounds 有值之后得校正一次 ——
        // makeUIView 里拿到的 bounds 还是零，那一帧的定位（0,0）会把它扔到左上角看不见。
        context.coordinator.refreshIndicator()
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
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
        /// 加载失败（拿不到图）的页。不记下来的话转圈会永远停不下来。
        private var failedPages: Set<Int> = []
        /// 悬浮在可视区中心的转圈。不挂在某一页上：条漫单页可能比屏幕还高，
        /// 挂在页面中心的话转圈会跑到屏幕外面去。
        private var indicator: UIActivityIndicatorView?
        /// 转圈下面的说明文字，跟图1 那种「正在下载 xxx」的反馈对齐。
        private var indicatorLabel: UILabel?
        /// 结尾卡（本话看完 / 下一话）。用 UIHostingController 把 SwiftUI 的
        /// ChapterEndView 塞进 UIScrollView 的内容末尾。
        ///
        /// 2.0.12 把条漫从 SwiftUI 的 LazyVStack 换成原生 UIScrollView 时，
        /// 这一块被漏掉了 —— 原来的 `if nextItem != nil { ChapterEndView(...) }`
        /// 变成了 `let footer: CGFloat = 300` 的一段空白。用户滑到底只看到黑屏。
        private var endHost: UIHostingController<ChapterEndView>?
        private let endCardHeight: CGFloat = 360

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
            failedPages.removeAll()

            // 加载指示器：挂在 scrollView 上（不随内容滚走），位置每次由
            // positionIndicator() 摆到可视区中心。
            if indicator == nil {
                let ind = UIActivityIndicatorView(style: .medium)
                ind.color = UIColor.black.withAlphaComponent(0.55)
                ind.hidesWhenStopped = true
                ind.isUserInteractionEnabled = false
                scroll.addSubview(ind)
                indicator = ind

                let label = UILabel()
                label.font = .preferredFont(forTextStyle: .footnote)
                label.textColor = UIColor.black.withAlphaComponent(0.8)
                label.textAlignment = .center
                label.isHidden = true
                label.isUserInteractionEnabled = false
                scroll.addSubview(label)
                indicatorLabel = label
            }
            indicator?.stopAnimating()
            indicatorLabel?.isHidden = true

            rebuildEndCard(in: contentView)

            let count = pageCount
            for i in 0..<count {
                let iv = UIImageView()
                // frame 高度按图片真实宽高比精确算，scaleToFill 正好 1:1 铺满，
                // 不会像 scaleAspectFit 那样在边缘留黑边。
                iv.contentMode = .scaleToFill
                iv.clipsToBounds = true
                iv.backgroundColor = .white
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

        /// 布局完成后补一次排版 + 加载。
        ///
        /// 只在「宽度变了」或「还有页是零高度」时重排，避免
        /// layoutSubviews ↔ contentSize 变化互相触发形成死循环。
        func handleLayout() {
            guard let scrollView, scrollView.bounds.width > 0 else { return }
            let needsRelayout = abs(layoutWidth - scrollView.bounds.width) > 0.5
                || pageViews.contains { $0.frame.height == 0 }
            if needsRelayout {
                relayout()   // 内部已经调过 loadVisiblePages
            }
            refreshIndicator()
        }

        /// 重建内容末尾的结尾卡。
        private func rebuildEndCard(in contentView: UIView) {
            endHost?.view.removeFromSuperview()
            let host = UIHostingController(rootView: ChapterEndView(model: parent.model))
            host.view.backgroundColor = .clear
            contentView.addSubview(host.view)
            endHost = host
        }

        /// 计算所有页 frame 和 contentView 高度。
        func relayout() {
            guard let contentView, let scrollView else { return }
            // pageWidth 还没从 SwiftUI 传进来时，先用 scrollView 自己的宽度兜底。
            // 否则所有页都是零尺寸：画面全黑、点不到东西、连加载转圈都判不出来
            // （refreshIndicator 找「视口内的页」一个都找不到，以为没东西要等）。
            let width = parent.pageWidth > 0 ? parent.pageWidth : scrollView.bounds.width
            guard width > 0 else { return }
            layoutWidth = width

            var y: CGFloat = 0
            for i in 0..<pageViews.count {
                let aspect = layoutAspects[i]
                let height = aspect > 0 ? width / aspect : width / 0.72
                pageViews[i].frame = CGRect(x: 0, y: y, width: width, height: height)
                y += height
            }
            // 结尾卡压在最后一页下面。
            if let card = endHost?.view, card.superview != nil {
                card.frame = CGRect(x: 0, y: y, width: width, height: endCardHeight)
                y += endCardHeight
            }

            contentView.frame = CGRect(x: 0, y: 0, width: width, height: y)
            scrollView.contentSize = CGSize(width: width, height: y)

            // 重排后可视范围变了，补一次按需加载。
            // 首次进入时 pageWidth 是 0、relayout 直接 return，所有页都是零尺寸；
            // 等宽度量出来再走到这里 —— 不补这一步就是「布局好了但一直不加载」，全黑且没有提示。
            loadVisiblePages()
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

            // 预加载下一话：判据统一交给 model（最后 5 页内自动触发），
            // 视图层不再额外要求「必须滚到最后一页」—— 那样两边触发时机不一致。
            parent.model.preloadNextChapterIfNeeded()

            refreshIndicator()
        }

        private func loadPage(_ index: Int) {
            guard index >= 0, index < pageCount else { return }
            guard !failedPages.contains(index) else { return }
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
                guard let image, index < self.pageViews.count else {
                    // 拿不到图：记下来，别让它一直吊着转圈。
                    self.failedPages.insert(index)
                    self.refreshIndicator()
                    return
                }
                self.pageViews[index].image = image
                self.loadedPages.insert(index)

                // 用图片真实尺寸算精确宽高比（不依赖 model 的 pageAspects，
                // 它可能因 decode 时序滞后导致估算高度留黑边），变化则重排。
                let newAspect = image.size.width / max(image.size.height, 1)
                if abs(newAspect - self.layoutAspects[index]) > 0.001 {
                    self.layoutAspects[index] = newAspect
                    self.relayout()
                }
                self.refreshIndicator()
            }
        }

        // MARK: - Loading indicator

        /// 只按「当前视口里有没有还没出图的页」来转圈。
        ///
        /// 早先按待加载任务计数，结果上下各一屏的预加载一直让计数 > 0，
        /// 用户正常往下看已经加载好的页面时，屏幕中间那颗圈就没停过。
        /// 预加载是后台行为，不该有前景提示。
        func refreshIndicator() {
            guard let scrollView, let ind = indicator else { return }
            // 尺寸还没量出来时别定位，等下一轮 updateUIView 再来。
            guard scrollView.bounds.width > 0, scrollView.bounds.height > 0 else { return }
            let zoom = max(scrollView.zoomScale, 0.0001)
            let top = scrollView.contentOffset.y / zoom
            let bottom = (scrollView.contentOffset.y + scrollView.bounds.height) / zoom

            var waiting: Int?
            // 还没排版（所有页零高度）时判断不出「视口里有哪些页」，
            // 这时只要还有页没出图就先转圈 —— 否则用户对着全黑屏等好几秒，没有任何反馈。
            let laidOut = pageViews.contains { $0.frame.height > 0 }
            if laidOut {
                waiting = pageViews.indices.first { i in
                    let f = pageViews[i].frame
                    guard f.maxY > top, f.minY < bottom else { return false }
                    return pageViews[i].image == nil && !failedPages.contains(i)
                }
            } else {
                waiting = pageViews.indices.first {
                    pageViews[$0].image == nil && !failedPages.contains($0)
                }
            }

            if let index = waiting {
                indicatorLabel?.text = pageCount > 1
                    ? "正在加载 第 \(index + 1) / \(pageCount) 页"
                    : "正在加载…"
                indicatorLabel?.isHidden = false
                positionIndicator()
                ind.startAnimating()
            } else {
                ind.stopAnimating()
                indicatorLabel?.isHidden = true
            }
        }

        /// 把转圈和说明文字摆到当前可视区中心（contentOffset 走了它们得跟着走）。
        private func positionIndicator() {
            guard let scrollView, let ind = indicator else { return }
            let cx = scrollView.contentOffset.x + scrollView.bounds.width / 2
            let cy = scrollView.contentOffset.y + scrollView.bounds.height / 2
            let hasLabel = indicatorLabel?.isHidden == false
            ind.center = CGPoint(x: cx, y: hasLabel ? cy - 16 : cy)

            if let label = indicatorLabel, hasLabel {
                label.sizeToFit()
                label.center = CGPoint(x: cx, y: cy + 22)
            }
        }

        // MARK: - Tap

        @objc func handleSingleTap(_ recognizer: UITapGestureRecognizer) {
            // 单击立即触发（双击已删除，无需延迟等双击判定）。
            parent.onTap?()
        }

        /// 点在结尾卡的按钮上时别顺手把工具栏切出来。
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldReceive touch: UITouch) -> Bool {
            !(touch.view is UIControl)
        }

        // MARK: - UIScrollViewDelegate

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            contentView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            // 缩放后重新加载可视页（缩放改变了可视范围）。
            loadVisiblePages()
            positionIndicator()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            loadVisiblePages()
            updateProgress(scrollView)
            positionIndicator()

            // 底部 overshoot 换章**不在这里判**。滚动过程中每一帧都会冲过阈值，
            // 手指一甩就跳章，根本停不下来 —— 见 scrollViewDidEndDragging。
        }

        /// 底部拉过头换下一话。
        ///
        /// 判据放在「松手」这个时刻，而不是滚动过程中：
        /// 滚动时 offset 会因为惯性瞬间越过任何阈值，用户完全没机会看完结尾卡。
        /// 现在必须**滑到底之后还能再拉出 100pt 再松手**，才算「我要往下走」。
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            // 放大看细节时不换章
            guard scrollView.zoomScale < 1.05 else { return }
            // 内容比屏幕还短时没有「到底」可言，别误判
            guard scrollView.contentSize.height > scrollView.bounds.height else { return }

            let bottom = scrollView.contentSize.height - scrollView.bounds.height
            let overshoot = scrollView.contentOffset.y - bottom
            guard overshoot > 100 else { return }
            parent.onNextChapter?()
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
