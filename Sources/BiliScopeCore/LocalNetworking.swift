import Foundation
import Darwin

/// IPv4 addresses of this machine, used to decide whether a plain-HTTP request
/// is aimed at one of our own local servers.
public enum LocalAddresses {
    public static func ipv4() -> [String] {
        var result: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return result }
        defer { freeifaddrs(ifaddr) }

        var pointer = first
        while true {
            let interface = pointer.pointee
            if let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, socklen_t(address.pointee.sa_len),
                               &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    result.append(String(cString: host))
                }
            }
            guard let next = interface.ifa_next else { break }
            pointer = next
        }
        return result
    }

    public static func isLocal(_ host: String) -> Bool {
        if host == "localhost" || host == "127.0.0.1" || host == "::1" { return true }
        return ipv4().contains(host)
    }
}

/// Optional client allow-list for the LAN mode. Empty means "no restriction",
/// which is only safe for the default loopback binding.
public struct ClientAllowlist: Sendable {
    private let entries: [String]

    public init(_ entries: [String] = []) {
        self.entries = entries
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    public var isEmpty: Bool { entries.isEmpty }

    public func allows(_ remote: String?) -> Bool {
        guard !entries.isEmpty else { return true }
        guard var ip = remote else { return false }
        if ip.hasPrefix("::ffff:") { ip.removeFirst(7) }
        return entries.contains { entry in
            if ip == entry { return true }
            let prefix = entry.hasSuffix(".") ? entry : entry + "."
            return ip.hasPrefix(prefix)
        }
    }

    /// `127.0.0.1`, `10.*`, `192.168.*`, and `172.16.*` … `172.31.*`.
    public static var privateNetworks: ClientAllowlist {
        var entries = ["127.", "10.", "192.168."]
        for second in 16...31 { entries.append("172.\(second).") }
        return ClientAllowlist(entries)
    }
}
