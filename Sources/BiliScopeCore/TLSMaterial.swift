import Foundation
import NIOCore
import NIOPosix
import NIOSSL

/// Caches one `NIOSSLContext` per host so we are not minting certificates for
/// every connection.
final class TLSMaterial {
    private let ca: CertificateAuthority
    private let cache = NSLock()
    private var contexts: [String: NIOSSLContext] = [:]

    init(ca: CertificateAuthority) {
        self.ca = ca
    }

    func context(for host: String) throws -> NIOSSLContext {
        cache.lock()
        if let existing = contexts[host] {
            cache.unlock()
            return existing
        }
        cache.unlock()

        let identity = try ca.identity(for: host)
        let certificate = try NIOSSLCertificate(bytes: Array(identity.certificatePEM.utf8), format: .pem)
        let privateKey = try NIOSSLPrivateKey(bytes: Array(identity.privateKeyPEM.utf8), format: .pem)
        var configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(certificate)],
            privateKey: .privateKey(privateKey)
        )
        configuration.applicationProtocols = ["http/1.1"]
        configuration.minimumTLSVersion = .tlsv12
        let context = try NIOSSLContext(configuration: configuration)

        cache.lock()
        contexts[host] = context
        cache.unlock()
        return context
    }
}
