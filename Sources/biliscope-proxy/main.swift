import Foundation
import BiliScopeCore

setvbuf(stdout, nil, _IOLBF, 0)

let arguments = CommandLine.arguments

func argument(_ name: String, default fallback: String) -> String {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return fallback }
    return arguments[index + 1]
}

func run() throws {
    let lanMode = arguments.contains("--lan")
    let home = FileManager.default.homeDirectoryForCurrentUser
    let caDirectory = URL(fileURLWithPath: argument("--ca-dir",
        default: home.appendingPathComponent("Library/Application Support/BiliScope").path))
    let port = UInt16(argument("--port", default: "8888")) ?? 8888
    let profilePort = UInt16(argument("--profile-port", default: "8899")) ?? 8899
    let chunkSize = Int64(argument("--chunk-size", default: "1048576")) ?? (1 << 20)
    let concurrency = Int(argument("--concurrency", default: "8")) ?? 8
    let bindHost = argument("--bind", default: lanMode ? "0.0.0.0" : "127.0.0.1")

    let explicitAllow = argument("--allow", default: "")
    let allowlist: ClientAllowlist
    if lanMode {
        allowlist = .privateNetworks
    } else if explicitAllow.isEmpty {
        allowlist = ClientAllowlist()
    } else {
        allowlist = ClientAllowlist(explicitAllow.split(separator: ",").map(String.init))
    }

    let ca = try CertificateAuthority(directory: caDirectory)
    print("root CA    : \(caDirectory.appendingPathComponent("ca-cert.pem").path)")
    print("fingerprint: \(ca.rootFingerprintSHA256)")

    let profile = ProfileServer(ca: ca, port: profilePort, bindHost: lanMode ? "0.0.0.0" : "127.0.0.1")
    try profile.start()
    print("profile    : http://127.0.0.1:\(profilePort)/ca.mobileconfig")

    let logger: @Sendable (String) -> Void = { line in
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        print("[\(formatter.string(from: Date()))] \(line)")
    }

    let proxy = MITMProxy(ca: ca, config: .init(bindHost: bindHost,
                                                port: port,
                                                concurrency: concurrency,
                                                chunkSize: chunkSize,
                                                allowedClients: allowlist,
                                                logForeignHosts: arguments.contains("--log-all"),
                                                log: logger))
    let actual = try proxy.start()
    print("proxy      : http://\(bindHost == "0.0.0.0" ? "127.0.0.1" : bindHost):\(actual)")
    print("accelerate : \(HostPolicy.defaultMediaDomains.joined(separator: ", ")) + upos-*-mirror*.akamaized.net")

    if lanMode {
        let lanIP = LocalAddresses.ipv4().first { $0 != "127.0.0.1" } ?? "<本机局域网 IP>"
        print("")
        print("LAN 模式：只接受私有网段客户端（127 / 10 / 192.168 / 172.16-31）")
        print("  iPhone Wi-Fi 代理 -> \(lanIP):\(actual)")
        print("  iPhone 证书地址   -> http://\(lanIP):\(profilePort)/ca.mobileconfig")
        print("  顺序：先装证书并信任，再改 Wi-Fi 代理")
    }

    signal(SIGINT) { _ in
        print("\nstopping")
        exit(0)
    }
    RunLoop.main.run()

}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("启动失败：\(error)\n".utf8))
    exit(1)
}
