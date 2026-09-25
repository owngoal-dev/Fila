import FilaBackendUI
import FilaProtocol
import SnapKit
import UIKit

/// The image viewer: one zoomable page, or — opened from a folder holding
/// more than one image — a horizontal pager through them.
///
/// A zoomed page pans to its edge before the pager takes the swipe, which is
/// what nesting a zooming scroll view inside a scrolling page controller does
/// by itself. Only the page on screen and its two neighbours are kept, so a
/// folder of photos costs three rasters, not all of them.
final class ImageViewerViewController: TabContentViewController {
    private let gallery: ImageGallery?
    /// Built only for a gallery. A lone image is hosted directly: a pager with
    /// nothing to page to still owns a horizontal scroll view, and that would
    /// take the full-width swipe back out of the navigation controller.
    private lazy var pages = UIPageViewController(
        transitionStyle: .scroll,
        navigationOrientation: .horizontal,
        options: [.interPageSpacing: FilaUI.Spacing.large],
    )
    private var current: ImagePageViewController
    /// The pages already made, by gallery index. The pager asks for a
    /// neighbour again whenever a swipe starts, and an abandoned swipe must
    /// not read and decode the same file twice.
    private var made: [Int: ImagePageViewController] = [:]

    private var container: ViewerContainerViewController? {
        parent as? ViewerContainerViewController
    }

    init(details: FileDetails, file: DescriptorFile, gallery: ImageGallery?) {
        self.gallery = gallery
        current = ImagePageViewController(index: gallery?.index ?? 0, details: details, file: file)
        made[current.index] = current
        super.init(nibName: nil, bundle: nil)
        title = current.name
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let host: UIViewController
        if gallery != nil {
            pages.dataSource = self
            pages.delegate = self
            host = pages
        } else {
            host = current
        }
        addChild(host)
        view.addSubview(host.view)
        host.view.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview()
            make.top.bottom.equalTo(view.safeAreaLayoutGuide)
        }
        host.didMove(toParent: self)
        // Decoded now, while the container is still preparing the push, so
        // the transition slides in the image rather than an empty page.
        current.loadViewIfNeeded()
        if gallery != nil {
            pages.setViewControllers([current], direction: .forward, animated: false)
        }

        container?.childMenuElements = [UIAction(
            title: String(localized: "Image Info"),
            image: UIImage(systemName: "info.circle"),
        ) { [weak self] _ in self?.showMetadata() }]
        container?.refreshBarItems()
    }

    private func page(at index: Int) -> ImagePageViewController? {
        guard let gallery, gallery.names.indices.contains(index) else { return nil }
        if let page = made[index] {
            return page
        }
        let page = ImagePageViewController(index: index, path: gallery.path(at: index))
        page.onSettled = { [weak self] page in
            guard let self, page === current else { return }
            follow(page)
        }
        made[index] = page
        return page
    }

    /// Hands the screen to the page now showing: its name in the title, its
    /// file behind the breadcrumb and the menu. Pages further than one swipe
    /// away are let go; one still loading stops with it.
    private func follow(_ page: ImagePageViewController) {
        current = page
        made = made.filter { abs($0.key - page.index) <= 1 }
        title = page.name
        container?.follow(page.details, galleryIndex: page.index)
    }

    @objc private func showMetadata() {
        let controller = KeyValueListViewController(
            title: String(localized: "Image Info"),
            rows: current.metadata,
        )
        presentAsSheet(UINavigationController(rootViewController: controller))
    }
}

extension ImageViewerViewController: UIPageViewControllerDataSource, UIPageViewControllerDelegate {
    func pageViewController(
        _: UIPageViewController,
        viewControllerBefore viewController: UIViewController,
    ) -> UIViewController? {
        (viewController as? ImagePageViewController).flatMap { page(at: $0.index - 1) }
    }

    func pageViewController(
        _: UIPageViewController,
        viewControllerAfter viewController: UIViewController,
    ) -> UIViewController? {
        (viewController as? ImagePageViewController).flatMap { page(at: $0.index + 1) }
    }

    func pageViewController(
        _: UIPageViewController,
        didFinishAnimating _: Bool,
        previousViewControllers: [UIViewController],
        transitionCompleted completed: Bool,
    ) {
        guard completed, let page = pages.viewControllers?.first as? ImagePageViewController,
              page !== current else { return }
        for previous in previousViewControllers {
            (previous as? ImagePageViewController)?.resetZoom()
        }
        follow(page)
    }
}
