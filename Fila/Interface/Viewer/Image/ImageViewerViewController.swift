import FilaMedia
import FilaProtocol
import ImageIO
import SnapKit
import Then
import UIKit

/// Pinch and double-tap zoom over the image, plus the metadata worth reading.
///
/// The image is read through the descriptor and handed to ImageIO as data, never
/// as a URL: `UIImage(contentsOfFile:)` would open the path a second time, as
/// `mobile`, which is exactly the open that fails for every interesting file on
/// the device.
final class ImageViewerViewController: UIViewController {
    private let details: FileDetails
    private let file: DescriptorFile
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private var metadata: [(String, String)] = []

    init(details: FileDetails, file: DescriptorFile) {
        self.details = details
        self.file = file
        super.init(nibName: nil, bundle: nil)
        title = URL(fileURLWithPath: details.path).lastPathComponent
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

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
            make.leading.trailing.equalToSuperview()
            make.top.bottom.equalTo(view.safeAreaLayoutGuide)
        }

        let container = parent as? ViewerContainerViewController
        container?.childMenuElements = [UIAction(
            title: String(localized: "Image Info"),
            image: UIImage(systemName: "info.circle")
        ) { [weak self] _ in self?.showMetadata() }]
        container?.refreshBarItems()

        load()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard imageView.bounds.size != scrollView.bounds.size else { return }
        scrollView.setZoomScale(scrollView.minimumZoomScale, animated: false)
        imageView.frame = CGRect(origin: .zero, size: scrollView.bounds.size)
        scrollView.contentSize = scrollView.bounds.size
    }

    private func load() {
        do {
            let data = try file.readAll(limit: ViewerLimits.inMemoryDocumentByteCount)
            guard let raster = ImagePreview.make(data: data) else {
                throw ViewerFailure.unsupportedContent(
                    String(localized: "This image format is not supported. Open it as Hex to see its contents.")
                )
            }
            let image = UIImage(cgImage: raster)
            imageView.image = image
            metadata = Self.describe(data, details: details)
        } catch {
            let label = UILabel().then {
                $0.text = FailureMessage.text(for: error)
                $0.numberOfLines = 0
                $0.textAlignment = .center
                $0.textColor = .secondaryLabel
            }
            view.addSubview(label)
            label.snp.makeConstraints { make in
                make.centerY.equalToSuperview()
                make.leading.trailing.equalTo(view.readableContentGuide)
            }
        }
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
                    size: size
                ),
                animated: true
            )
        }
    }

    @objc private func showMetadata() {
        let controller = KeyValueListViewController(
            title: String(localized: "Image Info"),
            rows: metadata
        )
        controller.navigationItem.rightBarButtonItem = nil
        presentAsSheet(UINavigationController(rootViewController: controller))
    }

    /// Pixel dimensions first, because that is what someone opening an asset in
    /// a bundle actually came for. The EXIF selection is the shooting settings
    /// and the timestamp; the full dictionary is dozens of keys, most of them
    /// vendor noise.
    private static func describe(_ data: Data, details: FileDetails) -> [(String, String)] {
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
            FilePresentation.byteLabel(details.node.size)
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

extension ImageViewerViewController: UIScrollViewDelegate {
    func viewForZooming(in _: UIScrollView) -> UIView? {
        imageView
    }
}
