import Foundation

/// What the proxy is allowed to do with a given host.
public enum HostRoute: Equatable, Sendable {
    /// Bilibili host we only relay: bytes are never decrypted, parsed or logged.
    case blindTunnel
    /// Bilibili media host we terminate TLS for, so Range requests can be accelerated.
    case accelerate
    /// Not a Bilibili host. Traffic never enters the tunnel in the first place.
    case passthrough
}

/// Decides, by host name only, whether we are allowed to touch a connection.
///
/// The rule is a hard allow-list: anything that is not exactly one of Bilibili's
/// registered domains (or one of their subdomains) is `passthrough`. There is no
/// "catch all" mode and no way to add a non-Bilibili domain at runtime.
public struct HostPolicy: Sendable {
    /// Domains owned by Bilibili. Keep this list short and explicit.
    public static let defaultDomains: [String] = [
        "bilibili.com",
        "bilibili.tv",
        "bilivideo.com",
        "bilivideo.cn",
        "hdslb.com",
        "biliapi.net",
        "biliapi.com",
        "bilicdn.com",
    ]

    /// Media/CDN hosts where we terminate TLS to rewrite Range downloads.
    public static let defaultMediaDomains: [String] = [
        "bilivideo.com",
        "bilivideo.cn",
        "hdslb.com",
        "bilicdn.com",
    ]

    public let domains: [String]
    public let mediaDomains: [String]

    public init(domains: [String] = HostPolicy.defaultDomains,
                mediaDomains: [String] = HostPolicy.defaultMediaDomains) {
        self.domains = domains.map(Self.normalize).filter { !$0.isEmpty }
        self.mediaDomains = mediaDomains.map(Self.normalize).filter { !$0.isEmpty }
    }

    /// Hosts we refuse to MITM even if configured, so a typo can never turn this
    /// into a general purpose interception proxy.
    private static let neverIntercept = ["apple.com", "icloud.com", "google.com", "qq.com", "weixin.qq.com"]

    public func route(for rawHost: String) -> HostRoute {
        let host = Self.normalize(rawHost)
        guard !host.isEmpty, !Self.isIPAddress(host) else { return .passthrough }
        if Self.isBilibiliAkamaiMirror(host) { return .accelerate }
        guard matches(host, in: domains) else { return .passthrough }
        guard !matches(host, in: Self.neverIntercept) else { return .passthrough }
        return matches(host, in: mediaDomains) ? .accelerate : .blindTunnel
    }

    /// Bilibili's Akamai mirror uses a Bilibili-specific hostname
    /// (`upos-<region>-mirrorakam.akamaized.net`). It is matched by shape, not by
    /// adding `akamaized.net` to the allow-list, so other Akamai traffic is
    /// never touched.
    static func isBilibiliAkamaiMirror(_ host: String) -> Bool {
        host.hasSuffix(".akamaized.net") && host.hasPrefix("upos-") && host.contains("-mirror")
    }

    public func isBilibili(_ rawHost: String) -> Bool {
        route(for: rawHost) != .passthrough
    }

    private func matches(_ host: String, in list: [String]) -> Bool {
        list.contains { domain in
            host == domain || host.hasSuffix("." + domain)
        }
    }

    /// Lowercase, strip a trailing dot and an optional `:port`.
    static func normalize(_ raw: String) -> String {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasPrefix("["), let end = host.firstIndex(of: "]") {
            host = String(host[host.index(after: host.startIndex)..<end])
        } else if let colon = host.lastIndex(of: ":"), host.filter({ $0 == ":" }).count == 1 {
            host = String(host[..<colon])
        }
        while host.hasSuffix(".") { host.removeLast() }
        return host
    }

    static func isIPAddress(_ host: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 { return true }
        var v6 = in6_addr()
        return inet_pton(AF_INET6, host, &v6) == 1
    }
}
