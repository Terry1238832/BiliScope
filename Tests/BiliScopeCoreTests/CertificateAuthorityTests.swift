import XCTest
import Security
@testable import BiliScopeCore

final class CertificateAuthorityTests: XCTestCase {
    var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("biliscope-ca-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRootCertificateIsValidX509() throws {
        let ca = try CertificateAuthority(directory: directory)
        let der = ca.rootCertificateDER
        XCTAssertGreaterThan(der.count, 200)
        let secCert = SecCertificateCreateWithData(nil, der as CFData)
        XCTAssertNotNil(secCert)
        let summary = SecCertificateCopySubjectSummary(secCert!) as String?
        XCTAssertEqual(summary, "BiliScope Root CA")
    }

    func testHostCertificateIsMintedAndCachedKeyIsReused() throws {
        let ca = try CertificateAuthority(directory: directory)
        let identity = try ca.identity(for: "upos-sz-mirrorcos.bilivideo.com")
        XCTAssertTrue(identity.certificatePEM.contains("BEGIN CERTIFICATE"))
        XCTAssertTrue(identity.privateKeyPEM.contains("BEGIN PRIVATE KEY"))

        let leafDER = try XCTUnwrap(Data(base64Encoded:
            identity.certificatePEM
                .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
                .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
                .components(separatedBy: .whitespacesAndNewlines).joined()
        ))
        let secCert = SecCertificateCreateWithData(nil, leafDER as CFData)
        XCTAssertNotNil(secCert)
    }

    func testAuthoritySurvivesRestart() throws {
        let first = try CertificateAuthority(directory: directory)
        let fingerprint = first.rootFingerprintSHA256
        let second = try CertificateAuthority(directory: directory)
        XCTAssertEqual(second.rootFingerprintSHA256, fingerprint)
    }

    func testMobileConfigurationIsAValidPlist() throws {
        let ca = try CertificateAuthority(directory: directory)
        let data = ca.mobileConfiguration()
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        XCTAssertEqual(plist?["PayloadType"] as? String, "Configuration")
        let content = try XCTUnwrap(plist?["PayloadContent"] as? [[String: Any]])
        XCTAssertEqual(content.first?["PayloadType"] as? String, "com.apple.security.root")
    }
}
