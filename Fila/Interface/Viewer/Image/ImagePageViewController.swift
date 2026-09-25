import FilaBackendUI
import FilaMedia
import FilaProtocol
import ImageIO
import SnapKit
import Then
import UIKit

/// One image, with pinch and double-tap zoom over it, plus the metadata worth
/// reading.
///
/// The image is read through the descriptor and handed to ImageIO as data, never
/// as a URL: `UIImage(contentsOfFile:)` would open the path a second time, as
/// `mobile`, which is exactly the open that fails for every interesting file on
/// the device.
final class ImagePageViewController: UIViewController {
    /// Where this page sits in its gallery; zero without one.
    let index: Int
    let name: String
    /// Nil until the file has been looked up, and for good if the lookup failed.
    /// The screen's file menu acts on this, so it stays off until it is known.
    private(set) var details: FileDetails?
    private(set) var metadata: [(String, String)] = []
    /// Once the page knows which file it shows, or that it cannot show one.
    var onSettled: ((ImagePageViewController) -> Void)?

    private enum Source {
        /// The file the viewer container already opened; decoded before the
        /// push, so the first image is on screen when the transition starts.
        case opened(DescriptorFile)
        /// A neighbour, looked up and decoded off the main thread while the
        /// user is still looking at the page beside it.
        case path(String)
    }

    private let source: Source
    private var loadTask: Task<Void, Never>?
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()

    init(index: Int, details: FileDetails, file: DescriptorFile) {
        self.index = index
        self.details = details
        name = URL(fileURLWithPath: details.path).lastPathComponent
        source = .opened(file)
        super.init(nibName: nil, bundle: nil)
    }

    init(index: Int, path: String) {
        self.index = index
        name = URL(fileURLWithPath: path).lastPathComponent
        source = .path(path)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    deinit { loadTask?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        scrollView.do {
            $0.delegate = self
            $0.minimumZoomScale = 1
            $0.maximumZoomScale = 12
            $0.showsHorizontalScrollIndicator = false
            $0.showsVerticalScrollIndicator = false
            $0.contentInsetAdjustmentBehavior = .never
        }

        imageView.do {
            $0.contentMode = .scaleAspectFit
            $0.frame = view.bounds
            $0.isUserInteractionEnabled = true
        }

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        imageView.addGestureRecognizer(doubleTap)

        scrollView.addSubview(imageView)
        view.addSubview(scrollView)
        scrollView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        load()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard imageView.bounds.size != scrollView.bounds.size else { return }
        scrollView.setZoomScale(scrollView.minimumZoomScale, animated: false)
        imageView.frame = CGRect(origin: .zero, size: scrollView.bounds.size)
        scrollView.contentSize = scrollView.bounds.size
    }

    /// A page swiped away comes back whole, the way Photos does it. Only a
    /// swipe: a tab switch or a pushed Properties page keeps the zoom.
    func resetZoom() {
        scrollView.setZoomScale(scrollView.minimumZoomScale, animated: false)
    }

    private func load() {
        switch source {
        case let .opened(file):
            guard let details else { return }
            do {
                try show(Self.decode(file, details: details))
            } catch {
                show(failure: error)
            }
        case let .path(path):
            loadTask = Task { [weak self] in
                var found: FileDetails?
                do {
                    // Through the session, which retries a read the daemon's
                    // idle exit dropped: a swipe after a pause must not show
                    // "connection reset" for an image that is fine. The open
                    // is read-only, so asking twice costs nothing.
                    let session = FileSession.shared
                    let details = try await session.perform(retryOnDisconnect: true) { try await $0.details(of: path) }
                    found = details
                    let file = try await session.perform(retryOnDisconnect: true) {
                        try await DescriptorFile.open(path, link: $0)
                    }
                    // A page swiped past before its decode finished is
                    // released; its decode stops at the next check instead of
                    // holding a whole file and a raster nobody will see.
                    let worker = Task.detached(priority: .userInitiated) {
                        try Self.decode(file, details: details)
                    }
                    let decoded = try await withTaskCancellationHandler {
                        try await worker.value
                    } onCancel: { worker.cancel() }
                    guard let self, !Task.isCancelled else { return }
                    self.details = details
                    show(decoded)
                } catch {
                    guard let self, !Task.isCancelled else { return }
                    details = found
                    show(failure: error)
                }
            }
        }
    }

    /// Reads the whole file, decodes its first frame and describes it, then
    /// closes the descriptor: the page keeps the raster, never the bytes.
    private nonisolated static func decode(
        _ file: DescriptorFile,
        details: FileDetails,
    ) throws -> (image: CGImage, metadata: [(String, String)]) {
        defer { file.close() }
        try Task.checkCancellation()
        let data = try file.readAll(limit: ViewerLimits.inMemoryDocumentByteCount)
        try Task.checkCancellation()
        guard let raster = ImagePreview.make(data: data) else {
            throw ViewerFailure.unsupportedContent(
                String(localized: "This image format is not supported. Open it as Hex to see its contents."),
            )
        }
        return (raster, describe(data, details: details))
    }

    private func show(_ decoded: (image: CGImage, metadata: [(String, String)])) {
        imageView.image = UIImage(cgImage: decoded.image)
        // Without a label the whole screen is one unnamed image. The file
        // name is what the title bar already says this is.
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = name
        imageView.accessibilityTraits = .image
        metadata = decoded.metadata
        onSettled?(self)
    }

    private func show(failure: Error) {
        let label = UILabel().then {
            $0.text = FailureMessage.text(for: failure)
            $0.numberOfLines = 0
            $0.textAlignment = .center
            $0.textColor = .secondaryLabel
        }
        view.addSubview(label)
        label.snp.makeConstraints { make in
            make.centerY.equalToSuperview()
            make.leading.trailing.equalTo(view.readableContentGuide)
        }
        onSettled?(self)
    }

    @objc private func toggleZoom(_ gesture: UITapGestureRecognizer) {
        if scrollView.zoomScale > scrollView.minimumZoomScale {
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
        } else {
            let point = gesture.location(in: imageView)
            let size = CGSize(width: scrollView.bounds.width / 4, height: scrollView.bounds.height / 4)
            scrollView.zoom(
                to: CGRect(
                    origin: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2),
                    size: size,
                ),
                animated: true,
            )
        }
    }

    /// Pixel dimensions first, because that is what someone opening an asset in
    /// a bundle actually came for. The EXIF selection is the shooting settings
    /// and the timestamp; the full dictionary is dozens of keys, most of them
    /// vendor noise.
    private nonisolated static func describe(_ data: Data, details: FileDetails) -> [(String, String)] {
        var rows: [(String, String)] = []
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return rows }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]

        if let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int
        {
            rows.append((String(localized: "Dimensions"), "\(width) × \(height)"))
        }

        if let type = CGImageSourceGetType(source) {
            rows.append((String(localized: "Type"), type as String))
        }
        if let depth = properties[kCGImagePropertyDepth] as? Int {
            rows.append((String(localized: "Bit Depth"), String(depth)))
        }
        if let model = properties[kCGImagePropertyColorModel] as? String {
            rows.append((String(localized: "Color Model"), model))
        }
        if let profile = properties[kCGImagePropertyProfileName] as? String {
            rows.append((String(localized: "Color Profile"), profile))
        }
        if CGImageSourceGetCount(source) > 1 {
            rows.append((String(localized: "Frames"), String(CGImageSourceGetCount(source))))
        }
        rows.append((
            String(localized: "File Size"),
            FilePresentation.byteLabel(details.node.size),
        ))

        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            let interesting: [(CFString, String)] = [
                (kCGImagePropertyExifDateTimeOriginal, String(localized: "Taken")),
                (kCGImagePropertyExifLensModel, String(localized: "Lens")),
                (kCGImagePropertyExifFNumber, String(localized: "Aperture")),
                (kCGImagePropertyExifExposureTime, String(localized: "Exposure")),
                (kCGImagePropertyExifFocalLength, String(localized: "Focal Length")),
            ]
            for (key, label) in interesting {
                if let value = exif[key] {
                    rows.append((label, "\(value)"))
                }
            }
            if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Any])?.first {
                rows.append((String(localized: "ISO"), "\(iso)"))
            }
        }
        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            if let make = tiff[kCGImagePropertyTIFFMake] {
                rows.append((String(localized: "Camera Make"), "\(make)"))
            }
            if let model = tiff[kCGImagePropertyTIFFModel] {
                rows.append((String(localized: "Camera Model"), "\(model)"))
            }
        }
        // The coordinates themselves are not shown: this is a file manager, and
        // the answer someone needs before sharing a file is whether they are in
        // there at all.
        if properties[kCGImagePropertyGPSDictionary] != nil {
            rows.append((String(localized: "Location"), String(localized: "Present in this file")))
        }
        return rows
    }
}

extension ImagePageViewController: UIScrollViewDelegate {
    func viewForZooming(in _: UIScrollView) -> UIView? {
        imageView
    }
}
