import Foundation

/// Bilibili serves the same signed segment from several interchangeable mirror
/// hosts. From overseas, `…ov` mirrors can be many times faster than the
/// mainland ones, so we race the mirrors for the first bytes and then keep the
/// winner for the rest of the file.
public enum MirrorPlanner {
    /// Mirror tokens seen in Bilibili's `upos-<region>-mirror<token>` hostnames.
    public static let tokens = ["cosov", "aliov", "hwov", "08cov", "cos", "ali", "bos", "hw", "08c"]

    /// `upos-sz-mirror<token>.bilivideo.com` — the pool that resolves from most
    /// networks, including Bilibili's Akamai-served segments.
    public static let mainlandPool = tokens.map { "upos-sz-mirror\($0).bilivideo.com" }

    public static func candidates(for host: String) -> [String] {
        var result = [host]
        if let parts = split(host) {
            for token in tokens where token != parts.token {
                result.append("\(parts.prefix)\(token).bilivideo.com")
            }
        }
        if isMirrorHost(host) {
            result.append(contentsOf: mainlandPool)
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0).inserted }
    }

    public static func isMirrorHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        if HostPolicy.isBilibiliAkamaiMirror(lower) { return true }
        return lower.hasSuffix(".bilivideo.com") && lower.contains("-mirror") && lower.hasPrefix("upos-")
    }

    /// Groups every mirror of one region together, e.g. `upos-sz-mirror*.bilivideo.com`.
    public static func family(for host: String) -> String? {
        // Every Bilibili mirror serves identical bytes for the same signed
        // path, so one winner is reused across videos and CDNs.
        guard isMirrorHost(host) else { return nil }
        return "bilibili-media-pool"
    }

    private static func split(_ host: String) -> (prefix: String, token: String)? {
        let suffix = ".bilivideo.com"
        let lower = host.lowercased()
        guard lower.hasSuffix(suffix) else { return nil }
        let left = String(lower.dropLast(suffix.count))
        guard let range = left.range(of: "-mirror", options: .backwards) else { return nil }
        let token = String(left[range.upperBound...])
        guard !token.isEmpty, token.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        let prefix = String(left[..<range.upperBound])
        guard prefix.hasPrefix("upos-") else { return nil }
        return (prefix, token)
    }
}

/// Remembers which mirror won the last race, so repeat requests do not pay for
/// racing every time.
final class MirrorCache {
    static let shared = MirrorCache()

    private struct Entry {
        let host: String
        let date: Date
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let ttl: TimeInterval = 300

    func preferred(for family: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[family], Date().timeIntervalSince(entry.date) < ttl else {
            entries[family] = nil
            return nil
        }
        return entry.host
    }

    func remember(_ host: String, for family: String) {
        lock.lock()
        entries[family] = Entry(host: host, date: Date())
        lock.unlock()
    }
}
