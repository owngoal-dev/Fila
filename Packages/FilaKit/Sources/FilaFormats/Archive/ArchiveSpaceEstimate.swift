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

    private static let warningNumerator: Int64 = 9
    private static let warningDenominator: Int64 = 10

    /// The same ratio `needsWarning` applies, for the message that reports it.
    /// The warning text must not spell the percentage itself: `%` is not the
    /// percent sign in every locale, and its placement varies.
    public static let warningFraction = Double(warningNumerator) / Double(warningDenominator)

    public func needsWarning(availableByteCount: Int64) -> Bool {
        let available = max(0, availableByteCount)
        // floor(available * warningFraction), without overflow or
        // floating-point rounding.
        let whole = available / Self.warningDenominator * Self.warningNumerator
        let remainder = available % Self.warningDenominator * Self.warningNumerator / Self.warningDenominator
        return byteCount > whole + remainder
    }
}
