import Foundation

extension Data {
    init(from value: some Any) {
        var value = value
        self = Swift.withUnsafeBytes(of: &value) { Data($0) }
    }

    func to<T>(type _: T.Type) -> T {
        withUnsafeBytes { $0.load(as: T.self) }
    }
}

extension Data {
    init?(_ hex: String) {
        let len = hex.count / 2
        var data = Data(capacity: len)
        for i in 0 ..< len {
            let j = hex.index(hex.startIndex, offsetBy: i * 2)
            let k = hex.index(j, offsetBy: 2)
            let bytes = hex[j ..< k]
            if var num = UInt8(bytes, radix: 16) {
                data.append(&num, count: 1)
            } else {
                return nil
            }
        }
        self = data
    }

    var hex: String {
        reduce("") { $0 + String(format: "%02x", $1) }
    }
}
