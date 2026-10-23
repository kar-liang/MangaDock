import SwiftUI
import UIKit

protocol PagerPage: AnyObject {
    var pageIndex: Int { get set }
}

/// UIPageViewController wrapper. SwiftUI's TabView(.page) keeps every page view
/// alive, which blows up memory on a 200-page chapter — this only holds ~3.
///
/// Taps are handled by a UITapGestureRecognizer that recognises *simultaneously*
/// with the pager's pan gesture. Doing it with a SwiftUI overlay instead would
/// swallow the swipe: the overlay becomes the hit-test target and the paging
/// scroll view underneath never sees the drag.
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

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator
        tap.cancelsTouchesInView = false
        tap.requiresExclusiveTouchType = false
        controller.view.addGestureRecognizer(tap)

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

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate,
                              UIGestureRecognizerDelegate {
        var parent: PagePager
        var isAnimating = false

        init(_ parent: PagePager) {
            self.parent = parent
        }

        func controller(for position: Int) -> UIViewController {
            if position < parent.model.pageCount {
                let host = ComicPageHost(rootView: ComicPageView(model: parent.model, index: position))
                host.pageIndex = position
                return host
            }
            let host = ChapterEndHost(rootView: ChapterEndView(model: parent.model))
            host.pageIndex = position
            return host
        }

        // MARK: Taps

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view, view.bounds.width > 0 else { return }
            let x = gesture.location(in: view).x
            let width = view.bounds.width
            if x < width * 0.33 {
                parent.onTapLeft()
            } else if x > width * 0.67 {
                parent.onTapRight()
            } else {
                parent.onTapCenter()
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
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
