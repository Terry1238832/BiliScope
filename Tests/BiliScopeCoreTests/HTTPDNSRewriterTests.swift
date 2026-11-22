import XCTest
@testable import BiliScopeCore

final class HTTPDNSRewriterTests: XCTestCase {
    let policy = HostPolicy()
    func isMedia(_ host: String) -> Bool { policy.route(for: host) == .accelerate }

    func testSingleAnswerForMediaHostIsRewritten() throws {
        let body = Data(#"{"host":"upos-sz-mirrorcosov.bilivideo.com","ips":["43.175.144.148"],"ipsv6":["2408::1"],"ttl":60}"#.utf8)
        let result = try XCTUnwrap(HTTPDNSRewriter.rewrite(body, answer: "198.18.200.1", isMedia: isMedia))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: result.body) as? [String: Any])
        XCTAssertEqual(json["ips"] as? [String], ["198.18.200.1"])
        XCTAssertEqual(json["ipsv6"] as? [String], [])
        XCTAssertEqual(json["ttl"] as? Int, 60)
        XCTAssertEqual(result.hosts, ["upos-sz-mirrorcosov.bilivideo.com"])
    }

    func testBatchRewritesOnlyMediaHosts() throws {
        let body = Data(#"{"dns":[{"host":"upos-hz-mirrorakam.akamaized.net","ips":["72.136.195.97"],"type":1},{"host":"a.w.bilicdn1.com","ips":["1.2.3.4"],"type":1},{"host":"example.com","ips":["5.6.7.8"],"type":1}]}"#.utf8)
        let result = try XCTUnwrap(HTTPDNSRewriter.rewrite(body, answer: "198.18.200.1", isMedia: isMedia))
        let dns = try XCTUnwrap((JSONSerialization.jsonObject(with: result.body) as? [String: Any])?["dns"] as? [[String: Any]])
        XCTAssertEqual(dns[0]["ips"] as? [String], ["198.18.200.1"])
        XCTAssertEqual(dns[1]["ips"] as? [String], ["1.2.3.4"])
        XCTAssertEqual(dns[2]["ips"] as? [String], ["5.6.7.8"])
        XCTAssertEqual(result.hosts, ["upos-hz-mirrorakam.akamaized.net"])
    }

    func testNonMediaOnlyAnswerIsLeftAsIs() throws {
        let body = Data(#"{"host":"example.com","ips":["5.6.7.8"]}"#.utf8)
        let result = try XCTUnwrap(HTTPDNSRewriter.rewrite(body, answer: "198.18.200.1", isMedia: isMedia))
        XCTAssertEqual(result.body, body)
        XCTAssertTrue(result.hosts.isEmpty)
    }

    func testNonJSONIsNotRewritten() {
        XCTAssertNil(HTTPDNSRewriter.rewrite(Data("encrypted\u{1}".utf8), answer: "198.18.200.1", isMedia: isMedia))
    }
}
