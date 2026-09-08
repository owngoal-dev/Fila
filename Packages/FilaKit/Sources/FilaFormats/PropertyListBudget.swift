import Foundation

/// Bound the input and the tree copied into an editor. Foundation still owns
/// the initial parse; this avoids amplifying it again into unbounded Swift trees.
public enum PropertyListBudget {
    public static func parse(_ data: Data, format: inout PropertyListSerialization.PropertyListFormat) throws -> Any {
        guard data.count <= PreviewLimits.textByteCount else {
            throw FormatFailure.tooLarge(byteCount: Int64(data.count), limit: PreviewLimits.textByteCount)
        }
        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
        } catch {
            throw FormatFailure.damaged(String(localized: "it is not a property list", bundle: .module))
        }
        try validate(object)
        return object
    }

    public static func serialize(_ object: Any, format: PropertyListSerialization.PropertyListFormat) throws -> Data {
        try validate(object)
        let data = try PropertyListSerialization.data(fromPropertyList: object, format: format, options: 0)
        guard data.count <= PreviewLimits.textByteCount else {
            throw FormatFailure.tooLarge(byteCount: Int64(data.count), limit: PreviewLimits.textByteCount)
        }
        return data
    }

    public static func validate(_ object: Any) throws {
        var remainingNodes = 100_000
        var remainingBytes = PreviewLimits.textByteCount
        func consume(_ count: Int) throws {
            guard count <= remainingBytes else {
                throw FormatFailure.tooLarge(
                    byteCount: PreviewLimits.textByteCount + 1,
                    limit: PreviewLimits.textByteCount
                )
            }
            remainingBytes -= Int64(count)
        }
        func visit(_ value: Any, depth: Int) throws {
            guard depth <= 64, remainingNodes > 0 else {
                throw FormatFailure.unsupported(
                    String(localized: "a property list with this many values or nesting levels", bundle: .module)
                )
            }
            remainingNodes -= 1
            switch value {
            case let text as String: try consume(text.utf8.count)
            case let data as Data: try consume(data.count)
            case let values as [Any]:
                guard values.count <= remainingNodes else {
                    throw FormatFailure.unsupported(
                        String(localized: "a property list with this many values or nesting levels", bundle: .module)
                    )
                }
                for child in values {
                    try visit(child, depth: depth + 1)
                }
            case let values as [String: Any]:
                guard values.count <= remainingNodes else {
                    throw FormatFailure.unsupported(
                        String(localized: "a property list with this many values or nesting levels", bundle: .module)
                    )
                }
                for (key, child) in values {
                    try consume(key.utf8.count)
                    try visit(child, depth: depth + 1)
                }
            default: break
            }
        }
        try visit(object, depth: 0)
    }
}
