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

    // MARK: - Helpers

    private struct CurlResult {
        let status: Int
        let body: Data
        let stderr: String
    }

    private func fetchThroughProxy(proxyPort: Int, ca: CertificateAuthority, url: String, range: String) throws -> CurlResult {
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
            url,
        ]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()

        let statusText = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let body = (try? Data(contentsOf: outputURL)) ?? Data()
        XCTAssertEqual(process.terminationStatus, 0, "curl failed: \(stderr)")
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
    private(set) var port: Int = 0

    init(payload: Data, ca: CertificateAuthority) throws {
        self.payload = payload
        self.ca = ca
    }

    func start() throws {
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

        let bootstrap = ServerBootstrap(group: group)
            .childChannelInitializer { channel -> EventLoopFuture<Void> in
                do {
                    return channel.pipeline.addHandler(try NIOSSLServerHandler(context: context)).flatMap {
                        channel.pipeline.addHandler(RangeResponder(payload: payload))
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

final class RangeResponder: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let payload: Data
    private var buffer = Data()
    private var answered = false

    init(payload: Data) {
        self.payload = payload
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !answered else { return }
        var incoming = unwrapInboundIn(data)
        if let bytes = incoming.readBytes(length: incoming.readableBytes) {
            buffer.append(contentsOf: bytes)
        }
        guard let (request, _) = HTTPHeadParser.parseRequest(buffer) else { return }
        answered = true

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
        out.writeBytes(body)
        context.writeAndFlush(NIOAny(out), promise: nil)
        context.close(promise: nil)
    }
}
