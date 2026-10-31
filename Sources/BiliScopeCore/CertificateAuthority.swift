import Foundation
import Crypto
import X509

/// A locally generated root CA plus a single leaf key.
///
/// One leaf key pair is reused for every host certificate so only a single
/// private key ever needs to be persisted. Certificates themselves are cheap to
/// mint and are cached in memory by the caller.
public final class CertificateAuthority {
    public struct Identity: Sendable {
        public let certificatePEM: String
        public let privateKeyPEM: String
    }

    public let directory: URL
    private let caKey: P256.Signing.PrivateKey
    private let caCertificate: Certificate
    private let leafKey: P256.Signing.PrivateKey

    private static let caKeyFile = "ca-key.pem"
    private static let caCertFile = "ca-cert.pem"
    private static let leafKeyFile = "leaf-key.pem"

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        if let key = Self.loadKey(directory.appendingPathComponent(Self.caKeyFile)),
           let cert = Self.loadCertificate(directory.appendingPathComponent(Self.caCertFile)) {
            self.caKey = key
            self.caCertificate = cert
        } else {
            let key = P256.Signing.PrivateKey()
            let cert = try Self.makeRootCA(key: key)
            try Self.persist(key.pemRepresentation, to: directory.appendingPathComponent(Self.caKeyFile))
            try Self.persist(cert.serializeAsPEM().pemString, to: directory.appendingPathComponent(Self.caCertFile))
            self.caKey = key
            self.caCertificate = cert
        }

        if let key = Self.loadKey(directory.appendingPathComponent(Self.leafKeyFile)) {
            self.leafKey = key
        } else {
            let key = P256.Signing.PrivateKey()
            try Self.persist(key.pemRepresentation, to: directory.appendingPathComponent(Self.leafKeyFile))
            self.leafKey = key
        }
    }

    public var rootCertificateDER: Data {
        Data((try? caCertificate.serializeAsPEM().derBytes) ?? [])
    }

    public var rootCertificatePEM: String {
        (try? caCertificate.serializeAsPEM().pemString) ?? ""
    }

    public var rootFingerprintSHA256: String {
        Data(SHA256.hash(data: rootCertificateDER)).hexString
    }

    /// Mints (or reuses) a server certificate for `host`, signed by the root CA.
    public func identity(for host: String) throws -> Identity {
        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: Certificate.PublicKey(leafKey.publicKey),
            notValidBefore: Date().addingTimeInterval(-3600),
            notValidAfter: Date().addingTimeInterval(90 * 24 * 3600),
            issuer: caCertificate.subject,
            subject: try DistinguishedName { CommonName(host) },
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                Critical(KeyUsage(digitalSignature: true, keyEncipherment: true))
                try ExtendedKeyUsage([.serverAuth])
                SubjectAlternativeNames([.dnsName(host)])
            },
            issuerPrivateKey: Certificate.PrivateKey(caKey)
        )
        return Identity(
            certificatePEM: try certificate.serializeAsPEM().pemString,
            privateKeyPEM: leafKey.pemRepresentation
        )
    }

    public func mobileConfiguration(displayName: String = "BiliScope Root CA") -> Data {
        Data(MobileConfig.make(rootDER: rootCertificateDER, displayName: displayName).utf8)
    }

    // MARK: - Root certificate

    private static func makeRootCA(key: P256.Signing.PrivateKey) throws -> Certificate {
        let name = try DistinguishedName {
            CommonName("BiliScope Root CA")
            OrganizationName("BiliScope")
        }
        let now = Date()
        return try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: Certificate.PublicKey(key.publicKey),
            notValidBefore: now.addingTimeInterval(-3600),
            notValidAfter: now.addingTimeInterval(5 * 365 * 24 * 3600),
            issuer: name,
            subject: name,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0))
                Critical(KeyUsage(digitalSignature: true, keyCertSign: true, cRLSign: true))
                try SubjectKeyIdentifier(hash: Certificate.PublicKey(key.publicKey))
            },
            issuerPrivateKey: Certificate.PrivateKey(key)
        )
    }

    // MARK: - Persistence

    private static func persist(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url, options: [.atomic, .completeFileProtection])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func loadKey(_ url: URL) -> P256.Signing.PrivateKey? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return try? P256.Signing.PrivateKey(pemRepresentation: text)
    }

    private static func loadCertificate(_ url: URL) -> Certificate? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return try? Certificate(pemEncoded: text)
    }
}

extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
