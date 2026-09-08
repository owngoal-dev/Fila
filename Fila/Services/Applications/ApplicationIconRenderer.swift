import Darwin
import ObjectiveC
import UIKit

// ISIcon is a class cluster: its allocator supplies the concrete factory.
// Declaring the initializers lets ARC own both allocation and initialization.
@objc private protocol SystemIcon {
    init?(bundleIdentifier: String)
    func prepareImage(forDescriptor descriptor: AnyObject) -> NSObject?
}

@objc private protocol SystemIconDescriptor {
    init?(size: CGSize, scale: CGFloat)
    var shouldApplyMask: Bool { get set }
}

@objc private protocol SystemIconImage {
    var cgImage: CGImage? { get }
    @objc(CGImage) var legacyCGImage: CGImage? { get }
}

enum ApplicationIconRenderer {
    // Keep the framework loaded for the lifetime of its Objective-C objects.
    private static let isAvailable = dlopen(
        "/System/Library/PrivateFrameworks/IconServices.framework/IconServices",
        RTLD_NOW
    ) != nil

    /// Called off the main actor; IconServices may contact its rendering agent.
    static func image(for identifier: String, scale: CGFloat) -> UIImage? {
        autoreleasepool {
            guard isAvailable,
                  let iconClass = NSClassFromString("ISIcon"),
                  let descriptorClass = NSClassFromString("ISImageDescriptor"),
                  let icon = unsafeBitCast(iconClass, to: SystemIcon.Type.self).init(bundleIdentifier: identifier),
                  let descriptor = unsafeBitCast(descriptorClass, to: SystemIconDescriptor.Type.self)
                    .init(size: CGSize(width: 60, height: 60), scale: scale) else { return nil }
            descriptor.shouldApplyMask = true
            guard let rendered = icon.prepareImage(forDescriptor: descriptor) else { return nil }
            let image = unsafeBitCast(rendered, to: SystemIconImage.self)
            let cgImage: CGImage?
            if rendered.responds(to: #selector(getter: SystemIconImage.cgImage)) {
                cgImage = image.cgImage
            } else if rendered.responds(to: #selector(getter: SystemIconImage.legacyCGImage)) {
                cgImage = image.legacyCGImage
            } else {
                return nil
            }
            guard let cgImage else { return nil }
            return UIImage(cgImage: cgImage, scale: scale, orientation: .up).withRenderingMode(.alwaysOriginal)
        }
    }
}
