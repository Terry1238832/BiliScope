import Foundation

/// Bilibili serves the same signed segment from several interchangeable mirror
/// hosts. From overseas, `…ov` mirrors can be many times faster than the
/// mainland ones, so we race the mirrors for the first bytes and then keep the
/// winner for the rest of the file.
public enum MirrorPlanner {
    /// Interchangeable mirrors for one signed path, listed as full host names
    /// because some (`estgoss`, `cn-hk-eq-…`) do not follow the
    /// `upos-<region>-mirror<token>` pattern. Overseas ones first, then mainland.
    /// Mostly from Bilibili-thread-ripper's lists; on 2026-11-22 every one
    /// answered 206 for fresh signed URLs, while `mirrorhwov` and `mirror08cov`
    /// never connected and were dropped.
    public static let pool = [
        "upos-sz-mirrorcosov.bilivideo.com",
        "upos-sz-mirroraliov.bilivideo.com",
        "cn-hk-eq-01-01.bilivideo.com",
        "cn-hk-eq-01-03.bilivideo.com",
        "upos-sz-mirrorcos.bilivideo.com",
        "upos-sz-mirrorcoso1.bilivideo.com",
        "upos-sz-mirrorali.bilivideo.com",
        "upos-sz-mirrorhw.bilivideo.com",
        "upos-sz-mirrorbos.bilivideo.com",
        "upos-sz-mirror08c.bilivideo.com",
        "upos-sz-mirrorbd.bilivideo.com",
        "upos-sz-mirror14b.bilivideo.com",
        "upos-sz-estgoss.bilivideo.com",
    ]

    public static func candidates(for host: String) -> [String] {
        let lower = host.lowercased()
        guard isMirrorHost(lower) else { return [host] }
        var seen = Set<String>()
        return ([lower] + pool).filter { seen.insert($0).inserted }
    }

    public static func isMirrorHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        if HostPolicy.isBilibiliAkamaiMirror(lower) || pool.contains(lower) { return true }
        return lower.hasSuffix(".bilivideo.com") && lower.contains("-mirror") && lower.hasPrefix("upos-")
    }

    /// Groups every mirror together under one key.
    public static func family(for host: String) -> String? {
        // Every Bilibili mirror serves identical bytes for the same signed
        // path, so one winner is reused across videos and CDNs.
        guard isMirrorHost(host) else { return nil }
        return "bilibili-media-pool"
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
