import Foundation
import NetworkExtension
import BiliScopeCore

/// Takes over Bilibili media traffic without any other VPN app.
///
/// The tunnel answers DNS only for the media domains, with mapped addresses
/// inside its own range, so only connections to those hosts enter it; all other
/// traffic keeps its normal route. hev-socks5-tunnel turns those packets back
/// into TCP connections and hands them, with their host names, to the same
/// proxy the app used to run, over SOCKS5 on loopback. The provider's own
/// connections never enter its tunnel, so the proxy reaches the real CDNs.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private var proxy: MITMProxy?
    private let log = TunnelLog()
    private var memoryTimer: DispatchSourceTimer?
    private let stopping = StopFlag()

    static let proxyPort = TunnelShared.tunnelProxyPort
    private let stats = TunnelStats()
    private static let tunnelAddress = "198.18.0.1"
    private static let dnsAddress = "198.18.0.2"
    /// Mapped addresses handed out for media host names.
    private static let mappedNetwork = ("198.19.0.0", "255.255.0.0")
    /// Alibaba Cloud HTTPDNS. Measured on a device: the Bilibili player asks it
    /// for CDN addresses and connects to bare IPs, skipping system DNS, so the
    /// media never reached the tunnel. Refusing it stalled the player, so its
    /// answers for media hosts are rewritten to `httpDNSAnswer` instead.
    private static let httpDNSAnswer = "198.18.200.1"
    private static let httpDNSNetworks = [("203.119.0.0", "255.255.0.0"), ("203.107.0.0", "255.255.0.0")]

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let configuration = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration ?? [:]
        // Debug only: send every connection through the tunnel, to measure how
        // much media skips DNS by connecting to a bare IP.
        let fullTunnel = configuration[TunnelShared.fullTunnelKey] as? Bool ?? false

        do {
            try startProxy(ca: configuration[TunnelShared.caKey] as? [String: String] ?? [:],
                           logForeignHosts: fullTunnel)
        } catch {
            log.write("代理启动失败：\(error.localizedDescription)")
            completionHandler(error)
            return
        }

        let domains = HostPolicy.defaultMediaDomains + HostPolicy.defaultRelayDomains + HostPolicy.exactMediaHosts
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        let ipv4 = NEIPv4Settings(addresses: [Self.tunnelAddress], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = fullTunnel
            ? [NEIPv4Route.default()]
            : [NEIPv4Route(destinationAddress: "198.18.0.0", subnetMask: "255.254.0.0")]
                + Self.httpDNSNetworks.map { NEIPv4Route(destinationAddress: $0.0, subnetMask: $0.1) }
        settings.ipv4Settings = ipv4
        let dns = NEDNSSettings(servers: [Self.dnsAddress])
        dns.matchDomains = fullTunnel ? [""] : domains
        settings.dnsSettings = dns
        settings.mtu = 1500

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else { return }
            if let error {
                self.log.write("隧道设置失败：\(error.localizedDescription)")
                self.proxy?.stop()
                self.proxy = nil
                completionHandler(error)
                return
            }
            HevTunnel.run(config: Self.hevConfig()) { [weak self, log, stopping] code in
                // A normal stop ends hev too; only an unexpected exit is an error.
                guard !stopping.isSet else { return }
                log.write("hev-socks5-tunnel 退出，代码 \(code)")
                // Routes would keep capturing Bilibili traffic with nothing to
                // carry it, which is a dead network: end the tunnel instead.
                self?.cancelTunnelWithError(NSError(domain: "BiliScope", code: Int(code),
                                                    userInfo: [NSLocalizedDescriptionKey: "隧道组件退出（\(code)）"]))
            }
            self.log.write("隧道已启动（\(fullTunnel ? "全量排查模式" : "只接管 \(domains.count) 个媒体域名")）")
            self.startMemoryLog()
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        stopping.set()
        HevTunnel.quit()
        memoryTimer?.cancel()
        memoryTimer = nil
        proxy?.stop()
        proxy = nil
        log.write("隧道已停止（原因 \(reason.rawValue)）")
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        switch messageData {
        case TunnelShared.logRequest: completionHandler?(log.snapshot())
        case TunnelShared.statsRequest: completionHandler?(stats.snapshot())
        default: completionHandler?(nil)
        }
    }

    /// Uses the CA the app sent: the user trusted that one, so never make another.
    private func startProxy(ca files: [String: String], logForeignHosts: Bool) throws {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BiliScopeTunnel", isDirectory: true)
        guard TunnelShared.caFiles.allSatisfy({ files[$0] != nil }) else {
            throw NSError(domain: "BiliScope", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "没有收到根证书，请在哔哩加速 App 里重新打开加速"])
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in TunnelShared.caFiles {
            try Data(files[name]!.utf8).write(to: directory.appendingPathComponent(name), options: .atomic)
        }
        let ca = try CertificateAuthority(directory: directory)
        let proxy = MITMProxy(ca: ca, config: .init(bindHost: "127.0.0.1",
                                                    port: Self.proxyPort,
                                                    concurrency: 10,
                                                    chunkSize: 1 << 20,
                                                    logForeignHosts: logForeignHosts,
                                                    maxSessions: 2,
                                                    httpDNSPrefixes: ["203.119.", "203.107."],
                                                    httpDNSAnswer: Self.httpDNSAnswer,
                                                    log: log.write,
                                                    onEvent: { [stats] event in
                                                        if case .accelerated(_, _, let bytes) = event { stats.add(bytes) }
                                                    }))
        try proxy.start()
        self.proxy = proxy
        log.write("根证书 SHA-256 \(ca.rootFingerprintSHA256.prefix(16))…")
    }

    /// Packet tunnel extensions are killed at roughly 50 MB, so the footprint is
    /// logged every 10 seconds while the tunnel runs, along with the peak.
    private func startMemoryLog() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.biliscope.tunnel.memory"))
        var peak: UInt64 = 0
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [log] in
            guard let footprint = Self.physicalFootprint() else { return }
            peak = max(peak, footprint)
            log.write("memory \(footprint >> 20) MB (peak \(peak >> 20) MB)")
        }
        timer.resume()
        memoryTimer = timer
    }

    private static func physicalFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }

    /// Low-memory settings from hev-socks5-tunnel's README for iOS.
    private static func hevConfig() -> String {
        """
        tunnel:
          mtu: 1500
          ipv4: \(tunnelAddress)
        socks5:
          port: \(proxyPort)
          address: 127.0.0.1
          udp: 'udp'
        mapdns:
          address: \(dnsAddress)
          port: 53
          network: \(mappedNetwork.0)
          netmask: \(mappedNetwork.1)
          cache-size: 4096
        misc:
          task-stack-size: 24576
          tcp-buffer-size: 4096
          max-session-count: 600
          log-level: warn
        """
    }
}

final class TunnelStats: @unchecked Sendable {
    private let lock = NSLock()
    private var requests = 0
    private var bytes: Int64 = 0
    func add(_ count: Int64) { lock.lock(); requests += 1; bytes += count; lock.unlock() }
    func snapshot() -> Data {
        lock.lock(); defer { lock.unlock() }
        return Data("\(requests) \(bytes)".utf8)
    }
}

final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

/// Keeps the newest log lines in memory; the app fetches them with a provider
/// message, because the two share no files.
final class TunnelLog: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private let limit = 1500
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    /// Also kept on the extension's own disk, so the last lines survive the
    /// tunnel stopping before the app could fetch them.
    private let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("BiliScopeTunnel.log")

    func write(_ line: String) {
        NSLog("BiliScopeTunnel %@", line)
        lock.lock()
        defer { lock.unlock() }
        let entry = "[\(formatter.string(from: Date()))] \(line)"
        lines.append(entry)
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
        if let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size] as? Int, size > 512_000 {
            try? FileManager.default.removeItem(at: fileURL)
        }
        let data = Data((entry + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }
}
