import Foundation

/// A property list as a tree the UI can walk and edit.
///
/// `PropertyListSerialization` hands back `Any` full of `NSNumber`, and an
/// `NSNumber` does not say what it was written as — which is how a plist editor
/// turns `<integer>1</integer>` into `<real>1</real>` and a launchd job stops
/// parsing. Every case here is a distinct plist type, decided once on the way
/// in, so a round trip cannot quietly change one.
public indirect enum PropertyListValue: Sendable, Hashable {
    case boolean(Bool)
    case integer(Int64)
    case real(Double)
    case string(String)
    case date(Date)
    case data(Data)
    case array([PropertyListValue])
    /// Plists have no key order — XML preserves the order it was written in,
    /// binary does not, and a round trip through either is free to reshuffle.
    /// The view sorts; nothing here pretends to remember.
    case dictionary([String: PropertyListValue])

    init(propertyList object: Any) throws {
        switch object {
        case let value as String: self = .string(value)
        case let value as Date: self = .date(value)
        case let value as Data: self = .data(value)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                self = .boolean(value.boolValue)
            } else if value.isFloatingPoint {
                self = .real(value.doubleValue)
            } else {
                self = .integer(value.int64Value)
            }
        case let value as [Any]:
            self = try .array(value.map(PropertyListValue.init(propertyList:)))
        case let value as [String: Any]:
            self = try .dictionary(value.mapValues(PropertyListValue.init(propertyList:)))
        default:
            throw FormatFailure.unsupported("it contains a value a property list cannot hold")
        }
    }

    var propertyListObject: Any {
        switch self {
        case let .boolean(value): value as NSNumber
        case let .integer(value): NSNumber(value: value)
        case let .real(value): NSNumber(value: value)
        case let .string(value): value
        case let .date(value): value
        case let .data(value): value
        case let .array(value): value.map(\.propertyListObject)
        case let .dictionary(value): value.mapValues(\.propertyListObject)
        }
    }
}

private extension NSNumber {
    /// `<real>` or `<integer>`, from the type the number actually carries.
    ///
    /// `CFNumberIsFloatType` would answer the same question, but reaching it
    /// from Swift means casting an `NSNumber` that might be a boolean to a
    /// `CFNumber`, and the Objective-C type encoding says it without the cast.
    var isFloatingPoint: Bool {
        let encoding = objCType.pointee
        return encoding == UInt8(ascii: "f") || encoding == UInt8(ascii: "d")
    }
}

/// One step into a `PropertyListValue`.
public enum PropertyListPathComponent: Sendable, Hashable {
    case key(String)
    case index(Int)
}

public extension PropertyListValue {
    /// The value at a path, and the one way to change it.
    ///
    /// An editor addresses a row by where it is, not by holding a reference
    /// into a value type it cannot mutate through. Assigning nil removes: a
    /// dictionary loses the key, an array loses the element. Assigning at an
    /// array index equal to the count appends. A path that does not lead
    /// anywhere — a key on an integer, an index past the end — reads nil and
    /// writes nothing, because a subscript cannot throw and a plist editor
    /// with a stale path must not take the document with it.
    subscript(path: [PropertyListPathComponent]) -> PropertyListValue? {
        get { PropertyListValue.value(at: path[...], in: self) }
        set { self = PropertyListValue.replacing(path[...], in: self, with: newValue) }
    }

    private static func value(at path: ArraySlice<PropertyListPathComponent>, in value: PropertyListValue) -> PropertyListValue? {
        guard let head = path.first else { return value }
        switch (head, value) {
        case let (.key(name), .dictionary(entries)):
            return entries[name].flatMap { self.value(at: path.dropFirst(), in: $0) }
        case let (.index(position), .array(elements)):
            guard elements.indices.contains(position) else { return nil }
            return self.value(at: path.dropFirst(), in: elements[position])
        default:
            return nil
        }
    }

    private static func replacing(
        _ path: ArraySlice<PropertyListPathComponent>,
        in value: PropertyListValue,
        with replacement: PropertyListValue?
    ) -> PropertyListValue {
        guard let head = path.first else { return replacement ?? value }
        let rest = path.dropFirst()
        switch (head, value) {
        case let (.key(name), .dictionary(entries)):
            var entries = entries
            if rest.isEmpty {
                entries[name] = replacement
            } else if let child = entries[name] {
                entries[name] = replacing(rest, in: child, with: replacement)
            }
            return .dictionary(entries)
        case let (.index(position), .array(elements)):
            var elements = elements
            if rest.isEmpty {
                if let replacement {
                    if elements.indices.contains(position) { elements[position] = replacement }
                    else if position == elements.count { elements.append(replacement) }
                } else if elements.indices.contains(position) {
                    elements.remove(at: position)
                }
            } else if elements.indices.contains(position) {
                elements[position] = replacing(rest, in: elements[position], with: replacement)
            }
            return .array(elements)
        default:
            return value
        }
    }
}

/// A property list read from a descriptor, and written back in either format.
///
/// Both directions matter on a jailbroken device: a launchd job ships as binary
/// and is unreadable in a text editor, so the app converts it to XML to show
/// it; the same job has to go back as binary if that is how it arrived, because
/// `launchctl` reads either but the next tool along may not.
public struct PropertyListDocument: Sendable, Hashable {
    public enum Format: Sendable, Hashable {
        case binary
        case xml
        /// The old NeXT text format — what a `.strings` file is.
        /// `PropertyListSerialization` reads it and cannot write it, so saving
        /// one is an explicit choice of binary or XML by the caller.
        case openStep
    }

    /// The format the bytes arrived in, so a save can default to it rather
    /// than silently rewriting every plist on the device as XML.
    public var format: Format

    public var root: PropertyListValue

    /// The one reader in this module that allocates by file size, because
    /// `PropertyListSerialization` has no streaming parser and needs the whole
    /// document. Anything approaching this limit is not a property list — it is
    /// a database that someone named `.plist`, and the hex viewer is the honest
    /// answer for it.
    public static let maximumByteCount = PreviewLimits.textByteCount

    public init(descriptor: Int32, maximumByteCount: Int64 = PropertyListDocument.maximumByteCount) throws {
        let reader = try DescriptorReader(descriptor: descriptor)
        guard reader.byteCount <= maximumByteCount else {
            throw FormatFailure.tooLarge(byteCount: reader.byteCount, limit: maximumByteCount)
        }
        try self.init(data: reader.read(at: 0, count: Int(reader.byteCount)))
    }

    public init(data: Data) throws {
        var serializationFormat = PropertyListSerialization.PropertyListFormat.xml
        let object = try PropertyListBudget.parse(data, format: &serializationFormat)
        root = try PropertyListValue(propertyList: object)
        format = switch serializationFormat {
        case .binary: .binary
        case .openStep: .openStep
        default: .xml
        }
    }

    public init(root: PropertyListValue, format: Format = .xml) {
        self.root = root
        self.format = format
    }

    /// Bytes ready for an atomic replace. Note that this is where a `.strings`
    /// file stops being one: OpenStep cannot be written, so the caller has to
    /// pick, and the pick changes the file's shape.
    public func serialized(as format: Format) throws -> Data {
        guard format != .openStep else {
            throw FormatFailure.unsupported("OpenStep property lists can be read but not written")
        }
        let serializationFormat: PropertyListSerialization.PropertyListFormat = format == .binary ? .binary : .xml
        do {
            return try PropertyListBudget.serialize(root.propertyListObject, format: serializationFormat)
        } catch let failure as FormatFailure {
            throw failure
        } catch {
            throw FormatFailure.damaged("these changes could not be written")
        }
    }

    /// Back in the format it came in, which is what a save button does.
    public func serialized() throws -> Data {
        try serialized(as: format)
    }
}
