import Foundation

/// Header sizes are an estimate, never a reservation of destination storage.
/// Unknown sizes are kept explicit so a raw compressed stream cannot look empty.
public struct ArchiveSpaceEstimate {
    public private(set) var byteCount: Int64 = 0
    public private(set) var hasUnknownSize = false

    public init(entries: [ArchiveEntry]) {
        for entry in entries where entry.kind == .regular && entry.hardLinkTarget == nil {
            guard let size = entry.byteCount, size >= 0 else {
                hasUnknownSize = true
                continue
            }
            let (sum, overflow) = byteCount.addingReportingOverflow(size)
            byteCount = overflow ? .max : sum
        }
    }

    public func needsWarning(availableByteCount: Int64) -> Bool {
        let available = max(0, availableByteCount)
        // floor(available * 0.9), without overflow or floating-point rounding.
        let threshold = available / 10 * 9 + available % 10 * 9 / 10
        return byteCount > threshold
    }
}
