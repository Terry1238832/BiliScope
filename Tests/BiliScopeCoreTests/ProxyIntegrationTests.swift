import XCTest
import NIOCore
import NIOPosix
import NIOSSL
@testable import BiliScopeCore

/// Spins up a local TLS origin that understands `Range` and talks HTTP/1.1,
/// then drives the real proxy with `curl` to prove the whole chain works:
/// CONNECT -> TLS -> range split -> 206 with the exact requested bytes.
final class ProxyIntegrationTests: XCTestCase {
    var caDirectory: URL!

    override func setUpWithError() throws {
        caDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("biliscope-it-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: caDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: caDirectory)
    }

    func testRangeAccelerationThroughProxy() throws {
        let payload = Data((0..<3_000_000).map { UInt8($0 % 251) })
        let ca = try CertificateAuthority(directory: caDirectory)
        let origin = try TestOriginServer(payload: payload, ca: ca)
        try origin.start()
        defer { origin.stop() }

        let policy = HostPolicy(domains: ["localhost"], mediaDomains: ["localhost"])
        let proxy = MITMProxy(ca: ca, policy: policy, config: .init(port: 0,
                                                                    concurrency: 4,
                                                                    chunkSize: 512 << 10,
                                                                    upstreamTrustRootDER: ca.rootCertificateDER))
        let proxyPort = try proxy.start()
        defer { proxy.stop() }

        let result = try fetchThroughProxy(proxyPort: proxyPort,
                                          ca: ca,
                                          url: "https://localhost:\(origin.port)/file",
                                          range: "0-1048575")

        XCTAssertEqual(result.status, 206, result.stderr)
        let expected = payload.prefix(1_048_576)
        XCTAssertEqual(result.body, Data(expected), "body mismatch, stderr: \(result.stderr)")
    }

    func testOpenEndedRangeStreamsAllChunksInOrder() throws {
        let payload = Data((0..<2_000_000).map { UInt8(($0 * 7) % 251) })
        let ca = try CertificateAuthority(directory: caDirectory)
        let origin = try TestOriginServer(payload: payload, ca: ca)
        try origin.start()
        defer { origin.stop() }

        let policy = HostPolicy(domains: ["localhost"], mediaDomains: ["localhost"])
        let proxy = MITMProxy(ca: ca, policy: policy, config: .init(port: 0,
                                                                    concurrency: 4,
                                                                    chunkSize: 256 << 10,
                                                                    upstreamTrustRootDER: ca.rootCertificateDER))
        let proxyPort = try proxy.start()
        defer { proxy.stop() }

        let result = try fetchThroughProxy(proxyPort: proxyPort,
                                          ca: ca,
                                          url: "https://localhost:\(origin.port)/file",
                                          range: "0-")
        XCTAssertEqual(result.status, 206, result.stderr)
        XCTAssertEqual(result.body.count, payload.count)
        XCTAssertEqual(result.body, payload)
    }

    func testMidFileRangeUsesCorrectContentRange() throws {
        let payload = Data((0..<1_000_000).map { UInt8(($0 * 3) % 251) })
        let ca = try CertificateAuthority(directory: caDirectory)
        let origin = try TestOriginServer(payload: payload, ca: ca)
        try origin.start()
        defer { origin.stop() }

        let policy = HostPolicy(domains: ["localhost"], mediaDomains: ["localhost"])
        let proxy = MITMProxy(ca: ca, policy: policy, config: .init(port: 0,
                                                                    concurrency: 3,
                                                                    chunkSize: 128 << 10,
                                                                    upstreamTrustRootDER: ca.rootCertificateDER))
        let proxyPort = try proxy.start()
        defer { proxy.stop() }

        let result = try fetchThroughProxy(proxyPort: proxyPort,
                                          ca: ca,
                                          url: "https://localhost:\(origin.port)/file",
                                          range: "100000-299999")
        XCTAssertEqual(result.status, 206, result.stderr)
        let expected = payload.subdata(in: 100_000..<300_000)
        XCTAssertEqual(result.body, expected)
    }

    func testForeignHostIsBlindTunnelled() throws {
        let payload = Data((0..<200_000).map { UInt8($0 % 97) })
        let ca = try CertificateAuthority(directory: caDirectory)
        let origin = try TestOriginServer(payload: payload, ca: ca)
        try origin.start()
        defer { origin.stop() }

        // Default policy does not know "localhost", so the proxy must not
        // terminate TLS: it just relays bytes to the origin.
        let proxy = MITMProxy(ca: ca, policy: HostPolicy(), config: .init(port: 0))
        let proxyPort = try proxy.start()
        defer { proxy.stop() }

        let result = try fetchThroughProxy(proxyPort: proxyPort,
                                          ca: ca,
                                          url: "https://localhost:\(origin.port)/file",
                                          range: "0-1023")
        XCTAssertEqual(result.status, 206, result.stderr)
        XCTAssertEqual(result.body, Data(payload.prefix(1024)))
    }

    func testPlainHTTPIsRelayedForAnyHost() throws {
        let payload = Data((0..<200_000).map { UInt8($0 % 89) })
        let ca = try CertificateAuthority(directory: caDirectory)
        let origin = try TestOriginServer(payload: payload, ca: ca, useTLS: false)
        try origin.start()
        defer { origin.stop() }

        let proxy = MITMProxy(ca: ca, policy: HostPolicy(), config: .init(port: 0))
        let proxyPort = try proxy.start()
        defer { proxy.stop() }

        let result = try fetchThroughProxy(proxyPort: proxyPort,
                                          ca: ca,
                                          url: "http://127.0.0.1:\(origin.port)/a%2Fb?sig=x%3Dy",
                                          range: "0-1023")
        XCTAssertEqual(result.status, 206, result.stderr)
        XCTAssertEqual(result.body, Data(payload.prefix(1024)))
        XCTAssertEqual(origin.lastTarget, "/a%2Fb?sig=x%3Dy")
    }

    /// Shadowrocket-style tunnel: CONNECT to a bare IP, then plain HTTP inside,
    /// with the real media host only in the Host header.
    func testPlainHTTPInsideConnectToIPIsAccelerated() throws {
        let payload = Data((0..<1_000_000).map { UInt8(($0 * 5) % 251) })
        let ca = try CertificateAuthority(directory: caDirectory)
        let origin = try TestOriginServer(payload: payload, ca: ca)
        try origin.start()
        defer { origin.stop() }

        let lines = LogRecorder()
        let policy = HostPolicy(domains: ["localhost"], mediaDomains: ["localhost"])
        let proxy = MITMProxy(ca: ca, policy: policy, config: .init(port: 0,
                                                                    concurrency: 4,
                                                                    chunkSize: 128 << 10,
                                                                    upstreamTrustRootDER: ca.rootCertificateDER,
                                                                    plainHTTPConnectPorts: [origin.port],
                                                                    mediaUpstreamPort: UInt16(origin.port),
                                                                    log: { lines.append($0) }))
        let proxyPort = try proxy.start()
        defer { proxy.stop() }

        let result = try fetchThroughProxy(proxyPort: proxyPort,
                                          ca: ca,
                                          url: "http://127.0.0.1:\(origin.port)/file",
                                          range: "1000-400999",
                                          extra: ["--proxytunnel", "-H", "Host: localhost"])
        XCTAssertEqual(result.status, 206, result.stderr)
        XCTAssertEqual(result.body, payload.subdata(in: 1000..<401_000))
        XCTAssertTrue(lines.contains("accelerated localhost"), "not accelerated: \(lines.all)")
    }

    /// The player asks for one small range; the blocks after it must already be
    /// on their way, because that is the only place parallelism can come from.
    func testSmallRangeTriggersReadAhead() throws {
        let payload = Data((0..<2_000_000).map { UInt8(($0 * 11) % 251) })
        let ca = try CertificateAuthority(directory: caDirectory)
        let origin = try TestOriginServer(payload: payload, ca: ca)
        try origin.start()
        defer { origin.stop() }

        let policy = HostPolicy(domains: ["localhost"], mediaDomains: ["localhost"])
        let proxy = MITMProxy(ca: ca, policy: policy, config: .init(port: 0,
                                                                    concurrency: 4,
                                                                    chunkSize: 256 << 10,
                                                                    upstreamTrustRootDER: ca.rootCertificateDER))
        let proxyPort = try proxy.start()
        defer { proxy.stop() }

        let url = "https://localhost:\(origin.port)/file"
        let first = try fetchThroughProxy(proxyPort: proxyPort, ca: ca, url: url, range: "0-1023")
        XCTAssertEqual(first.body, Data(payload.prefix(1024)))

        let deadline = Date().addingTimeInterval(3)
        while origin.requestCount < 4, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertEqual(origin.requestCount, 4, "expected the window to be fetched ahead")

        // Served from what was fetched ahead, even across a block boundary.
        let second = try fetchThroughProxy(proxyPort: proxyPort, ca: ca, url: url, range: "200000-500000")
        XCTAssertEqual(second.body, payload.subdata(in: 200_000..<500_001))
    }

    /// A mirror that stops sending must fail fast instead of freezing the player.
    func testStalledUpstreamFailsWithinStallTimeout() throws {
        let ca = try CertificateAuthority(directory: caDirectory)
        let origin = try TestOriginServer(payload: Data(count: 1_000_000), ca: ca, stallsMidBody: true)
        try origin.start()
        defer { origin.stop() }

        let policy = HostPolicy(domains: ["localhost"], mediaDomains: ["localhost"])
        let proxy = MITMProxy(ca: ca, policy: policy, config: .init(port: 0,
                                                                    upstreamTrustRootDER: ca.rootCertificateDER,
                                                                    stallTimeout: 1))
        let proxyPort = try proxy.start()
        defer { proxy.stop() }

        let started = Date()
        let result = try fetchThroughProxy(proxyPort: proxyPort, ca: ca,
                                          url: "https://localhost:\(origin.port)/file",
                                          range: "0-1023", expectSuccess: false)
        XCTAssertNotEqual(result.status, 206)
        XCTAssertLessThan(Date().timeIntervalSince(started), 6)
    }

    func testUpstreamRequestReturningToProxyIsRefused() throws {
        let ca = try CertificateAuthority(directory: caDirectory)
        let origin = try TestOriginServer(payload: Data(count: 4096), ca: ca)
        try origin.start()
        defer { origin.stop() }

        let policy = HostPolicy(domains: ["localhost"], mediaDomains: ["localhost"])
        let proxy = MITMProxy(ca: ca, policy: policy, config: .init(port: 0, upstreamTrustRootDER: ca.rootCertificateDER))
        let proxyPort = try proxy.start()
        defer { proxy.stop() }

        let result = try fetchThroughProxy(proxyPort: proxyPort, ca: ca,
                                          url: "https://localhost:\(origin.port)/file",
                                          range: "0-1023",
                                          extra: ["-H", "X-BiliScope-Hop: 1"])
        XCTAssertEqual(result.status, 508, result.stderr)
        XCTAssertEqual(origin.requestCount, 0)
    }

    /// A host that ignores Range must reach the player as it is, not as a dead connection.
    func testUpstreamIgnoringRangeIsPassedThrough() throws {
        let payload = Data((0..<50_000).map { UInt8($0 % 251) })
        let ca = try CertificateAuthority(directory: caDirectory)
        let origin = try TestOriginServer(payload: payload, ca: ca, ignoresRange: true)
        try origin.start()
        defer { origin.stop() }

        let policy = HostPolicy(domains: ["localhost"], mediaDomains: ["localhost"])
        let proxy = MITMProxy(ca: ca, policy: policy, config: .init(port: 0, upstreamTrustRootDER: ca.rootCertificateDER))
        let proxyPort = try proxy.start()
        defer { proxy.stop() }

        let result = try fetchThroughProxy(proxyPort: proxyPort, ca: ca,
                                          url: "https://localhost:\(origin.port)/file", range: "0-1023")
        XCTAssertEqual(result.status, 200, result.stderr)
        XCTAssertEqual(result.body, payload)
    }

    /// CONNECT to a bare IP with TLS inside: the media host appears only in the SNI.
    func testBareIPConnectIsAcceleratedFromServerName() throws {
        let payload = Data((0..<600_000).map { UInt8(($0 * 13) % 251) })
        let ca = try CertificateAuthority(directory: caDirectory)
        let origin = try TestOriginServer(payload: payload, ca: ca)
        try origin.start()
        defer { origin.stop() }

        let lines = LogRecorder()
        let policy = HostPolicy(domains: ["localhost"], mediaDomains: ["localhost"])
        let proxy = MITMProxy(ca: ca, policy: policy, config: .init(port: 0,
                                                                    upstreamTrustRootDER: ca.rootCertificateDER,
                                                                    plainHTTPConnectPorts: [origin.port],
                                                                    log: { lines.append($0) }))
        let proxyPort = try proxy.start()
        defer { proxy.stop() }

        let result = try fetchThroughProxy(proxyPort: proxyPort, ca: ca,
                                          url: "https://localhost:\(origin.port)/file", range: "0-1023",
                                          extra: ["--connect-to", "localhost:\(origin.port):127.0.0.1:\(origin.port)"])
        XCTAssertEqual(result.status, 206, result.stderr)
        XCTAssertEqual(result.body, Data(payload.prefix(1024)))
        XCTAssertTrue(lines.contains("accelerated localhost"), "not accelerated: \(lines.all)")
    }

    // MARK: - Helpers

    private struct CurlResult {
        let status: Int
        let body: Data
        let stderr: String
    }

    private func fetchThroughProxy(proxyPort: Int, ca: CertificateAuthority, url: String, range: String, extra: [String] = [], expectSuccess: Bool = true) throws -> CurlResult {
        let caPath = caDirectory.appendingPathComponent("ca.pem")
        try Data(ca.rootCertificatePEM.utf8).write(to: caPath)

        let outputURL = caDirectory.appendingPathComponent(UUID().uuidString + ".bin")
        let errorURL = caDirectory.appendingPathComponent(UUID().uuidString + ".err")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = [
            "-sS", "--max-time", "30",
            "-x", "http://127.0.0.1:\(proxyPort)",
            "--cacert", caPath.path,
            "-r", range,
            "-o", outputURL.path,
            "-w", "%{http_code}",
        ] + extra + [url]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()

        let statusText = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let body = (try? Data(contentsOf: outputURL)) ?? Data()
        if expectSuccess { XCTAssertEqual(process.terminationStatus, 0, "curl failed: \(stderr)") }
        return CurlResult(status: Int(statusText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0,
                          body: body,
                          stderr: stderr)
    }
}

// MARK: - Local TLS origin

final class TestOriginServer {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let payload: Data
    private let ca: CertificateAuthority
    private var channel: Channel?
    private let useTLS: Bool
    private let targets = TargetRecorder()
    private(set) var port: Int = 0
    private let stallsMidBody: Bool
    var lastTarget: String? { targets.last }
    var requestCount: Int { targets.count }

    private let ignoresRange: Bool

    init(payload: Data, ca: CertificateAuthority, useTLS: Bool = true, stallsMidBody: Bool = false, ignoresRange: Bool = false) throws {
        self.ignoresRange = ignoresRange
        self.payload = payload
        self.ca = ca
        self.useTLS = useTLS
        self.stallsMidBody = stallsMidBody
    }

    func start() throws {
        guard useTLS else {
            let payload = self.payload
            let targets = self.targets
            let channel = try ServerBootstrap(group: group)
                .childChannelInitializer { $0.pipeline.addHandler(RangeResponder(payload: payload, targets: targets)) }
                .bind(host: "127.0.0.1", port: 0).wait()
            self.channel = channel
            self.port = channel.localAddress?.port ?? 0
            return
        }
        let identity = try ca.identity(for: "localhost")
        let certificate = try NIOSSLCertificate(bytes: Array(identity.certificatePEM.utf8), format: .pem)
        let key = try NIOSSLPrivateKey(bytes: Array(identity.privateKeyPEM.utf8), format: .pem)
        var configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(certificate)],
            privateKey: .privateKey(key)
        )
        configuration.applicationProtocols = ["http/1.1"]
        let context = try NIOSSLContext(configuration: configuration)
        let payload = self.payload
        let targets = self.targets
        let stallsMidBody = self.stallsMidBody
        let ignoresRange = self.ignoresRange

        let bootstrap = ServerBootstrap(group: group)
            .childChannelInitializer { channel -> EventLoopFuture<Void> in
                do {
                    return channel.pipeline.addHandler(try NIOSSLServerHandler(context: context)).flatMap {
                        channel.pipeline.addHandler(RangeResponder(payload: payload, targets: targets, stallsMidBody: stallsMidBody, ignoresRange: ignoresRange))
                    }
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
        let channel = try bootstrap.bind(host: "127.0.0.1", port: 0).wait()
        self.channel = channel
        self.port = channel.localAddress?.port ?? 0
    }

    func stop() {
        try? channel?.close().wait()
        channel = nil
        try? group.syncShutdownGracefully()
    }
}

final class LogRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
    func append(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    func contains(_ text: String) -> Bool { all.contains { $0.contains(text) } }
}

final class TargetRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    private var seen = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return seen }
    var last: String? {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; seen += 1; lock.unlock() }
    }
}

final class RangeResponder: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let payload: Data
    private var buffer = Data()
    private var answered = false
    private let targets: TargetRecorder?
    private let stallsMidBody: Bool
    private let ignoresRange: Bool

    init(payload: Data, targets: TargetRecorder? = nil, stallsMidBody: Bool = false, ignoresRange: Bool = false) {
        self.ignoresRange = ignoresRange
        self.payload = payload
        self.targets = targets
        self.stallsMidBody = stallsMidBody
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !answered else { return }
        var incoming = unwrapInboundIn(data)
        if let bytes = incoming.readBytes(length: incoming.readableBytes) {
            buffer.append(contentsOf: bytes)
        }
        guard let (request, _) = HTTPHeadParser.parseRequest(buffer) else { return }
        answered = true
        targets?.last = request.target

        if ignoresRange {
            var whole = context.channel.allocator.buffer(capacity: payload.count + 128)
            whole.writeString("HTTP/1.1 200 OK\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n")
            whole.writeBytes(payload)
            context.writeAndFlush(NIOAny(whole), promise: nil)
            context.close(promise: nil)
            return
        }

        let span = RangeHeader.parse(request.header("Range")) ?? ByteSpan(start: 0, end: Int64(payload.count))
        let start = Int(min(span.start, Int64(payload.count)))
        let end = Int(min(span.end == .max ? Int64(payload.count) : span.end, Int64(payload.count)))
        let body = payload.subdata(in: start..<end)

        var head = "HTTP/1.1 206 Partial Content\r\n"
        head += "Content-Range: bytes \(start)-\(max(start, end - 1))/\(payload.count)\r\n"
        head += "Content-Type: application/octet-stream\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"

        var out = context.channel.allocator.buffer(capacity: head.utf8.count + body.count)
        out.writeString(head)
        if stallsMidBody {
            // Promise the whole body, deliver part of it and keep the connection open.
            out.writeBytes(body.prefix(body.count / 2))
            context.writeAndFlush(NIOAny(out), promise: nil)
            return
        }
        out.writeBytes(body)
        context.writeAndFlush(NIOAny(out), promise: nil)
        context.close(promise: nil)
    }
}
