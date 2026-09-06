import Darwin
import Foundation

/// The addresses a Mac on the same network can reach this device at.
///
/// `getifaddrs(3)`, because there is no other answer: the device has no name
/// anything else would resolve, and asking a server on the internet what our
/// address is would be both wrong behind NAT and a request this app has no
/// business making. Loopback and cellular are dropped — one is unreachable from
/// the laptop, the other is where this server must never be answering.
///
/// IPv4 only. The address is printed for someone to type into Finder's *Connect
/// to Server*, and a link-local IPv6 address with a `%en0` scope on the end is
/// not something anybody types.
public enum RemoteAddress {
    public static func localAddresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var found: [String] = []
        for interface in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(interface.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let address = interface.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.pointee.ifa_name)
            // `pdp_ip*` is the cellular interface on iOS, `utun*` a VPN.
            guard !name.hasPrefix("pdp_ip"), !name.hasPrefix("utun") else { continue }

            var text = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                address, socklen_t(address.pointee.sa_len),
                &text, socklen_t(text.count),
                nil, 0, NI_NUMERICHOST
            ) == 0 else { continue }
            let value = String(cString: text)
            if !value.isEmpty, !found.contains(value) { found.append(value) }
        }
        return found
    }
}
