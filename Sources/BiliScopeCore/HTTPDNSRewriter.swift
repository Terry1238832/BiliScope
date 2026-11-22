import Foundation

/// Rewrites Alibaba Cloud HTTPDNS answers so media hosts resolve to an address
/// inside the packet tunnel. The Bilibili player asks HTTPDNS for CDN addresses
/// and connects to them directly, skipping the system DNS the tunnel answers.
///
/// The schema is walked generically, so `/d?host=` (`{host, ips, ipsv6}`) and
/// `/resolve?host=a,b` (`{dns: [{host, ips, …}]}`) are both covered. Anything
/// that is not JSON comes back as `nil`, and the caller returns it unchanged.
public enum HTTPDNSRewriter {
    public static func rewrite(_ body: Data, answer: String,
                               isMedia: (String) -> Bool) -> (body: Data, hosts: [String])? {
        guard let json = try? JSONSerialization.jsonObject(with: body, options: [.mutableContainers]) else {
            return nil
        }
        var hosts: [String] = []
        let rewritten = visit(json, answer: answer, isMedia: isMedia, hosts: &hosts)
        guard !hosts.isEmpty, let data = try? JSONSerialization.data(withJSONObject: rewritten) else {
            return (body, [])
        }
        return (data, hosts)
    }

    private static func visit(_ node: Any, answer: String, isMedia: (String) -> Bool, hosts: inout [String]) -> Any {
        if var object = node as? [String: Any] {
            for (key, value) in object {
                object[key] = visit(value, answer: answer, isMedia: isMedia, hosts: &hosts)
            }
            if let host = object["host"] as? String, isMedia(host) {
                if object["ips"] != nil { object["ips"] = [answer] }
                // An IPv6 answer would let the player bypass the IPv4-only tunnel.
                if object["ipsv6"] != nil { object["ipsv6"] = [String]() }
                hosts.append(host)
            }
            return object
        }
        if let array = node as? [Any] {
            return array.map { visit($0, answer: answer, isMedia: isMedia, hosts: &hosts) }
        }
        return node
    }
}
