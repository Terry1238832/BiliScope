import Foundation
import HevSocks5Tunnel

/// Runs hev-socks5-tunnel (App/Vendor, built from source by
/// scripts/build-hev-xcframework.sh) on the packet tunnel's utun device.
enum HevTunnel {
    /// `_IOWR('N', 3, struct ctl_info)`, which Swift cannot import as a macro.
    private static let ctlIOCGInfo: UInt = 0xC064_4E03

    /// The utun socket NetworkExtension opened for this provider. iOS has no API
    /// for it, so find the open socket whose peer is the utun control, the same
    /// way WireGuard and Tun2SocksKit do.
    static var tunnelFileDescriptor: Int32? {
        var info = biliscope_ctl_info()
        withUnsafeMutableBytes(of: &info.ctl_name) { name in
            let control = Array("com.apple.net.utun_control".utf8)
            name.copyBytes(from: control.prefix(name.count - 1))
        }
        for descriptor: Int32 in 0...1024 {
            var address = biliscope_sockaddr_ctl()
            var length = socklen_t(MemoryLayout.size(ofValue: address))
            let result = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(descriptor, $0, &length) }
            }
            guard result == 0, address.sc_family == AF_SYSTEM else { continue }
            if info.ctl_id == 0, ioctl(descriptor, ctlIOCGInfo, &info) != 0 { continue }
            if address.sc_id == info.ctl_id { return descriptor }
        }
        return nil
    }

    /// Blocks until `quit()`, so it runs on its own thread.
    static func run(config: String, onExit: @escaping @Sendable (Int32) -> Void) {
        guard let descriptor = tunnelFileDescriptor else {
            onExit(-1)
            return
        }
        Thread.detachNewThread {
            let bytes = Array(config.utf8)
            let code = bytes.withUnsafeBufferPointer {
                hev_socks5_tunnel_main_from_str($0.baseAddress, UInt32($0.count), descriptor)
            }
            onExit(code)
        }
    }

    static func quit() {
        hev_socks5_tunnel_quit()
    }
}
