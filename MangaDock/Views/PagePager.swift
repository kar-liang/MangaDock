import SwiftUI
import UIKit

/// UIPageViewController wrapper. SwiftUI's TabView(.page) keeps every page view
/// alive, which blows up memory on a 200-page chapter — this only holds ~3.
struct PagePager: UIViewControllerRepresentable {
    @ObservedObject var model: ReaderModel
    @Binding var index: Int

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

        if model.pageCount > 0 {
            controller.setViewControllers([context.coordinator.controller(for: index)],
                                          direction: .forward,
                                          animated: false)
        }
        return controller
    }

    func updateUIViewController(_ controller: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        guard model.pageCount > 0, !context.coordinator.isAnimating else { return }

        if let current = controller.viewControllers?.first as? ComicPageHost,
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

        func controller(for position: Int) -> ComicPageHost {
            let host = ComicPageHost(rootView: ComicPageView(model: parent.model, index: position))
            host.pageIndex = position
            return host
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerBefore viewController: UIViewController) -> UIViewController? {
            guard let host = viewController as? ComicPageHost,
                  host.pageIndex > 0,
                  host.pageIndex < parent.model.pageCount else { return nil }
            return controller(for: host.pageIndex - 1)
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerAfter viewController: UIViewController) -> UIViewController? {
            guard let host = viewController as? ComicPageHost,
                  host.pageIndex + 1 < parent.model.pageCount else { return nil }
            return controller(for: host.pageIndex + 1)
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
                  let host = pageViewController.viewControllers?.first as? ComicPageHost else { return }
            parent.index = host.pageIndex
        }
    }
}

final class ComicPageHost: UIHostingController<ComicPageView> {
    var pageIndex: Int = 0
}
