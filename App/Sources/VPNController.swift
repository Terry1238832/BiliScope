import Foundation
import NetworkExtension

/// Installs and drives the app's own packet tunnel, which replaces Shadowrocket.
@MainActor
final class VPNController: ObservableObject {
    @Published private(set) var status: NEVPNStatus = .invalid
    @Published private(set) var lastError: String?
    @Published var fullTunnel = false
    /// The newest lines of the tunnel's log, shown in place of the app's own.
    @Published private(set) var tunnelLines: [String] = []
    @Published private(set) var acceleratedRequests = 0
    @Published private(set) var acceleratedBytes: Int64 = 0

    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?
    private var logPoll: Task<Void, Never>?

    /// The tunnel's log, copied here so it can be shared and pulled off a device.
    static var tunnelLogURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BiliScope-tunnel.log")
    }

    private var tunnelBundleIdentifier: String {
        (Bundle.main.bundleIdentifier ?? "") + ".tunnel"
    }

    init() {
        observer = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStatus() }
        }
        Task { await load() }
    }

    var isOn: Bool { status == .connected || status == .connecting || status == .reasserting }

    var statusText: String {
        switch status {
        case .connected: return "已连接"
        case .connecting: return "连接中…"
        case .disconnecting: return "断开中…"
        case .reasserting: return "重新连接中…"
        case .disconnected: return "未连接"
        case .invalid: return "未安装"
        @unknown default: return "未知"
        }
    }

    func load() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            manager = managers.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == tunnelBundleIdentifier }
            if let configuration = (manager?.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration {
                fullTunnel = configuration[TunnelShared.fullTunnelKey] as? Bool ?? false
            }
            refreshStatus()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// The first save shows iOS's "Allow VPN configuration" prompt.
    func start() async {
        lastError = nil
        // The tunnel cannot read the app's container, so it gets the CA the
        // user already trusted instead of making its own.
        var ca: [String: String] = [:]
        for name in TunnelShared.caFiles {
            guard let text = try? String(contentsOf: TunnelShared.appCADirectory.appendingPathComponent(name), encoding: .utf8) else {
                lastError = "还没有根证书：先在下面安装并信任根证书"
                return
            }
            ca[name] = text
        }
        let manager = self.manager ?? NETunnelProviderManager()
        let configuration = NETunnelProviderProtocol()
        configuration.providerBundleIdentifier = tunnelBundleIdentifier
        configuration.serverAddress = "本机"
        configuration.providerConfiguration = [TunnelShared.fullTunnelKey: fullTunnel, TunnelShared.caKey: ca]
        manager.protocolConfiguration = configuration
        manager.localizedDescription = "哔哩加速"
        manager.isEnabled = true
        do {
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
            self.manager = manager
            try manager.connection.startVPNTunnel()
            refreshStatus()
        } catch {
            lastError = Self.describe(error)
        }
    }

    /// NetworkExtension's own messages are terse English ("IPC failed").
    static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        guard nsError.domain == NEVPNErrorDomain, let code = NEVPNError.Code(rawValue: nsError.code) else {
            return error.localizedDescription
        }
        switch code {
        case .configurationReadWriteFailed:
            return "没能保存 VPN 配置：可能是在弹窗里点了“不允许”，再点一次加速并选择允许"
        case .configurationDisabled, .configurationInvalid:
            return "VPN 配置无效，请在 设置 → VPN 里删除哔哩加速后重试"
        case .connectionFailed:
            return "VPN 没能连上，请再试一次"
        case .configurationStale:
            return "VPN 配置已在别处修改，请再试一次"
        case .configurationUnknown:
            return "这台设备暂时无法开启 VPN（模拟器不支持）"
        @unknown default:
            return error.localizedDescription
        }
    }

    func stop() {
        manager?.connection.stopVPNTunnel()
    }

    /// Stops the tunnel, waits until it is really down, then starts it in the
    /// given mode (`nil` only stops). Lets a connected Mac switch modes.
    func restart(fullTunnel full: Bool?) async {
        await load()
        note("restart requested, status \(statusText), full \(full.map(String.init) ?? "off")")
        stop()
        for _ in 0..<50 where status != .disconnected && status != .invalid {
            try? await Task.sleep(nanoseconds: 200_000_000)
            refreshStatus()
        }
        guard let full else { return }
        fullTunnel = full
        await start()
        note("started, status \(statusText), error \(lastError ?? "none")")
    }

    /// Appends to the app's tunnel log, so remote mode switches leave a trace.
    private func note(_ line: String) {
        let entry = "[app] \(Date()) \(line)\n"
        let url = Self.tunnelLogURL.deletingLastPathComponent().appendingPathComponent("BiliScope-vpn.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(entry.utf8))
        } else {
            try? Data(entry.utf8).write(to: url)
        }
    }

    private func refreshStatus() {
        status = manager?.connection.status ?? .invalid
        if !isOn {
            acceleratedRequests = 0
            acceleratedBytes = 0
        }
        if isOn, logPoll == nil {
            logPoll = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.fetchTunnelLog()
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
        } else if !isOn {
            logPoll?.cancel()
            logPoll = nil
        }
    }

    private func send(_ message: Data, to session: NETunnelProviderSession) async -> Data? {
        await withCheckedContinuation { continuation in
            do {
                try session.sendProviderMessage(message) { continuation.resume(returning: $0) }
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }

    private func fetchTunnelLog() async {
        guard let session = manager?.connection as? NETunnelProviderSession, status == .connected else { return }
        if let stats = await send(TunnelShared.statsRequest, to: session) {
            let parts = String(decoding: stats, as: UTF8.self).split(separator: " ")
            if parts.count == 2 {
                acceleratedRequests = Int(parts[0]) ?? acceleratedRequests
                acceleratedBytes = Int64(parts[1]) ?? acceleratedBytes
            }
        }
        guard let reply = await send(TunnelShared.logRequest, to: session) else { return }
        try? reply.write(to: Self.tunnelLogURL)
        tunnelLines = String(decoding: reply, as: UTF8.self)
            .split(separator: "\n").suffix(80).map(String.init)
    }
}
