import Foundation
import UIKit
import BiliScopeCore

final class ProxyController: ObservableObject {
    enum BindMode: String, CaseIterable, Identifiable {
        case loopback
        case wifi
        var id: String { rawValue }
        var title: String {
            switch self {
            case .loopback: return "127.0.0.1"
            case .wifi: return "Wi-Fi 地址"
            }
        }
    }

    @Published private(set) var isRunning = false
    @Published private(set) var logs: [String] = []
    @Published private(set) var caFingerprint = ""
    @Published private(set) var selfCheckText = ""
    @Published private(set) var selfCheckRunning = false
    @Published private(set) var certificateTrusted = false
    @Published private(set) var acceleratedCount = 0
    @Published private(set) var tunnelCount = 0
    @Published var autoStart: Bool = ProxyController.storedAutoStart() {
        didSet { UserDefaults.standard.set(autoStart, forKey: "autoStart") }
    }
    @Published var bindMode: BindMode = .loopback {
        didSet {
            UserDefaults.standard.set(bindMode.rawValue, forKey: "bindMode")
            guard oldValue != bindMode, isRunning else { return }
            stop()
            start()
        }
    }

    let proxyPort: UInt16 = 8888
    static let profilePort: UInt16 = 8899

    private var proxy: MITMProxy?
    private var profileServer: ProfileServer?
    private let keepAlive = AudioKeepAlive()
    private var check: SelfCheck?

    init() {
        bindMode = ProxyController.storedBindMode()
        refreshTrust()
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-bindlan") { bindMode = .wifi }
        if arguments.contains("-bindloop") { bindMode = .loopback }
        if arguments.contains("-install") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.installCertificate()
            }
        }
        if arguments.contains("-noproxy") { return }
        let forced = arguments.contains("-autostart")
        guard forced || autoStart else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.start()
            if forced {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self?.runSelfCheck() }
            }
        }
    }

    private static func storedBindMode() -> BindMode {
        guard let raw = UserDefaults.standard.string(forKey: "bindMode"),
              let mode = BindMode(rawValue: raw) else { return .loopback }
        return mode
    }

    private static func storedAutoStart() -> Bool {
        if UserDefaults.standard.object(forKey: "autoStart") == nil { return true }
        return UserDefaults.standard.bool(forKey: "autoStart")
    }

    var wifiAddress: String? {
        LocalAddresses.ipv4().first { $0 != "127.0.0.1" }
    }

    var proxyAddress: String {
        bindMode == .loopback ? "127.0.0.1:\(proxyPort)" : "\(wifiAddress ?? "0.0.0.0"):\(proxyPort)"
    }
    var profileURL: URL { URL(string: "http://127.0.0.1:\(Self.profilePort)/ca.mobileconfig")! }

    private var caDirectory: URL {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-cadir"), index + 1 < arguments.count {
            return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }
        #endif
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("BiliScope", isDirectory: true)
    }

    var caPath: String { caDirectory.appendingPathComponent("ca-cert.pem").path }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        do {
            let ca = try CertificateAuthority(directory: caDirectory)
            caFingerprint = ca.rootFingerprintSHA256

            let logger: @Sendable (String) -> Void = { [weak self] line in
                DispatchQueue.main.async { self?.append(line) }
            }
            let onEvent: @Sendable (TrafficEvent) -> Void = { [weak self] event in
                DispatchQueue.main.async {
                    switch event {
                    case .tunnel:
                        self?.tunnelCount += 1
                    case .accelerated:
                        self?.acceleratedCount += 1
                    }
                }
            }

            ensureProfileServer()

            let bindHost = bindMode == .loopback ? "127.0.0.1" : "0.0.0.0"
            let clients: ClientAllowlist
            if bindMode == .loopback {
                clients = ClientAllowlist()
            } else {
                clients = ClientAllowlist([wifiAddress, "127.0.0.1"].compactMap { $0 })
            }
            let proxy = MITMProxy(ca: ca, config: .init(bindHost: bindHost,
                                                        port: proxyPort,
                                                        concurrency: 8,
                                                        chunkSize: 2 << 20,
                                                        allowedClients: clients,
                                                        log: logger,
                                                        onEvent: onEvent))
            _ = try proxy.start()
            self.proxy = proxy
            keepAlive.start()
            tunnelCount = 0
            acceleratedCount = 0
            isRunning = true
            refreshTrust()
            append("代理已启动 \(proxyAddress)")
        } catch {
            let message: String
            if String(describing: error).contains("address already in use") {
                message = "端口 \(proxyPort) 被占用，先关掉占用的 App 再试"
            } else {
                message = "启动失败：\(error.localizedDescription)"
            }
            append(message)
            stop()
        }
    }

    func refreshTrust() {
        guard let ca = try? CertificateAuthority(directory: caDirectory) else {
            certificateTrusted = false
            return
        }
        certificateTrusted = CertificateTrust.isTrusted(ca.rootCertificateDER)
    }

    func stop() {
        proxy?.stop()
        proxy = nil
        profileServer?.stop()
        profileServer = nil
        keepAlive.stop()
        if isRunning { append("代理已停止") }
        isRunning = false
    }

    // MARK: - Certificate

    func installCertificate() {
        ensureProfileServer()
        UIApplication.shared.open(profileURL)
    }

    /// The certificate page must work even when the proxy itself is off.
    private func ensureProfileServer() {
        guard profileServer == nil else { return }
        do {
            let ca = try CertificateAuthority(directory: caDirectory)
            let server = ProfileServer(ca: ca, port: Self.profilePort)
            try server.start()
            profileServer = server
        } catch {
            append("证书服务启动失败：\(error.localizedDescription)")
        }
    }

    func openWiFiSettings() {
        if let url = URL(string: "App-Prefs:root=WIFI"), UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        } else if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    // MARK: - Self check

    func runSelfCheck() {
        guard isRunning, let ca = try? CertificateAuthority(directory: caDirectory) else {
            selfCheckText = "请先启动代理"
            return
        }
        selfCheckRunning = true
        selfCheckText = "检测中…"
        let check = SelfCheck(caDER: ca.rootCertificateDER, port: proxyPort)
        self.check = check
        check.run { [weak self] result in
            DispatchQueue.main.async {
                self?.selfCheckRunning = false
                self?.selfCheckText = result
                self?.append("自检：\(result)")
                self?.check = nil
            }
        }
    }

    func clearLogs() {
        logs.removeAll()
    }

    private func append(_ line: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let entry = "[\(formatter.string(from: Date()))] \(line)"
        logs.append(entry)
        NSLog("BiliScope %@", entry)
        if logs.count > 300 { logs.removeFirst(logs.count - 300) }
    }
}
