import XCTest
@testable import BiliScopeCore

final class HostPolicyTests: XCTestCase {
    let policy = HostPolicy()

    func testBilibiliHosts() {
        XCTAssertEqual(policy.route(for: "www.bilibili.com"), .blindTunnel)
        XCTAssertEqual(policy.route(for: "api.bilibili.com"), .blindTunnel)
        XCTAssertEqual(policy.route(for: "upos-sz-mirrorcos.bilivideo.com"), .accelerate)
        XCTAssertEqual(policy.route(for: "cn-hbxy-cu-01-11.bilivideo.com:443"), .accelerate)
        XCTAssertEqual(policy.route(for: "i0.hdslb.com"), .accelerate)
        XCTAssertEqual(policy.route(for: "BILIBILI.COM."), .blindTunnel)
    }

    func testForeignHostsAreNeverTouched() {
        XCTAssertEqual(policy.route(for: "example.com"), .passthrough)
        XCTAssertEqual(policy.route(for: "bilibili.com.evil.com"), .passthrough)
        XCTAssertEqual(policy.route(for: "notbilibili.com"), .passthrough)
        XCTAssertEqual(policy.route(for: "apple.com"), .passthrough)
        XCTAssertEqual(policy.route(for: "127.0.0.1"), .passthrough)
        XCTAssertEqual(policy.route(for: "::1"), .passthrough)
        XCTAssertEqual(policy.route(for: ""), .passthrough)
    }

    func testBilibiliAkamaiMirrorIsAccelerated() {
        XCTAssertEqual(policy.route(for: "upos-hz-mirrorakam.akamaized.net"), .accelerate)
        XCTAssertEqual(policy.route(for: "upos-sz-mirrorakam.akamaized.net"), .accelerate)
        XCTAssertEqual(policy.route(for: "foo.akamaized.net"), .passthrough)
        XCTAssertEqual(policy.route(for: "upos-evil.akamaized.net"), .passthrough)
    }

    func testNonMediaBilibiliHostsAreBlind() {
        XCTAssertEqual(policy.route(for: "i0.hdslb.com"), .accelerate)
        XCTAssertEqual(policy.route(for: "mall.bilibili.com"), .blindTunnel)
        XCTAssertEqual(policy.route(for: "passport.bilibili.com"), .blindTunnel)
    }

    func testPolicyCannotBeWidenedToForeignDomains() {
        let widened = HostPolicy(domains: HostPolicy.defaultDomains + ["apple.com"], mediaDomains: ["apple.com"])
        XCTAssertEqual(widened.route(for: "gateway.icloud.apple.com"), .passthrough)
    }
}

final class RangeTests: XCTestCase {
    func testParseRange() {
        XCTAssertEqual(RangeHeader.parse("bytes=0-"), ByteSpan(start: 0, end: .max))
        XCTAssertEqual(RangeHeader.parse("bytes=1024-2047"), ByteSpan(start: 1024, end: 2048))
        XCTAssertNil(RangeHeader.parse("bytes=0-1,4-5"))
        XCTAssertNil(RangeHeader.parse("items=0-1"))
        XCTAssertNil(RangeHeader.parse(nil))
    }

    func testParseContentRange() {
        let parsed = RangeHeader.parseContentRange("bytes 0-1023/900000")
        XCTAssertEqual(parsed?.span, ByteSpan(start: 0, end: 1024))
        XCTAssertEqual(parsed?.total, 900000)
    }

    func testChunksCoverSpanExactly() {
        let planner = RangePlanner(chunkSize: 1024, maxConcurrency: 8)
        let span = ByteSpan(start: 0, end: 10_240)
        let chunks = planner.chunks(for: span)
        XCTAssertEqual(chunks.count, 10)
        XCTAssertEqual(chunks.first?.start, 0)
        XCTAssertEqual(chunks.last?.end, 10_240)
        for (a, b) in zip(chunks, chunks.dropFirst()) {
            XCTAssertEqual(a.end, b.start)
        }
    }

    func testChunksWithRemainder() {
        let planner = RangePlanner(chunkSize: 1024, maxConcurrency: 4)
        let chunks = planner.chunks(for: ByteSpan(start: 500, end: 2500))
        XCTAssertEqual(chunks, [
            ByteSpan(start: 500, end: 1524),
            ByteSpan(start: 1524, end: 2500),
        ])
    }
}

final class HTTPHeadTests: XCTestCase {
    func testParseRequest() throws {
        let raw = "GET /video.m4s?range=0 HTTP/1.1\r\nHost: upos.bilivideo.com\r\nRange: bytes=0-\r\n\r\n"
        let parsed = try XCTUnwrap(HTTPHeadParser.parseRequest(Data(raw.utf8)))
        XCTAssertEqual(parsed.0.method, "GET")
        XCTAssertEqual(parsed.0.path, "/video.m4s?range=0")
        XCTAssertEqual(parsed.0.header("host"), "upos.bilivideo.com")
        XCTAssertEqual(parsed.1, raw.utf8.count)
    }

    func testIncompleteHeadReturnsNil() {
        XCTAssertNil(HTTPHeadParser.parseRequest(Data("GET / HTTP/1.1\r\nHost: x".utf8)))
    }
}
