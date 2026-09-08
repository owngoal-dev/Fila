@testable import FilaFormats
import Foundation
import Testing

@Suite("Hex windows")
struct HexWindowTests {
    @Test("Offset input accepts decimal and hex, and rejects negative or overflowing positions")
    func parsesOffsets() {
        #expect(HexWindow.parseOffset("0") == 0)
        #expect(HexWindow.parseOffset(" 32\n") == 32)
        #expect(HexWindow.parseOffset("0X7f") == 127)
        #expect(HexWindow.parseOffset(String(Int64.max)) == Int64.max)
        for text in ["-1", "-16", "0x-10", "", "0x", "1.5", "9223372036854775808", "0x8000000000000000"] {
            #expect(HexWindow.parseOffset(text) == nil)
        }
    }

    @Test("A window reads the bytes actually at the offset, including the short last row")
    func readsAWindow() throws {
        try withScratch { scratch in
            let url = scratch.appendingPathComponent("blob.bin")
            let payload = samplePayload(byteCount: 5000)
            try payload.write(to: url)

            try withDescriptor(reading: url) { descriptor in
                let window = try HexWindow(descriptor: descriptor)
                #expect(window.byteCount == 5000)
                #expect(window.rowCount() == 313)

                // Near the end, where an off-by-one in the clamp shows up.
                #expect(try window.read(at: 4980, count: 16) == payload[4980 ..< 4996])
                #expect(try window.read(at: 4990, count: 16) == payload[4990 ..< 5000])
                #expect(try window.read(at: 4096, count: 16) == payload[4096 ..< 4112])
                #expect(try window.rows(312 ..< 313) == payload[4992 ..< 5000])
            }
        }
    }

    @Test("Reading past the end is empty rather than an error, because files get truncated under a viewer")
    func readsPastTheEnd() throws {
        try withScratch { scratch in
            let url = scratch.appendingPathComponent("small.bin")
            try Data([1, 2, 3]).write(to: url)

            try withDescriptor(reading: url) { descriptor in
                let window = try HexWindow(descriptor: descriptor)
                #expect(window.rowCount() == 1)
                #expect(try window.read(at: 10, count: 16).isEmpty)
                #expect(try window.read(at: 1, count: 16) == Data([2, 3]))
            }
        }
    }
}
