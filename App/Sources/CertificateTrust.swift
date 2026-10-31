import Foundation
import Security

/// Answers the only question that really matters to the user: is the local root
/// CA installed *and* trusted for SSL on this device?
enum CertificateTrust {
    static func isTrusted(_ der: Data) -> Bool {
        guard !der.isEmpty,
              let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            return false
        }
        let policy = SecPolicyCreateSSL(true, nil)
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates([certificate] as CFArray, policy, &trust) == errSecSuccess,
              let trust else {
            return false
        }
        var error: CFError?
        return SecTrustEvaluateWithError(trust, &error)
    }
}
