import Foundation
import NIOCore
import NIOPosix
@preconcurrency import NIOSSL

/// A local HTTP proxy that only intercepts Bilibili media hosts.
///
/// * Anything that is not a Bilibili domain is relayed byte-for-byte (TLS is
///   never terminated and never parsed). Non-Bilibili traffic that the user's
///   proxy settings send here still has to work, so it is tunnelled, not dropped.
/// * Bilibili API hosts are also tunnelled untouched.
/// * Only the media CDN hosts listed in `HostPolicy` get a local certificate and
///   Range-aware download acceleration.
/// Coarse traffic counters for the UI. Deliberately does not carry URLs,
/// query strings or anything belonging to non-Bilibili hosts.
public enum TrafficEvent: Sendable {
    case tunnel(host: String)
    case accelerated(host: String, chunks: Int)
}

public final class MITMProxy {
    public struct Configuration: Sendable {
        public var bindHost: String
        public var port: UInt16
        public var concurrency: Int
        public var chunkSize: Int64
        public var allowedClients: ClientAllowlist
        /// Optional pin for upstream TLS. Only used by tests and self-signed
        /// origins; production traffic verifies against the system roots.
        public var upstreamTrustRootDER: Data?
        public var log: @Sendable (String) -> Void
        public var onEvent: (@Sendable (TrafficEvent) -> Void)?

        public init(bindHost: String = "127.0.0.1",
                    port: UInt16 = 8888,
                    concurrency: Int = 8,
                    chunkSize: Int64 = 2 << 20,
                    allowedClients: ClientAllowlist = ClientAllowlist(),
                    upstreamTrustRootDER: Data? = nil,
                    log: @escaping @Sendable (String) -> Void = { _ in },
                    onEvent: (@Sendable (TrafficEvent) -> Void)? = nil) {
            self.bindHost = bindHost
            self.port = port
            self.concurrency = concurrency
            self.chunkSize = chunkSize
            self.allowedClients = allowedClients
            self.upstreamTrustRootDER = upstreamTrustRootDER
            self.log = log
            self.onEvent = onEvent
        }
    }

    private let group: MultiThreadedEventLoopGroup
    private let ca: CertificateAuthority
    private let policy: HostPolicy
    private let config: Configuration
    private let material: TLSMaterial
    private var server: Channel?

    public init(ca: CertificateAuthority,
                policy: HostPolicy = HostPolicy(),
                config: Configuration = Configuration()) {
        self.ca = ca
        self.policy = policy
        self.config = config
        self.material = TLSMaterial(ca: ca)
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    }

    deinit {
        try? group.syncShutdownGracefully()
    }

    /// Binds and returns the actual port (useful when `port == 0`).
    @discardableResult
    public func start() throws -> Int {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 128)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .childChannelInitializer { [material, policy, config] channel in
                channel.pipeline.addHandler(
                    FrontDoorHandler(material: material, policy: policy, config: config)
                )
            }
        let channel = try bootstrap.bind(host: config.bindHost, port: Int(config.port)).wait()
        self.server = channel
        let actualPort = channel.localAddress?.port ?? Int(config.port)
        config.log("proxy listening on \(config.bindHost):\(actualPort)")
        return actualPort
    }

    public func stop() {
        try? server?.close().wait()
        server = nil
    }
}

// MARK: - Front door

final class FrontDoorHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let material: TLSMaterial
    private let policy: HostPolicy
    private let config: MITMProxy.Configuration

    private var buffer = Data()
    private var decided = false
    private var relayPeer: Channel?
    private let allowlist: ClientAllowlist
    private let localHosts: Set<String>

    init(material: TLSMaterial, policy: HostPolicy, config: MITMProxy.Configuration) {
        self.material = material
        self.policy = policy
        self.config = config
        self.allowlist = config.allowedClients
        self.localHosts = Set(LocalAddresses.ipv4() + ["127.0.0.1", "localhost", "::1"])
    }

    func channelActive(context: ChannelHandlerContext) {
        let remote = context.channel.remoteAddress?.ipAddress
        guard allowlist.allows(remote) else {
            config.log("denied client \(remote ?? "unknown")")
            context.close(promise: nil)
            return
        }
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        if let bytes = incoming.readBytes(length: incoming.readableBytes) {
            buffer.append(contentsOf: bytes)
        }

        if let peer = relayPeer {
            flush(to: peer)
            return
        }
        guard !decided else { return }

        guard let (request, headEnd) = HTTPHeadParser.parseRequest(buffer) else {
            if buffer.count > HTTPHeadParser.maxHeadSize {
                context.close(promise: nil)
            }
            return
        }
        decided = true
        buffer.removeFirst(headEnd)

        guard request.method == "CONNECT" else {
            // The only plain-HTTP traffic we accept is loopback, which is how
            // the app serves its own root-certificate profile to Safari.
            if let url = URL(string: request.target), let host = url.host, localHosts.contains(host) {
                startPlainRelay(context: context, request: request, host: host, port: url.port ?? 80)
            } else {
                respond(context, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            }
            return
        }

        let target = request.target
        let host = HostPolicy.normalize(target)
        let port = Self.port(from: target)
        let route = policy.route(for: host)

        if route == .accelerate {
            startMITM(context: context, host: host, port: port)
        } else {
            startRelay(context: context, host: host, port: port, route: route)
        }
    }

    private func startMITM(context: ChannelHandlerContext, host: String, port: Int) {
        let channel = context.channel
        let sslContext: NIOSSLContext
        do {
            sslContext = try material.context(for: host)
        } catch {
            config.log("certificate error for \(host): \(error)")
            respond(context, "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            return
        }

        // The client waits for the 200 before it starts its TLS handshake, but
        // anything it sends early is buffered right here until the pipeline is
        // rebuilt, so no bytes are lost in the hand-off.
        config.log("mitm \(host)")
        let promise = channel.eventLoop.makePromise(of: Void.self)
        channel.writeAndFlush(ByteBuffer(string: "HTTP/1.1 200 Connection Established\r\n\r\n"), promise: promise)
        // NIOSSLServerHandler is not Sendable, which NIO 2.8 warns about when
        // adding it from a closure. It is only ever touched on this channel's
        // event loop, so the warning is benign.
        let tlsHandler = NIOSSLServerHandler(context: sslContext)
        promise.futureResult.flatMap { _ in
            channel.pipeline.addHandler(tlsHandler)
        }.flatMap { _ in
            channel.pipeline.addHandler(MediaHandler(host: host, port: UInt16(port), config: self.config))
        }.flatMap { _ in
            channel.pipeline.removeHandler(self)
        }.whenComplete { result in
            switch result {
            case .success:
                self.firePending(on: channel)
            case .failure(let error):
                self.config.log("mitm setup failed for \(host): \(error)")
                channel.close(promise: nil)
            }
        }
    }

    private func startPlainRelay(context: ChannelHandlerContext, request: HTTPRequestHead, host: String, port: Int) {
        let channel = context.channel
        ClientBootstrap(group: channel.eventLoop)
            .channelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .connect(host: host, port: port)
            .flatMap { upstream -> EventLoopFuture<Void> in
                var text = "\(request.method) \(request.path) HTTP/1.1\r\n"
                for header in request.headers where header.name.lowercased() != "proxy-connection" {
                    text += "\(header.name): \(header.value)\r\n"
                }
                text += "Connection: close\r\n\r\n"
                return upstream.writeAndFlush(ByteBuffer(string: text)).flatMap {
                    self.relayPeer = upstream
                    return upstream.pipeline.addHandler(RelayHandler(peer: channel))
                }
            }.whenComplete { result in
                switch result {
                case .success:
                    if let peer = self.relayPeer { self.flush(to: peer) }
                case .failure(let error):
                    self.config.log("local relay failed: \(error)")
                    channel.close(promise: nil)
                }
            }
    }

    private func startRelay(context: ChannelHandlerContext, host: String, port: Int, route: HostRoute) {
        let channel = context.channel
        let promise = channel.eventLoop.makePromise(of: Void.self)
        channel.writeAndFlush(ByteBuffer(string: "HTTP/1.1 200 Connection Established\r\n\r\n"), promise: promise)

        promise.futureResult.flatMap { _ in
            ClientBootstrap(group: channel.eventLoop)
                .channelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
                .connect(host: host, port: port)
        }.flatMap { upstream -> EventLoopFuture<Void> in
            // Stay in the pipeline as the client -> upstream direction; this
            // avoids a window where inbound bytes have no handler.
            self.relayPeer = upstream
            // Never log foreign hostnames: the proxy is a pass-through for
            // those and the user should not see other apps' traffic in the log.
            if route == .blindTunnel {
                self.config.log("tunnel \(host)")
                self.config.onEvent?(.tunnel(host: host))
            }
            return upstream.pipeline.addHandler(RelayHandler(peer: channel))
        }.whenComplete { result in
            switch result {
            case .success:
                if let peer = self.relayPeer { self.flush(to: peer) }
            case .failure(let error):
                self.config.log("relay failed for \(host): \(error)")
                channel.close(promise: nil)
            }
        }
    }

    private func flush(to peer: Channel) {
        guard !buffer.isEmpty else { return }
        let pending = buffer
        buffer.removeAll(keepingCapacity: false)
        peer.writeAndFlush(ByteBuffer(bytes: pending), promise: nil)
    }

    private func firePending(on channel: Channel) {
        guard !buffer.isEmpty else { return }
        let pending = buffer
        buffer.removeAll(keepingCapacity: false)
        channel.pipeline.fireChannelRead(ByteBuffer(bytes: pending))
    }

    private func respond(_ context: ChannelHandlerContext, _ text: String) {
        context.writeAndFlush(NIOAny(ByteBuffer(string: text)), promise: nil)
        context.close(promise: nil)
    }

    private static func port(from target: String) -> Int {
        guard let colon = target.lastIndex(of: ":") else { return 443 }
        let text = target[target.index(after: colon)...]
        return Int(text) ?? 443
    }

    func channelInactive(context: ChannelHandlerContext) {
        relayPeer?.close(promise: nil)
        relayPeer = nil
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        relayPeer?.close(promise: nil)
        context.close(promise: nil)
    }
}

// MARK: - Blind relay

final class RelayHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    let peer: Channel

    init(peer: Channel) {
        self.peer = peer
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        peer.writeAndFlush(unwrapInboundIn(data), promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        peer.close(promise: nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
        peer.close(promise: nil)
    }
}

// MARK: - Media (MITM) handler

final class MediaHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let host: String
    private let port: UInt16
    private let config: MITMProxy.Configuration
    private var buffer = Data()
    private var busy = false

    init(host: String, port: UInt16, config: MITMProxy.Configuration) {
        self.host = host
        self.port = port
        self.config = config
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        config.log("tls/http error \(host): \(error)")
        context.close(promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        if let bytes = incoming.readBytes(length: incoming.readableBytes) {
            buffer.append(contentsOf: bytes)
        }
        guard !busy, let (request, headEnd) = HTTPHeadParser.parseRequest(buffer) else { return }
        busy = true
        buffer.removeFirst(headEnd)
        let rest = buffer
        buffer.removeAll(keepingCapacity: false)

        let channel = context.channel
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.dispatch(request, leftover: rest, channel: channel)
            } catch {
                self.config.log("media error \(self.host): \(error)")
                channel.close(promise: nil)
            }
        }
    }

    private func dispatch(_ request: HTTPRequestHead, leftover: Data, channel: Channel) async throws {
        guard request.method == "GET",
              let rangeHeader = request.header("Range"),
              let span = RangeHeader.parse(rangeHeader) else {
            try await forward(request, channel: channel)
            return
        }
        try await accelerate(request, span: span, channel: channel)
    }

    private func forward(_ request: HTTPRequestHead, channel: Channel) async throws {
        let client = try await UpstreamClient.open(host: host, port: port)
        defer { client.cancel() }
        let data = Self.requestData(request, host: host, range: nil, close: true)
        try await client.send(data)
        var transferred = 0
        while let chunk = try await client.receive() {
            transferred += chunk.count
            try await channel.writeAndFlush(ByteBuffer(bytes: chunk)).get()
        }
        config.log("forward \(host)\(request.path.prefix(80)) \(transferred)B")
        try? await channel.close().get()
    }

    private func accelerate(_ request: HTTPRequestHead, span: ByteSpan, channel: Channel) async throws {
        let probeSize = min(config.chunkSize, 1 << 20)
        let probeSpan = ByteSpan(start: span.start,
                                 end: span.end == .max ? span.start + probeSize : min(span.start + probeSize, span.end))

        let candidates = MirrorPlanner.candidates(for: host)
        let family = MirrorPlanner.family(for: host) ?? host
        let preferred = MirrorCache.shared.preferred(for: family)
        let (probeHead, probeBody, winner) = try await probe(request,
                                                             span: probeSpan,
                                                             candidates: candidates,
                                                             preferred: preferred)
        MirrorCache.shared.remember(winner, for: family)
        if winner != host {
            config.log("mirror \(host) -> \(winner)")
        }

        guard let contentRange = RangeHeader.parseContentRange(probeHead.header("Content-Range")),
              let total = contentRange.total else {
            throw UpstreamClient.Failure.http("missing Content-Range")
        }
        let end = span.end == .max ? total : min(span.end, total)
        guard end > span.start else { throw UpstreamClient.Failure.http("empty range") }

        var head = HTTPResponseHead(status: 206, reason: "Partial Content", headers: [])
        head.headers.append(("Content-Range", "bytes \(span.start)-\(end - 1)/\(total)"))
        head.headers.append(("Content-Type", probeHead.header("Content-Type") ?? "application/octet-stream"))
        head.headers.append(("Accept-Ranges", "bytes"))
        head.headers.append(("Cache-Control", "no-store"))
        let headData = HTTPHeadParser.serialize(response: head, bodyLength: end - span.start, keepAlive: false)
        try await channel.writeAndFlush(ByteBuffer(bytes: [UInt8](headData))).get()

        try await write(probeBody, to: channel)

        let served = Int64(probeBody.count)
        let remaining = ByteSpan(start: span.start + served, end: end)
        // Spread the rest over all connections instead of hammering a couple of
        // sockets on medium-sized files.
        let chunkSize = Self.adaptiveChunkSize(remaining: remaining.length, config: config)
        let planner = RangePlanner(chunkSize: chunkSize, maxConcurrency: config.concurrency)
        let chunks = remaining.length > 0 ? planner.chunks(for: remaining) : []

        var next = 0
        var window: [Task<Data, Error>] = []
        let inFlight = max(1, config.concurrency - 1)
        while next < chunks.count && window.count < inFlight {
            window.append(fetchTask(request, span: chunks[next], candidates: candidates, preferred: winner))
            next += 1
        }
        while !window.isEmpty {
            let task = window.removeFirst()
            let data: Data
            do {
                data = try await task.value
            } catch {
                window.forEach { $0.cancel() }
                throw error
            }
            try await write(data, to: channel)
            if next < chunks.count {
                window.append(fetchTask(request, span: chunks[next], candidates: candidates, preferred: winner))
                next += 1
            }
        }
        config.log("accelerated \(host) via \(winner) \(span.start + served)B+ \(chunks.count) chunks")
        config.onEvent?(.accelerated(host: host, chunks: chunks.count))
        try? await channel.close().get()
    }

    /// Races the mirror hosts for the first chunk and keeps the fastest.
    /// Deliberately unstructured: a structured task group would wait for every
    /// straggler (up to the connection timeout) before returning.
    private func probe(_ request: HTTPRequestHead,
                       span: ByteSpan,
                       candidates: [String],
                       preferred: String?) async throws -> (HTTPResponseHead, Data, String) {
        if let preferred, candidates.contains(preferred),
           let result = try? await fetch(request, span: span, host: preferred, timeout: 8) {
            return (result.0, result.1, preferred)
        }

        let started = Date()
        return try await withCheckedThrowingContinuation { continuation in
            let box = MirrorRaceBox(count: candidates.count, continuation: continuation)
            for candidate in candidates {
                Task { [self] in
                    do {
                        let (head, body) = try await fetch(request, span: span, host: candidate, timeout: 8)
                        box.succeed(host: candidate, head: head, body: body)
                    } catch {
                        let ms = Int(Date().timeIntervalSince(started) * 1000)
                        config.log("probe fail \(candidate) \(ms)ms")
                        box.fail(error)
                    }
                }
            }
        }
    }

    static func adaptiveChunkSize(remaining: Int64, config: MITMProxy.Configuration) -> Int64 {
        let minimum: Int64 = 256 << 10
        guard remaining > 0 else { return config.chunkSize }
        let perConnection = remaining / Int64(max(1, config.concurrency))
        return max(minimum, min(config.chunkSize, perConnection))
    }

    private func write(_ data: Data, to channel: Channel) async throws {
        guard !data.isEmpty else { return }
        try await channel.writeAndFlush(ByteBuffer(bytes: data)).get()
    }

    private func fetchTask(_ request: HTTPRequestHead,
                           span: ByteSpan,
                           candidates: [String],
                           preferred: String?) -> Task<Data, Error> {
        Task { [self] in
            try await fetchAny(request, span: span, candidates: candidates, preferred: preferred)
        }
    }

    /// Chunks go to the winning mirror first; if it starts failing, the other
    /// mirrors take over.
    private func fetchAny(_ request: HTTPRequestHead,
                          span: ByteSpan,
                          candidates: [String],
                          preferred: String?) async throws -> Data {
        var ordered: [String] = []
        if let preferred { ordered.append(preferred) }
        ordered.append(contentsOf: candidates.filter { $0 != preferred })
        var lastError: Error?
        for candidate in ordered {
            do {
                return try await fetch(request, span: span, host: candidate).1
            } catch {
                lastError = error
            }
        }
        throw lastError ?? UpstreamClient.Failure.http("no mirror available")
    }

    private func fetch(_ request: HTTPRequestHead, span: ByteSpan, host: String, timeout: TimeInterval = 15) async throws -> (HTTPResponseHead, Data) {
        let client = try await UpstreamClient.open(host: host,
                                                   port: port,
                                                   timeout: timeout,
                                                   trustRootDER: config.upstreamTrustRootDER)
        defer { client.cancel() }
        try await client.send(Self.requestData(request, host: host, range: span, close: true))
        let stream = ResponseStream(client: client)
        let head = try await stream.readHead()
        guard head.status == 206 else {
            throw UpstreamClient.Failure.http("expected 206, got \(head.status)")
        }
        guard let length = Int(head.header("Content-Length") ?? ""), length > 0 else {
            throw UpstreamClient.Failure.http("chunk without Content-Length")
        }
        let body = try await stream.readExactly(length)
        return (head, body)
    }

    static func requestData(_ request: HTTPRequestHead, host: String, range: ByteSpan?, close: Bool) -> Data {
        let drop: Set<String> = ["range", "connection", "proxy-connection", "accept-encoding", "keep-alive", "te", "upgrade", "host"]
        var text = "\(request.method) \(request.path) HTTP/1.1\r\n"
        for header in request.headers {
            let lower = header.name.lowercased()
            if drop.contains(lower) { continue }
            text += "\(header.name): \(header.value)\r\n"
        }
        text += "Host: \(host)\r\n"
        text += "Accept-Encoding: identity\r\n"
        if let range { text += "Range: \(range.headerValue)\r\n" }
        text += "Connection: \(close ? "close" : "keep-alive")\r\n\r\n"
        return Data(text.utf8)
    }
}

extension FrontDoorHandler: RemovableChannelHandler {
    func removeHandler(context: ChannelHandlerContext, removalToken: ChannelHandlerContext.RemovalToken) {
        context.leavePipeline(removalToken: removalToken)
    }
}


private final class MirrorRaceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var remaining: Int
    private let continuation: CheckedContinuation<(HTTPResponseHead, Data, String), Error>

    init(count: Int, continuation: CheckedContinuation<(HTTPResponseHead, Data, String), Error>) {
        self.remaining = count
        self.continuation = continuation
    }

    func succeed(host: String, head: HTTPResponseHead, body: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        lock.unlock()
        continuation.resume(returning: (head, body, host))
    }

    func fail(_ error: Error) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        remaining -= 1
        let exhausted = remaining == 0
        if exhausted { finished = true }
        lock.unlock()
        if exhausted { continuation.resume(throwing: error) }
    }
}

