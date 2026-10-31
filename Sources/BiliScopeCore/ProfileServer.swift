import Foundation
import Network
import BiliScopeCore

/// Serves the root-certificate `.mobileconfig` so the user can install it
/// through Safari. Loopback by default; the command-line LAN mode binds the
/// WiFi address instead.
public final class ProfileServer {
    private let ca: CertificateAuthority
    private let port: UInt16
    private let bindHost: String
    private let queue = DispatchQueue(label: "com.biliscope.profile")
    private var listener: NWListener?

    public init(ca: CertificateAuthority, port: UInt16, bindHost: String = "127.0.0.1") {
        self.ca = ca
        self.port = port
        self.bindHost = bindHost
    }

    public func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "BiliScope", code: 1, userInfo: [NSLocalizedDescriptionKey: "无效端口"])
        }
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(bindHost), port: nwPort)

        let listener = try NWListener(using: parameters)

        let semaphore = DispatchSemaphore(value: 0)
        var failure: Error?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                semaphore.signal()
            case .failed(let error):
                failure = error
                semaphore.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)
        self.listener = listener

        _ = semaphore.wait(timeout: .now() + 3)
        if let failure { throw failure }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, error in
            guard let self, let data, error == nil else {
                connection.cancel()
                return
            }
            let request = String(decoding: data, as: UTF8.self)
            let path = request
                .split(separator: "\r\n").first?
                .split(separator: " ").dropFirst().first
                .map(String.init) ?? "/"
            let response = self.response(for: path)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func response(for path: String) -> Data {
        if path.hasPrefix("/ca.mobileconfig") {
            let body = ca.mobileConfiguration()
            var head = "HTTP/1.1 200 OK\r\n"
            head += "Content-Type: application/x-apple-aspen-config\r\n"
            head += "Content-Disposition: attachment; filename=\"BiliScope-CA.mobileconfig\"\r\n"
            head += "Content-Length: \(body.count)\r\n"
            head += "Cache-Control: no-store\r\n"
            head += "Connection: close\r\n\r\n"
            return Data(head.utf8) + body
        }

        if path == "/" || path.hasPrefix("/index") {
            let html = """
            <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
            <style>
            body{background:#0f1115;color:#eee;font:16px -apple-system;margin:0;padding:28px;line-height:1.7}
            h1{font-size:22px} a{display:block;margin:24px 0;padding:16px;background:#fb7299;color:#fff;
            text-align:center;border-radius:14px;text-decoration:none;font-weight:600}
            p{color:#9aa0aa} code{background:#1c1f26;padding:2px 6px;border-radius:6px}
            </style>
            <h1>哔哩加速 · 根证书</h1>
            <p>这个证书只用于解密 B 站视频 CDN 的流量（<code>*.bilivideo.com</code>、<code>*.hdslb.com</code>），
            其他网站不会被解密。</p>
            <a href="/ca.mobileconfig">安装根证书</a>
            <p>安装后回到「设置 → 通用 → 关于本机 → 证书信任设置」，把 BiliScope Root CA 的完全信任打开。</p>
            """
            let body = Data(html.utf8)
            var head = "HTTP/1.1 200 OK\r\n"
            head += "Content-Type: text/html; charset=utf-8\r\n"
            head += "Content-Length: \(body.count)\r\n"
            head += "Connection: close\r\n\r\n"
            return Data(head.utf8) + body
        }

        return Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
    }
}
