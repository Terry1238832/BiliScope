import Foundation

/// A half-open byte range `[start, end)`, the way HTTP content is usually sliced
/// internally. The wire format is inclusive, so conversion happens at the edges.
public struct ByteSpan: Equatable, Sendable {
    public var start: Int64
    public var end: Int64

    public init(start: Int64, end: Int64) {
        self.start = start
        self.end = end
    }

    public var length: Int64 { max(0, end - start) }

    /// `bytes=start-end` (inclusive), as sent in a Range header.
    public var headerValue: String {
        end == .max ? "bytes=\(start)-" : "bytes=\(start)-\(end - 1)"
    }
}

public enum RangeHeader {
    /// Parses a single-range `Range` header. Multi-range requests return `nil`
    /// and are passed through untouched.
    public static func parse(_ raw: String?) -> ByteSpan? {
        guard let raw, raw.lowercased().hasPrefix("bytes=") else { return nil }
        let spec = raw.dropFirst("bytes=".count).trimmingCharacters(in: .whitespaces)
        guard !spec.contains(",") else { return nil }
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }

        let startText = String(parts[0]).trimmingCharacters(in: .whitespaces)
        let endText = String(parts[1]).trimmingCharacters(in: .whitespaces)
        guard let start = Int64(startText), start >= 0 else { return nil }
        if endText.isEmpty {
            return ByteSpan(start: start, end: Int64.max)
        }
        guard let end = Int64(endText), end >= start else { return nil }
        return ByteSpan(start: start, end: end + 1)
    }

    /// Parses `Content-Range: bytes start-end/total`.
    public static func parseContentRange(_ raw: String?) -> (span: ByteSpan, total: Int64?)? {
        guard let raw, raw.lowercased().hasPrefix("bytes ") else { return nil }
        let body = raw.dropFirst("bytes ".count)
        let parts = body.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let rangePart = parts[0].split(separator: "-", maxSplits: 1)
        guard rangePart.count == 2,
              let start = Int64(rangePart[0]),
              let end = Int64(rangePart[1]) else { return nil }
        let total = Int64(String(parts[1]).trimmingCharacters(in: .whitespaces))
        return (ByteSpan(start: start, end: end + 1), total)
    }
}

/// Splits a byte span into fixed-size chunks that can be fetched over several
/// connections. Chunks are returned in ascending order; the caller decides how
/// many are in flight at once.
public struct RangePlanner: Sendable {
    public var chunkSize: Int64
    public var maxConcurrency: Int

    public init(chunkSize: Int64 = 2 << 20, maxConcurrency: Int = 8) {
        self.chunkSize = max(1024, chunkSize)
        self.maxConcurrency = max(1, min(maxConcurrency, 32))
    }

    public func chunks(for span: ByteSpan) -> [ByteSpan] {
        guard span.length > 0 else { return [] }
        var result: [ByteSpan] = []
        result.reserveCapacity(Int((span.length + chunkSize - 1) / chunkSize))
        var cursor = span.start
        while cursor < span.end {
            let end = min(cursor + chunkSize, span.end)
            result.append(ByteSpan(start: cursor, end: end))
            cursor = end
        }
        return result
    }
}
