import Foundation

/// App preview budgets, checked before constructing a renderer or reading its payload.
/// Streaming playback and archive browsing have a separate file-size ceiling.
public enum PreviewLimits {
    public static let fileByteCount: Int64 = 128 * 1024 * 1024
    public static let textByteCount: Int64 = 32 * 1024 * 1024
    public static let streamingFileByteCount: Int64 = 2 * 1024 * 1024 * 1024
    public static let imagePixelSize = 4096

    /// Line objects also consume memory: many tiny lines can outweigh their bytes.
    public static func textPrefixByteCount(_ data: Data) -> Int {
        var lines = 1
        var previous: UInt8 = 0
        for (offset, byte) in data.prefix(Int(textByteCount)).enumerated() {
            if byte == 13 || (byte == 10 && previous != 13) {
                if lines == 100_000 {
                    return offset
                }
                lines += 1
            }
            previous = byte
        }
        return min(data.count, Int(textByteCount))
    }

    public static func validate(byteCount: Int64, format: FileFormat) throws {
        guard byteCount >= 0 else { throw FormatFailure.system(errno: EINVAL) }
        let limit: Int64
        switch format {
        // These readers window their input; text has its own bounded head preview.
        case .audio, .video, .binary, .machO, .text: return
        case .archive: limit = streamingFileByteCount
        case .propertyList: limit = textByteCount
        default: limit = fileByteCount
        }
        guard byteCount <= limit else { throw FormatFailure.tooLarge(byteCount: byteCount, limit: limit) }
    }
}
