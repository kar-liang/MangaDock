import SwiftUI
import UIKit

protocol PagerPage: AnyObject {
    var pageIndex: Int { get set }
}

/// UIPageViewController wrapper. SwiftUI's TabView(.page) keeps every page view
/// alive, which blows up memory on a 200-page chapter — this only holds ~3.
///
/// 本 wrapper 只负责滑动翻页。单击/双击/缩放全部由每页的 ZoomableImageView 在
/// 内部统一处理（单层手势，require(toFail:) 天然可靠），这里不再挂任何 tap 手势，
/// 避免跨层手势冲突（历史上双击放大和单击翻页分属两层，冲突修不完）。
struct PagePager: UIViewControllerRepresentable {
    @ObservedObject var model: ReaderModel
    @Binding var index: Int

    var onTapLeft: () -> Void = {}
    var onTapCenter: () -> Void = {}
    var onTapRight: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let controller = UIPageViewController(
            transitionStyle: .scroll,
            navigationOrientation: .horizontal,
            options: nil
        )
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        controller.view.backgroundColor = .black

        if model.displayPageCount > 0 {
            controller.setViewControllers([context.coordinator.controller(for: index)],
                                          direction: .forward,
                                          animated: false)
        }
        return controller
    }

    func updateUIViewController(_ controller: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        guard model.displayPageCount > 0, !context.coordinator.isAnimating else { return }

        if let current = controller.viewControllers?.first as? PagerPage,
           current.pageIndex == index {
            return
        }
        controller.setViewControllers([context.coordinator.controller(for: index)],
                                      direction: .forward,
                                      animated: false)
    }
    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: PagePager
        var isAnimating = false

        init(_ parent: PagePager) {
            self.parent = parent
        }

        func controller(for position: Int) -> UIViewController {
            if position < parent.model.pageCount {
                // 捕获三个回调（值拷贝），避免闭包捕获 self（Coordinator）造成循环引用。
                let onTapLeft = parent.onTapLeft
                let onTapCenter = parent.onTapCenter
                let onTapRight = parent.onTapRight
                let host = ComicPageHost(rootView: ComicPageView(
                    model: parent.model,
                    index: position,
                    onTap: { x in
                        // x 是点击位置在屏宽的比例。放大状态下 ZoomableImageView 会
                        // 固定传 0.5（走中间分支，只唤出工具栏），fit 状态按位置翻页。
                        if x < 0.33 {
                            onTapLeft()
                        } else if x > 0.67 {
                            onTapRight()
                        } else {
                            onTapCenter()
                        }
                    }
                ))
                host.pageIndex = position
                return host
            }
            let host = ChapterEndHost(rootView: ChapterEndView(model: parent.model))
            host.pageIndex = position
            return host
        }

        // MARK: Paging

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerBefore viewController: UIViewController) -> UIViewController? {
            guard let page = viewController as? PagerPage,
                  page.pageIndex > 0 else { return nil }
            return controller(for: page.pageIndex - 1)
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerAfter viewController: UIViewController) -> UIViewController? {
            guard let page = viewController as? PagerPage,
                  page.pageIndex + 1 < parent.model.displayPageCount else { return nil }
            return controller(for: page.pageIndex + 1)
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                willTransitionTo pendingViewControllers: [UIViewController]) {
            isAnimating = true
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController],
                                transitionCompleted completed: Bool) {
            isAnimating = false
            guard completed,
                  let page = pageViewController.viewControllers?.first as? PagerPage else { return }
            parent.index = page.pageIndex
        }
    }
}

final class ComicPageHost: UIHostingController<ComicPageView>, PagerPage {
    var pageIndex: Int = 0
}

final class ChapterEndHost: UIHostingController<ChapterEndView>, PagerPage {
    var pageIndex: Int = 0
}
