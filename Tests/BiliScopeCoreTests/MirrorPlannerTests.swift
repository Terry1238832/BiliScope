import XCTest
@testable import BiliScopeCore

final class MirrorPlannerTests: XCTestCase {
    func testCandidatesIncludeOriginalAndOverseasMirrors() {
        let candidates = MirrorPlanner.candidates(for: "upos-sz-mirrorcos.bilivideo.com")
        XCTAssertEqual(candidates.first, "upos-sz-mirrorcos.bilivideo.com")
        XCTAssertTrue(candidates.contains("upos-sz-mirrorcosov.bilivideo.com"))
        XCTAssertTrue(candidates.contains("upos-sz-mirrorali.bilivideo.com"))
        XCTAssertEqual(Set(candidates).count, candidates.count)
        XCTAssertTrue(candidates.allSatisfy { $0.hasSuffix(".bilivideo.com") })
    }

    func testFamilyIsSharedAcrossMirrors() {
        XCTAssertEqual(MirrorPlanner.family(for: "upos-sz-mirrorcosov.bilivideo.com"), "bilibili-media-pool")
        XCTAssertEqual(MirrorPlanner.family(for: "upos-sz-mirrorcos.bilivideo.com"), "bilibili-media-pool")
        XCTAssertEqual(MirrorPlanner.family(for: "upos-hz-mirrorakam.akamaized.net"), "bilibili-media-pool")
    }

    func testAkamaiMirrorRacesAgainstBilibiliMirrors() {
        let candidates = MirrorPlanner.candidates(for: "upos-hz-mirrorakam.akamaized.net")
        XCTAssertEqual(candidates.first, "upos-hz-mirrorakam.akamaized.net")
        XCTAssertTrue(candidates.contains("upos-sz-mirrorcosov.bilivideo.com"))
        XCTAssertTrue(candidates.contains("upos-sz-mirrorcos.bilivideo.com"))
    }

    func testPlainAkamaiHostIsNotAMirror() {
        XCTAssertFalse(MirrorPlanner.isMirrorHost("foo.akamaized.net"))
        XCTAssertEqual(MirrorPlanner.candidates(for: "foo.akamaized.net"), ["foo.akamaized.net"])
    }

    func testUnknownHostsStaySingle() {
        XCTAssertEqual(MirrorPlanner.candidates(for: "i0.hdslb.com"), ["i0.hdslb.com"])
        XCTAssertEqual(MirrorPlanner.candidates(for: "cn-hbxy-cu-01-11.bilivideo.com"),
                       ["cn-hbxy-cu-01-11.bilivideo.com"])
        XCTAssertNil(MirrorPlanner.family(for: "example.com"))
    }
}
