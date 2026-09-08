import Foundation

/// A property list as something Swift can edit.
///
/// `PropertyListSerialization` hands back `Any` — `NSDictionary`, `NSNumber`,
/// and a `Bool` that is an `NSNumber` wearing a different `CFTypeID`. Editing
/// that tree in place means casting at every node and guessing at every leaf
/// whether a `1` is a number or a `true`, and guessing wrong writes a launchd
/// job that launchd then ignores. So it is converted once, on the way in, and
/// converted back once, on the way out.
///
/// A dictionary keeps its pairs in an array rather than a `[String: …]` because
/// the editor shows them in a stable order and a Swift dictionary has none.
indirect enum PropertyListValue {
    case dictionary([(key: String, value: PropertyListValue)])
    case array([PropertyListValue])
    case string(String)
    case integer(Int64)
    case real(Double)
    case boolean(Bool)
    case date(Date)
    case data(Data)
    case readOnly(String)

    var supportsEditing: Bool {
        switch self {
        case let .dictionary(pairs): pairs.allSatisfy(\.value.supportsEditing)
        case let .array(items): items.allSatisfy(\.supportsEditing)
        case .readOnly: false
        default: true
        }
    }

    var isContainer: Bool {
        switch self {
        case .dictionary, .array: true
        default: false
        }
    }

    var childCount: Int {
        switch self {
        case let .dictionary(pairs): pairs.count
        case let .array(items): items.count
        default: 0
        }
    }

    /// What the row shows to the right of the key.
    var summary: String {
        switch self {
        case let .dictionary(pairs):
            String(format: String(localized: "%lld items"), Int64(pairs.count))
        case let .array(items):
            String(format: String(localized: "%lld items"), Int64(items.count))
        case let .string(text):
            text
        case let .integer(number):
            String(number)
        case let .real(number):
            String(number)
        case let .boolean(flag):
            flag ? "true" : "false"
        case let .date(date):
            ISO8601DateFormatter().string(from: date)
        case let .data(bytes):
            ByteCountFormatter.string(fromByteCount: Int64(bytes.count), countStyle: .binary)
        case let .readOnly(summary):
            summary
        }
    }

    var typeName: String {
        switch self {
        case .dictionary: String(localized: "Dictionary")
        case .array: String(localized: "Array")
        case .string: String(localized: "String")
        case .integer: String(localized: "Number")
        case .real: String(localized: "Number")
        case .boolean: String(localized: "Boolean")
        case .date: String(localized: "Date")
        case .data: String(localized: "Data")
        case .readOnly: String(localized: "Read-Only Value")
        }
    }

    /// The value a leaf edit starts from, and the only thing a text field can
    /// round-trip. Containers and data have no text form and are not edited this
    /// way.
    var editableText: String? {
        switch self {
        case .string, .integer, .real: summary
        default: nil
        }
    }
}

/// Where a node lives. `.key` into a dictionary, `.index` into an array; the two
/// cannot be interchanged and keeping them as separate cases is what stops an
/// array index being applied to a dictionary at three in the morning.
enum PropertyListStep: Hashable {
    case key(String)
    case index(Int)
}

extension PropertyListValue {
    /// Preserve the position of values the editor cannot round-trip. Binary
    /// plists can contain archive UIDs even when no objects are unarchived.
    init(_ object: Any) {
        switch object {
        // The `Bool` check has to come first and has to be this one:
        // `NSNumber(true)` casts to `Int64` perfectly happily, and a boolean
        // that saves back as the integer 1 is how an entitlement stops working.
        case let value as NSNumber where CFGetTypeID(value) == CFBooleanGetTypeID():
            self = .boolean(value.boolValue)
        case let value as NSNumber:
            if CFNumberIsFloatType(value) {
                self = .real(value.doubleValue)
            } else {
                let number = value.int64Value
                self = NSNumber(value: number) == value ? .integer(number) : .readOnly(value.stringValue)
            }
        case let value as String:
            self = .string(value)
        case let value as Date:
            self = .date(value)
        case let value as Data:
            self = .data(value)
        case let value as [Any]:
            self = .array(value.map(PropertyListValue.init))
        case let value as [String: Any]:
            self = .dictionary(
                value.sorted { $0.key < $1.key }.map { (key: $0.key, value: PropertyListValue($0.value)) }
            )
        default:
            self = .readOnly(Self.readOnlySummary(object))
        }
    }

    /// Foundation's public XML output represents a UID as CF$UID plus an
    /// integer. Read that display value only; never instantiate archived objects
    /// or turn this presentation form into a writable replacement value.
    private static func readOnlySummary(_ object: Any) -> String {
        guard let data = try? PropertyListSerialization
            .data(fromPropertyList: ["value": object], format: .xml, options: 0),
            let xml = String(data: data, encoding: .utf8),
            let key = xml.range(of: "<key>CF$UID</key>"),
            let start = xml.range(of: "<integer>", range: key.upperBound ..< xml.endIndex),
            let end = xml.range(of: "</integer>", range: start.upperBound ..< xml.endIndex),
            let number = UInt64(xml[start.upperBound ..< end.lowerBound])
        else {
            return String(localized: "Unsupported Value")
        }
        return "UID \(number)"
    }

    var foundationObject: Any {
        get throws {
            switch self {
            case let .dictionary(pairs):
                var result: [String: Any] = [:]
                for pair in pairs {
                    result[pair.key] = try pair.value.foundationObject
                }
                return result
            case let .array(items):
                return try items.map { try $0.foundationObject }
            case let .string(text): return text
            case let .integer(number): return NSNumber(value: number)
            case let .real(number): return NSNumber(value: number)
            case let .boolean(flag): return NSNumber(value: flag)
            case let .date(date): return date
            case let .data(bytes): return bytes
            case .readOnly: throw CocoaError(.propertyListWriteInvalid)
            }
        }
    }

    subscript(step: PropertyListStep) -> PropertyListValue? {
        switch (self, step) {
        case let (.dictionary(pairs), .key(name)):
            pairs.first { $0.key == name }?.value
        case let (.array(items), .index(index)):
            items.indices.contains(index) ? items[index] : nil
        default:
            nil
        }
    }

    func value(at path: [PropertyListStep]) -> PropertyListValue? {
        path.reduce(self as PropertyListValue?) { $0?[$1] }
    }

    /// Replace what is at `path`, or remove it when `replacement` is nil.
    ///
    /// Recursive rather than iterative because an enum with associated values
    /// has no in-place mutation through a path; the copy is the price of the
    /// tree being a value, and a property list is small enough for that to cost
    /// nothing that matters.
    func replacing(_ path: [PropertyListStep], with replacement: PropertyListValue?) -> PropertyListValue {
        guard let step = path.first else { return replacement ?? self }
        let rest = Array(path.dropFirst())

        switch (self, step) {
        case (.dictionary(var pairs), let .key(name)):
            guard let position = pairs.firstIndex(where: { $0.key == name }) else { return self }
            if rest.isEmpty {
                if let replacement {
                    pairs[position].value = replacement
                } else {
                    pairs.remove(at: position)
                }
            } else {
                pairs[position].value = pairs[position].value.replacing(rest, with: replacement)
            }
            return .dictionary(pairs)

        case (.array(var items), let .index(index)):
            guard items.indices.contains(index) else { return self }
            if rest.isEmpty {
                if let replacement {
                    items[index] = replacement
                } else {
                    items.remove(at: index)
                }
            } else {
                items[index] = items[index].replacing(rest, with: replacement)
            }
            return .array(items)

        default:
            return self
        }
    }

    /// Rename a dictionary key, keeping the value. A remove-then-insert would
    /// also move the row, and losing your place after a typo fix is the kind of
    /// small thing that makes an editor annoying to use.
    func renaming(_ path: [PropertyListStep], to newKey: String) -> PropertyListValue {
        guard let step = path.first else { return self }
        let rest = Array(path.dropFirst())

        switch (self, step) {
        case (.dictionary(var pairs), let .key(name)):
            guard let position = pairs.firstIndex(where: { $0.key == name }) else { return self }
            if rest.isEmpty {
                guard !pairs.contains(where: { $0.key == newKey }) else { return self }
                pairs[position].key = newKey
                pairs.sort { $0.key < $1.key }
            } else {
                pairs[position].value = pairs[position].value.renaming(rest, to: newKey)
            }
            return .dictionary(pairs)

        case (.array(var items), let .index(index)):
            guard items.indices.contains(index), !rest.isEmpty else { return self }
            items[index] = items[index].renaming(rest, to: newKey)
            return .array(items)

        default:
            return self
        }
    }

    /// Append into the container at `path`. The key is ignored for an array and
    /// required for a dictionary.
    func inserting(_ child: PropertyListValue, key: String, into path: [PropertyListStep]) -> PropertyListValue {
        guard let step = path.first else {
            switch self {
            case var .dictionary(pairs):
                guard !pairs.contains(where: { $0.key == key }) else { return self }
                pairs.append((key: key, value: child))
                pairs.sort { $0.key < $1.key }
                return .dictionary(pairs)
            case var .array(items):
                items.append(child)
                return .array(items)
            default:
                return self
            }
        }
        let rest = Array(path.dropFirst())

        switch (self, step) {
        case (.dictionary(var pairs), let .key(name)):
            guard let position = pairs.firstIndex(where: { $0.key == name }) else { return self }
            pairs[position].value = pairs[position].value.inserting(child, key: key, into: rest)
            return .dictionary(pairs)
        case (.array(var items), let .index(index)):
            guard items.indices.contains(index) else { return self }
            items[index] = items[index].inserting(child, key: key, into: rest)
            return .array(items)
        default:
            return self
        }
    }
}
