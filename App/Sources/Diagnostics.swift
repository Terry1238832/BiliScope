import Foundation
import Network
import Security

/// Three-phase connectivity check, so a failure says *where* it broke:
/// TCP to the local proxy, the CONNECT handshake, then the full HTTPS request.
final class Diagnostics: NSObject, URLSessionDataDelegate {
    private let caDER: Data
    private let port: UInt16
    private var session: URLSession?
    private var completion: ((String) -> Void)?
    private var usesProxy = false
    private let started = Date()

    init(caDER: Data, port: UInt16) {
        self.caDER = caDER
        self.port = port
    }

    func run(completion: @escaping (String) -> Void) {
        self.completion = completion
        Task { [weak self] in
            guard let self else { return }
            var lines: [String] = []
            do {
                let connection = try await Net.connect(host: "127.0.0.1", port: self.port, timeout: 4)
                lines.append("① 本机代理 TCP `127.0.0.1:\(self.port)` ✅ \(self.elapsed)ms")
                try await Net.send(connection, Data("CONNECT i0.hdslb.com:443 HTTP/1.1\r\nHost: i0.hdslb.com:443\r\n\r\n".utf8))
                let head = try await Net.receive(connection, until: Data("\r\n\r\n".utf8), timeout: 4)
                connection.cancel()
                let status = String(decoding: head, as: UTF8.self)
                    .split(separator: "\r\n").first.map(String.init) ?? "?"
                lines.append("② CONNECT ✅ \(status)")

                let videoCDN = "https://upos-sz-mirrorcosov.bilivideo.com/"
                let proxied = await self.request(url: videoCDN, useProxy: true, timeout: 12, range: false)
                lines.append("③ 视频 CDN 经代理 \(proxied)")

                let direct = await self.request(url: videoCDN, useProxy: false, timeout: 12, range: false)
                lines.append("④ 视频 CDN 直连 \(direct)")

                let image = await self.request(url: "https://i0.hdslb.com/bfs/face/member/noface.jpg",
                                               useProxy: false, timeout: 15, range: true)
                lines.append("⑤ 图片 CDN 直连 \(image)")
            } catch {
                lines.append("❌ \(error)")
            }
            let text = lines.joined(separator: "\n")
            DispatchQueue.main.async { completion(text) }
        }
    }

    private var elapsed: Int { Int(Date().timeIntervalSince(started) * 1000) }

    // MARK: - HTTPS request

    private func request(url: String, useProxy: Bool, timeout: TimeInterval, range: Bool) async -> String {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout + 5
        if useProxy {
            configuration.connectionProxyDictionary = [
                "HTTPSEnable": 1,
                "HTTPSProxy": "127.0.0.1",
                "HTTPSPort": Int(port),
            ]
        }
        usesProxy = useProxy
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session

        var request = URLRequest(url: URL(string: url)!)
        if range { request.setValue("bytes=0-2047", forHTTPHeaderField: "Range") }
        request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        let start = Date()
        let outcome: String = await withCheckedContinuation { continuation in
            session.dataTask(with: request) { data, response, error in
                let cost = Int(Date().timeIntervalSince(start) * 1000)
                if let error = error as NSError? {
                    let hint: String
                    switch error.code {
                    case NSURLErrorTimedOut: hint = "超时，请求没回来"
                    case NSURLErrorSecureConnectionFailed: hint = "TLS 不被信任"
                    default: hint = error.localizedDescription
                    }
                    continuation.resume(returning: "❌ \(error.code) \(hint)")
                } else if let http = response as? HTTPURLResponse {
                    continuation.resume(returning: "✅ 可达，HTTP \(http.statusCode)，\(data?.count ?? 0) 字节，\(cost)ms")
                } else {
                    continuation.resume(returning: "❌ 没有 HTTP 响应")
                }
            }.resume()
        }
        session.invalidateAndCancel()
        self.session = nil
        return outcome
    }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard usesProxy,
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let anchor = SecCertificateCreateWithData(nil, caDER as CFData) else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

// MARK: - Tiny async TCP helper

enum NetError: LocalizedError {
    case timeout
    case closed
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .timeout: return "超时"
        case .closed: return "连接被关闭"
        case .failed(let text): return text
        }
    }
}

enum Net {
    static func connect(host: String, port: UInt16, timeout: TimeInterval) async throws -> NWConnection {
        let connection = NWConnection(host: NWEndpoint.Host(host),
                                      port: NWEndpoint.Port(rawValue: port)!,
                                      using: .tcp)
        let queue = DispatchQueue(label: "com.biliscope.diagnostics")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let box = ResumeBox()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    box.once { continuation.resume() }
                case .failed(let error):
                    box.once { continuation.resume(throwing: error) }
                case .cancelled:
                    box.once { continuation.resume(throwing: NetError.closed) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                box.once { continuation.resume(throwing: NetError.timeout) }
            }
        }
        return connection
    }

    static func send(_ connection: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    static func receive(_ connection: NWConnection, until marker: Data, timeout: TimeInterval) async throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = Data()
        while buffer.range(of: marker) == nil {
            guard Date() < deadline else { throw NetError.timeout }
            guard let chunk = try await receiveOnce(connection) else { throw NetError.closed }
            buffer.append(chunk)
        }
        return buffer
    }

    private static func receiveOnce(_ connection: NWConnection) async throws -> Data? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, complete, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, !data.isEmpty { continuation.resume(returning: data) }
                else if complete { continuation.resume(returning: nil) }
                else { continuation.resume(returning: Data()) }
            }
        }
    }
}

final class ResumeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    func once(_ body: () -> Void) {
        lock.lock()
        guard !used else { lock.unlock(); return }
        used = true
        lock.unlock()
        body()
    }
}
