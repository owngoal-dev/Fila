import Foundation

/// One screenful of a file at a time, over a descriptor.
///
/// The hex viewer is the floor under every other viewer — the thing that opens
/// when nothing else recognised the file — so it has to open a 4 GB disk image
/// as fast as it opens a 40-byte one. Nothing here ever reads more than the
/// rows about to be drawn: the view sizes itself from `rowCount`, asks for the
/// range it is scrolling through, and forgets it again.
public struct HexWindow: Sendable {
    /// A user-facing byte offset is decimal or explicitly hexadecimal; it can
    /// never address before the beginning of the descriptor.
    public static func parseOffset(_ text: String) -> Int64? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let offset = text.hasPrefix("0x") ? Int64(text.dropFirst(2), radix: 16) : Int64(text)
        guard let offset, offset >= 0 else { return nil }
        return offset
    }

    /// What a hex dump has been sixteen bytes wide since `hexdump(1)`, and what
    /// fits an iPhone in landscape. Callers may use another width; this is the
    /// default the row arithmetic assumes.
    public static let bytesPerRow = 16

    private let reader: DescriptorReader

    public var byteCount: Int64 { reader.byteCount }

    public init(descriptor: Int32) throws {
        reader = try DescriptorReader(descriptor: descriptor)
    }

    /// How many rows the file has. An empty file has none, and a file whose
    /// last row is short still counts as a row.
    public func rowCount(bytesPerRow: Int = HexWindow.bytesPerRow) -> Int64 {
        guard bytesPerRow > 0 else { return 0 }
        return (byteCount + Int64(bytesPerRow) - 1) / Int64(bytesPerRow)
    }

    /// The bytes at `offset`, at most `count` of them, clamped to the file.
    ///
    /// Comes back short at the end and empty past it. Neither is an error: a
    /// file can be truncated while someone is looking at it, and the viewer's
    /// job then is to draw fewer bytes, not to put up an alert.
    public func read(at offset: Int64, count: Int) throws -> Data {
        guard offset >= 0, offset < byteCount, count > 0 else { return Data() }
        return try reader.readUpTo(at: offset, count: Int(min(Int64(count), byteCount - offset)))
    }

    /// The bytes behind a range of rows, for a view that knows which rows it is
    /// about to draw and not which byte offsets those are.
    public func rows(_ range: Range<Int64>, bytesPerRow: Int = HexWindow.bytesPerRow) throws -> Data {
        guard bytesPerRow > 0, !range.isEmpty else { return Data() }
        let start = range.lowerBound * Int64(bytesPerRow)
        let length = (range.upperBound - range.lowerBound) * Int64(bytesPerRow)
        return try read(at: start, count: Int(min(length, byteCount)))
    }
}
