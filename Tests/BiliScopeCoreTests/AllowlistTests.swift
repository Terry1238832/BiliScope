import XCTest
@testable import BiliScopeCore

final class ClientAllowlistTests: XCTestCase {
    func testEmptyAllowlistAllowsEverything() {
        XCTAssertTrue(ClientAllowlist().allows("8.8.8.8"))
        XCTAssertTrue(ClientAllowlist().allows(nil))
    }

    func testPrivateNetworks() {
        let list = ClientAllowlist.privateNetworks
        XCTAssertTrue(list.allows("127.0.0.1"))
        XCTAssertTrue(list.allows("192.168.1.23"))
        XCTAssertTrue(list.allows("10.0.0.9"))
        XCTAssertTrue(list.allows("172.20.3.4"))
        XCTAssertFalse(list.allows("172.32.3.4"))
        XCTAssertFalse(list.allows("8.8.8.8"))
    }

    func testExactEntry() {
        let list = ClientAllowlist(["192.168.1.5"])
        XCTAssertTrue(list.allows("192.168.1.5"))
        XCTAssertFalse(list.allows("192.168.1.50"))
        XCTAssertFalse(list.allows("192.168.1.6"))
    }

    func testIPv4MappedRemote() {
        let list = ClientAllowlist(["10."])
        XCTAssertTrue(list.allows("::ffff:10.1.2.3"))
    }

    func testLoopbackIsLocal() {
        XCTAssertTrue(LocalAddresses.isLocal("127.0.0.1"))
        XCTAssertTrue(LocalAddresses.isLocal("localhost"))
    }
}
