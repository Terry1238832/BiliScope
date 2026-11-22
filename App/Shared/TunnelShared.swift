import Foundation

/// What the app and its packet tunnel exchange. They share no container: the
/// app hands the CA over in the tunnel's configuration and asks for the log
/// through provider messages, so signing needs no App Group.
enum TunnelShared {
    /// Where the app keeps its CA; the tunnel receives a copy of these files.
    static var appCADirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BiliScope", isDirectory: true)
    }

    static let caFiles = ["ca-cert.pem", "ca-key.pem", "leaf-key.pem"]
    static let caKey = "ca"
    static let fullTunnelKey = "fullTunnel"
    static let logRequest = Data("log".utf8)
    /// Answered with "<requests> <bytes>" accelerated since the tunnel started.
    static let statsRequest = Data("stats".utf8)
    static let tunnelProxyPort: UInt16 = 8889

    /// The free-account build leaves the packet tunnel out entirely.
    static var hasTunnel: Bool {
        guard let plugins = Bundle.main.builtInPlugInsURL else { return false }
        return FileManager.default.fileExists(atPath: plugins.appendingPathComponent("BiliScopeTunnel.appex").path)
    }
}
