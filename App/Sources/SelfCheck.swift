import Foundation
import CFNetwork
import Security

/// End-to-end check of the local path: CONNECT through the proxy, TLS with our
/// own root, and a Range request to a Bilibili CDN host. It does not prove the
/// Bilibili app honours the system proxy, but it proves everything on our side.
final class SelfCheck: NSObject, URLSessionDataDelegate {
    private let caDER: Data
    private let port: UInt16
    private var completion: ((String) -> Void)?
    private var session: URLSession?

    init(caDER: Data, port: UInt16) {
        self.caDER = caDER
        self.port = port
    }

    func run(completion: @escaping (String) -> Void) {
        self.completion = completion

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        // The kCFNetworkProxies* constants are macOS-only; the underlying
        // dictionary keys are accepted on iOS as plain strings.
        configuration.connectionProxyDictionary = [
            "HTTPSEnable": 1,
            "HTTPSProxy": "127.0.0.1",
            "HTTPSPort": Int(port),
        ]
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session

        var request = URLRequest(url: URL(string: "https://i0.hdslb.com/bfs/face/member/noface.jpg")!)
        request.setValue("bytes=0-2047", forHTTPHeaderField: "Range")
        request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                let ns = error as NSError
                if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorSecureConnectionFailed {
                    self.finish("❌ TLS 失败：根证书未受信任。仅安装描述文件不够，还要到 设置 → 通用 → 关于本机 → 证书信任设置 打开完全信任。")
                } else {
                    self.finish("❌ 失败：\(ns.domain) \(ns.code) · \(ns.localizedDescription)")
                }
                return
            }
            guard let http = response as? HTTPURLResponse else {
                self.finish("⚠️ 未拿到 HTTP 响应")
                return
            }
            if http.statusCode == 206, let data, !data.isEmpty {
                self.finish("✅ 通过：代理 + 根证书 + 分片链路正常（206，\(data.count) 字节）")
            } else {
                self.finish("⚠️ 代理通了，但返回 \(http.statusCode)")
            }
        }.resume()
    }

    private func finish(_ message: String) {
        DispatchQueue.main.async {
            self.completion?(message)
            self.completion = nil
            self.session?.invalidateAndCancel()
            self.session = nil
        }
    }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let certificate = SecCertificateCreateWithData(nil, caDER as CFData) else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        SecTrustSetAnchorCertificates(trust, [certificate] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)

        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
