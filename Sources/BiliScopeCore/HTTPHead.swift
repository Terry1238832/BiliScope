import Foundation

/// Minimal HTTP/1.1 head parser. We only ever look at the first request of a
/// connection and then stream bytes, so this deliberately stays small.
public struct HTTPRequestHead: Sendable {
    public var method: String
    public var target: String
    public var version: String
    public var headers: [(name: String, value: String)]

    public func header(_ name: String) -> String? {
        let needle = name.lowercased()
        return headers.first { $0.name.lowercased() == needle }?.value
    }

    /// Absolute path + query for origin-form targets.
    public var path: String {
        if let url = URL(string: target), let scheme = url.scheme, scheme.hasPrefix("http") {
            var value = url.path.isEmpty ? "/" : url.path
            if let query = url.query { value += "?" + query }
            return value
        }
        return target
    }

    public var host: String? {
        if let url = URL(string: target), let host = url.host { return host }
        return header("Host")
    }
}

public struct HTTPResponseHead: Sendable {
    public var status: Int
    public var reason: String
    public var headers: [(name: String, value: String)]

    public func header(_ name: String) -> String? {
        let needle = name.lowercased()
        return headers.first { $0.name.lowercased() == needle }?.value
    }
}

public enum HTTPHeadParser {
    public static let maxHeadSize = 64 * 1024

    /// Returns `(head, headerEndIndex)` where `headerEndIndex` points just past
    /// the blank line, or `nil` when the buffer does not hold a complete head.
    public static func parseRequest(_ data: Data) -> (HTTPRequestHead, Int)? {
        guard let end = headEnd(in: data) else { return nil }
        guard let text = String(data: data[data.startIndex..<end], encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count >= 2 else { return nil }
        var headers: [(String, String)] = []
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers.append((name, value))
        }
        let head = HTTPRequestHead(
            method: String(requestLine[0]).uppercased(),
            target: String(requestLine[1]),
            version: requestLine.count > 2 ? String(requestLine[2]) : "HTTP/1.1",
            headers: headers
        )
        return (head, end)
    }

    public static func parseResponse(_ data: Data) -> (HTTPResponseHead, Int)? {
        guard let end = headEnd(in: data) else { return nil }
        guard let text = String(data: data[data.startIndex..<end], encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let statusLine = lines.removeFirst().split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard statusLine.count >= 2, let status = Int(statusLine[1]) else { return nil }
        var headers: [(String, String)] = []
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers.append((name, value))
        }
        let reason = statusLine.count > 2 ? String(statusLine[2]) : ""
        return (HTTPResponseHead(status: status, reason: reason, headers: headers), end)
    }

    public static func serialize(response: HTTPResponseHead, bodyLength: Int64?, keepAlive: Bool) -> Data {
        var text = "HTTP/1.1 \(response.status) \(response.reason.isEmpty ? "OK" : response.reason)\r\n"
        for header in response.headers {
            if bodyLength != nil, header.name.lowercased() == "content-length" { continue }
            text += "\(header.name): \(header.value)\r\n"
        }
        if let bodyLength { text += "Content-Length: \(bodyLength)\r\n" }
        text += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
        return Data(text.utf8)
    }

    private static func headEnd(in data: Data) -> Int? {
        // Scan only the first `maxHeadSize` bytes: a response head routinely
        // arrives in the same chunk as the first hundreds of KB of body, and
        // that must not make the head unparseable.
        let bytes = [UInt8](data.prefix(maxHeadSize + 4))
        var i = 0
        while i + 3 < bytes.count {
            if bytes[i] == 13, bytes[i + 1] == 10, bytes[i + 2] == 13, bytes[i + 3] == 10 {
                return i + 4
            }
            i += 1
        }
        return nil
    }
}
