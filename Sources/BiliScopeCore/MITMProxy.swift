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
    case accelerated(host: String, chunks: Int, bytes: Int64)
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
        /// Opt-in troubleshooting: also log hosts that are not Bilibili at all.
        /// Off by default so normal logs never contain other apps' traffic.
        public var logForeignHosts: Bool
        /// CONNECT ports whose tunnels may carry plain HTTP instead of TLS.
        public var plainHTTPConnectPorts: Set<Int>
        /// Where plain-HTTP media requests are fetched over TLS. Only tests change it.
        public var mediaUpstreamPort: UInt16
        /// A download that delivers nothing for this long is abandoned for another mirror.
        public var stallTimeout: TimeInterval
        /// How long the player waits on a block before a second mirror joins in.
        public var hedgeDelay: TimeInterval
        /// How many media files keep a read-ahead window at once. Each holds
        /// about `concurrency` blocks, so this bounds memory (a Network Extension
        /// is killed at roughly 50 MB).
        public var maxSessions: Int
        /// IPv4 prefixes (like `"203.119."`) of HTTPDNS servers. Their plain-HTTP
        /// answers for media hosts are rewritten to `httpDNSAnswer`; any other
        /// port to them is refused, because it cannot be rewritten.
        public var httpDNSPrefixes: [String]
        /// An address inside the packet tunnel. Connections to it carry the real
        /// host name only in their `Host` header or TLS server name.
        public var httpDNSAnswer: String?
        /// The HTTPDNS port. Only tests change it.
        public var httpDNSPort: Int
        public var log: @Sendable (String) -> Void
        public var onEvent: (@Sendable (TrafficEvent) -> Void)?

        public init(bindHost: String = "127.0.0.1",
                    port: UInt16 = 8888,
                    concurrency: Int = 8,
                    chunkSize: Int64 = 1 << 20,
                    allowedClients: ClientAllowlist = ClientAllowlist(),
                    upstreamTrustRootDER: Data? = nil,
                    logForeignHosts: Bool = false,
                    plainHTTPConnectPorts: Set<Int> = [80],
                    mediaUpstreamPort: UInt16 = 443,
                    stallTimeout: TimeInterval = 4,
                    hedgeDelay: TimeInterval = 1.5,
                    maxSessions: Int = 4,
                    httpDNSPrefixes: [String] = [],
                    httpDNSAnswer: String? = nil,
                    httpDNSPort: Int = 80,
                    log: @escaping @Sendable (String) -> Void = { _ in },
                    onEvent: (@Sendable (TrafficEvent) -> Void)? = nil) {
            self.bindHost = bindHost
            self.port = port
            self.concurrency = concurrency
            self.chunkSize = chunkSize
            self.allowedClients = allowedClients
            self.upstreamTrustRootDER = upstreamTrustRootDER
            self.logForeignHosts = logForeignHosts
            self.plainHTTPConnectPorts = plainHTTPConnectPorts
            self.mediaUpstreamPort = mediaUpstreamPort
            self.stallTimeout = stallTimeout
            self.hedgeDelay = hedgeDelay
            self.maxSessions = maxSessions
            self.httpDNSPrefixes = httpDNSPrefixes
            self.httpDNSAnswer = httpDNSAnswer
            self.httpDNSPort = httpDNSPort
            self.log = log
            self.onEvent = onEvent
        }
    }

    private let group: MultiThreadedEventLoopGroup
    private let ca: CertificateAuthority
    private let policy: HostPolicy
    private let config: Configuration
    private let material: TLSMaterial
    private let sessions: MediaSessionStore
    private let relays = RelayGuard()
    private var server: Channel?

    public init(ca: CertificateAuthority,
                policy: HostPolicy = HostPolicy(),
                config: Configuration = Configuration()) {
        self.ca = ca
        self.policy = policy
        self.config = config
        self.material = TLSMaterial(ca: ca)
        self.sessions = MediaSessionStore(limit: config.maxSessions)
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
            .childChannelInitializer { [material, policy, config, sessions, relays] channel in
                channel.pipeline.addHandler(
                    FrontDoorHandler(material: material, policy: policy, config: config, sessions: sessions, relays: relays)
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
    private let sessions: MediaSessionStore
    private let relays: RelayGuard
    private var relayKey: String?

    private var buffer = Data()
    private var decided = false
    private var upstream: UpstreamClient?
    private var sendTail: Task<Void, Never>?
    /// What tells the client its tunnel is open: the HTTP CONNECT answer, or
    /// the SOCKS5 success reply when the packet tunnel connects through SOCKS5.
    private var connectReply = [UInt8]("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)
    private var socks: SocksState?

    private enum SocksState { case greeting, request }
    private var pendingConnect: (host: String, port: Int, route: HostRoute)?
    private let allowlist: ClientAllowlist

    init(material: TLSMaterial, policy: HostPolicy, config: MITMProxy.Configuration, sessions: MediaSessionStore, relays: RelayGuard) {
        self.relays = relays
        self.material = material
        self.policy = policy
        self.config = config
        self.sessions = sessions
        self.allowlist = config.allowedClients
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

        if upstream != nil {
            flushUpstream()
            return
        }
        if let pending = pendingConnect {
            routeTunnel(context: context, pending: pending)
            return
        }
        guard !decided else { return }

        if socks != nil || buffer.first == Socks5.version {
            readSocks(context: context)
            return
        }

        guard let (request, headEnd) = HTTPHeadParser.parseRequest(buffer) else {
            if buffer.count > HTTPHeadParser.maxHeadSize {
                context.close(promise: nil)
            }
            return
        }
        decided = true
        buffer.removeFirst(headEnd)

        guard request.method == "CONNECT" else {
            // With the system proxy on, every plain-HTTP request on the device
            // arrives here in absolute form, so all of them have to keep working.
            guard let url = URL(string: request.target), let host = url.host else {
                respond(context, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                return
            }
            let route = policy.route(for: host)
            if route == .accelerate, url.port == nil, request.method == "GET" {
                startPlainMedia(context: context, request: request, host: HostPolicy.normalize(host))
            } else {
                startPlainRelay(context: context, request: request, host: host, port: url.port ?? 80, route: route)
            }
            return
        }

        let target = request.target
        establish(context: context, host: HostPolicy.normalize(target), port: Self.port(from: target))
    }

    /// SOCKS5 is how the packet tunnel hands over connections: the no-auth
    /// greeting, then one CONNECT whose target is usually a domain name, because
    /// the tunnel answers DNS with mapped addresses and keeps the names.
    private func readSocks(context: ChannelHandlerContext) {
        if socks == nil { socks = .greeting }
        if socks == .greeting {
            guard buffer.count >= 2, buffer.count >= 2 + Int(buffer[buffer.startIndex + 1]) else { return }
            buffer.removeFirst(2 + Int(buffer[buffer.startIndex + 1]))
            context.writeAndFlush(NIOAny(ByteBuffer(bytes: [Socks5.version, 0x00])), promise: nil)
            socks = .request
        }
        switch Socks5.parseRequest(buffer) {
        case .incomplete:
            return
        case .invalid:
            context.close(promise: nil)
        case .unsupported(let length):
            // Only CONNECT: refusing UDP ASSOCIATE right away makes QUIC fall back
            // to TCP, which is the only path this proxy accelerates.
            buffer.removeFirst(length)
            respond(context, Socks5.reply(0x07))
        case .connect(let host, let port, let length):
            buffer.removeFirst(length)
            decided = true
            socks = nil
            connectReply = Socks5.reply(0x00)
            establish(context: context, host: HostPolicy.normalize(host), port: port)
        }
    }

    private func isHTTPDNS(_ host: String) -> Bool {
        HostPolicy.isIPAddress(host) && config.httpDNSPrefixes.contains(where: host.hasPrefix)
    }

    private func isSentinel(_ host: String) -> Bool {
        config.httpDNSAnswer == host
    }

    private func establish(context: ChannelHandlerContext, host: String, port: Int) {
        // An out-of-range port would trap where it becomes a UInt16 later.
        guard Self.validPorts.contains(port) else {
            config.log("refused \(host):\(port), invalid port")
            context.close(promise: nil)
            return
        }
        let route = policy.route(for: host)
        let bareIPOverTLS = HostPolicy.isIPAddress(host) && port == 443
        let httpDNSLookup = isHTTPDNS(host) && port == config.httpDNSPort
        if route == .accelerate || bareIPOverTLS || isSentinel(host) || httpDNSLookup || config.plainHTTPConnectPorts.contains(port) {
            // VPN-style clients send CONNECT for plaintext connections too, often
            // to a bare IP, so the first bytes decide what this tunnel really is.
            pendingConnect = (host, port, route)
            context.channel.writeAndFlush(ByteBuffer(bytes: connectReply), promise: nil)
            if !buffer.isEmpty { routeTunnel(context: context, pending: (host, port, route)) }
        } else {
            startRelay(context: context, host: host, port: port, route: route)
        }
    }

    private func routeTunnel(context: ChannelHandlerContext, pending: (host: String, port: Int, route: HostRoute)) {
        guard let first = buffer.first else { return }
        let tlsHandshakeRecord: UInt8 = 0x16
        if first == tlsHandshakeRecord {
            // The server name sits in the ClientHello, which may arrive in pieces:
            // decide only once the whole first record is here.
            if buffer.count >= 5 {
                let recordLength = Int(buffer[buffer.startIndex + 3]) << 8 | Int(buffer[buffer.startIndex + 4])
                if buffer.count < 5 + recordLength, buffer.count < 16 << 10 { return }
            } else {
                return
            }
            pendingConnect = nil
            let serverName = TLSClientHello.serverName(in: buffer).map(HostPolicy.normalize)
            logBareIP(pending, name: serverName)
            if pending.route == .accelerate {
                startMITM(context: context, host: pending.host, port: pending.port, announce: false)
            } else if HostPolicy.isIPAddress(pending.host), let serverName, policy.route(for: serverName) == .accelerate {
                startMITM(context: context, host: serverName, port: pending.port, announce: false)
            } else if isSentinel(pending.host) {
                // Nothing listens at the tunnel address: relay by name, or give up.
                if let serverName {
                    startRelay(context: context, host: serverName, port: pending.port, route: policy.route(for: serverName), announce: false)
                } else {
                    context.close(promise: nil)
                }
            } else {
                startRelay(context: context, host: pending.host, port: pending.port, route: pending.route, announce: false)
            }
            return
        }
        let looksLikeHTTP = first >= UInt8(ascii: "A") && first <= UInt8(ascii: "Z")
        if looksLikeHTTP, config.plainHTTPConnectPorts.contains(pending.port) || isSentinel(pending.host)
            || (isHTTPDNS(pending.host) && pending.port == config.httpDNSPort) {
            guard let (request, headEnd) = HTTPHeadParser.parseRequest(buffer) else {
                if buffer.count > HTTPHeadParser.maxHeadSize { context.close(promise: nil) }
                return
            }
            // Only lookups are rewritten; any other request to these networks,
            // from any app, is relayed as it came.
            if isHTTPDNS(pending.host), pending.port == config.httpDNSPort, Self.isHTTPDNSLookup(request) {
                pendingConnect = nil
                buffer.removeFirst(headEnd)
                rewriteHTTPDNS(channel: context.channel, request: request, address: pending.host)
                return
            }
            let target = request.header("Host").map(HostPolicy.normalize) ?? pending.host
            logBareIP(pending, name: target)
            if request.method == "GET", policy.route(for: target) == .accelerate {
                pendingConnect = nil
                config.log("mitm http tunnel \(target)")
                installPlainMedia(on: context.channel, host: target)
                return
            }
            if isSentinel(pending.host), !HostPolicy.isIPAddress(target) {
                pendingConnect = nil
                startRelay(context: context, host: target, port: pending.port, route: policy.route(for: target), announce: false)
                return
            }
        }
        pendingConnect = nil
        if isSentinel(pending.host) {
            context.close(promise: nil)
            return
        }
        startRelay(context: context, host: pending.host, port: pending.port, route: pending.route, announce: false)
    }

    /// Alibaba Cloud HTTPDNS lookups: `/{account}/d?`, `/resolve?` and their
    /// signed `sign_` forms.
    static func isHTTPDNSLookup(_ request: HTTPRequestHead) -> Bool {
        guard request.method == "GET" else { return false }
        let path = request.path
        return ["/d?", "/resolve?", "/sign_d?", "/sign_resolve?"].contains { path.contains($0) }
    }

    /// Fetches the real HTTPDNS answer and points media hosts at the tunnel. Any
    /// failure returns the original answer: unaccelerated beats a stalled player.
    private func rewriteHTTPDNS(channel: Channel, request: HTTPRequestHead, address: String) {
        guard let answer = config.httpDNSAnswer else {
            channel.close(promise: nil)
            return
        }
        let config = self.config, policy = self.policy
        Task {
            var original = Data()
            do {
                let client = try await UpstreamClient.openTCP(host: address, port: UInt16(config.httpDNSPort))
                defer { client.cancel() }
                // A stalled HTTPDNS server must not hold the player's lookup forever.
                let deadline = Task {
                    try await Task.sleep(nanoseconds: 8_000_000_000)
                    client.cancel()
                }
                defer { deadline.cancel() }
                // HTTP/1.0 with no Accept-Encoding: an identity body, never chunked.
                let skip: Set<String> = ["accept-encoding", "connection", "proxy-connection", "keep-alive"]
                var head = "\(request.method) \(request.path) HTTP/1.0\r\n"
                for header in request.headers where !skip.contains(header.name.lowercased()) {
                    head += "\(header.name): \(header.value)\r\n"
                }
                head += "Connection: close\r\n\r\n"
                try await client.send(Data(head.utf8))
                while let chunk = try await client.receive() {
                    original.append(chunk)
                    // Answers are a few KB; anything this large is not one to rewrite.
                    guard original.count < 512 << 10 else { throw UpstreamClient.Failure.http("answer too large") }
                }
            } catch {
                config.log("httpdns \(address) failed: \(error)")
                try? await channel.close().get()
                return
            }
            var reply = original
            if let (head, end) = HTTPHeadParser.parseResponse(original) {
                let body = original.subdata(in: original.startIndex + end..<original.endIndex)
                if let (rewritten, hosts) = HTTPDNSRewriter.rewrite(body, answer: answer,
                                                                   isMedia: { policy.route(for: $0) == .accelerate }) {
                    if !hosts.isEmpty {
                        var out = HTTPResponseHead(status: head.status, reason: head.reason, headers: head.headers.filter {
                            !["content-length", "transfer-encoding", "connection"].contains($0.name.lowercased())
                        })
                        out.headers.append(("Connection", "close"))
                        reply = HTTPHeadParser.serialize(response: out, bodyLength: Int64(rewritten.count), keepAlive: false) + rewritten
                        config.log("httpdns rewrote \(hosts.joined(separator: ","))")
                    }
                } else {
                    config.log("httpdns \(address) unparsed: \(String(decoding: body.prefix(160), as: UTF8.self))")
                }
            }
            try? await channel.writeAndFlush(ByteBuffer(bytes: reply)).get()
            try? await channel.close().get()
        }
    }

    /// Connections to a bare IP skip DNS, so the packet tunnel's split DNS never
    /// sees them. Logging what they carry shows how much traffic that leaves out.
    private func logBareIP(_ pending: (host: String, port: Int, route: HostRoute), name: String?) {
        guard HostPolicy.isIPAddress(pending.host) else { return }
        let named = name.map { policy.isBilibili($0) ? $0 : (config.logForeignHosts ? $0 : "non-Bilibili") } ?? "unknown"
        guard policy.isBilibili(name ?? "") || config.logForeignHosts else { return }
        config.log("bare ip \(pending.host):\(pending.port) carries \(named)")
    }

    private func startMITM(context: ChannelHandlerContext, host: String, port: Int, announce: Bool = true) {
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
        if announce {
            channel.writeAndFlush(ByteBuffer(bytes: connectReply), promise: promise)
        } else {
            promise.succeed(())
        }
        // NIOSSLServerHandler is not Sendable, which NIO 2.8 warns about when
        // adding it from a closure. It is only ever touched on this channel's
        // event loop, so the warning is benign.
        let tlsHandler = NIOSSLServerHandler(context: sslContext)
        promise.futureResult.flatMap { _ in
            channel.pipeline.addHandler(tlsHandler)
        }.flatMap { _ in
            channel.pipeline.addHandler(MediaHandler(host: host, port: UInt16(port), config: self.config, sessions: self.sessions))
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

    /// Media CDNs also serve the same signed paths over TLS, so a plain-HTTP
    /// media request gets the same acceleration, with TLS on the upstream side.
    private func startPlainMedia(context: ChannelHandlerContext, request: HTTPRequestHead, host: String) {
        buffer.insert(contentsOf: Self.originFormHead(request, connection: nil), at: buffer.startIndex)
        config.log("mitm http \(host)")
        installPlainMedia(on: context.channel, host: host)
    }

    private func installPlainMedia(on channel: Channel, host: String) {
        channel.pipeline.addHandler(MediaHandler(host: host, port: config.mediaUpstreamPort, config: config, sessions: sessions)).flatMap { _ in
            channel.pipeline.removeHandler(self)
        }.whenComplete { result in
            switch result {
            case .success:
                self.firePending(on: channel)
            case .failure(let error):
                self.config.log("http media setup failed for \(host): \(error)")
                channel.close(promise: nil)
            }
        }
    }

    private static func originFormHead(_ request: HTTPRequestHead, connection: String?) -> Data {
        let hopByHop: Set<String> = ["proxy-connection", "connection", "keep-alive"]
        var text = "\(request.method) \(request.path) HTTP/1.1\r\n"
        for header in request.headers where !hopByHop.contains(header.name.lowercased()) {
            text += "\(header.name): \(header.value)\r\n"
        }
        if let connection { text += "Connection: \(connection)\r\n" }
        text += "\r\n"
        return Data(text.utf8)
    }

    /// A last line of defence: a relay loop shows up as one target piling up connections.
    private func acquireRelay(context: ChannelHandlerContext, host: String, port: Int) -> Bool {
        let key = "\(host):\(port)"
        guard relays.acquire(key) else {
            config.log("relay refused, possible loop: \(relays.isBilibiliSafeLabel(host, policy: policy))")
            context.close(promise: nil)
            return false
        }
        relayKey = key
        return true
    }

    private func startPlainRelay(context: ChannelHandlerContext, request: HTTPRequestHead, host: String, port: Int, route: HostRoute) {
        guard acquireRelay(context: context, host: host, port: port) else { return }
        openRelay(channel: context.channel, host: host, port: port,
                  head: Self.originFormHead(request, connection: "close")) {
            if route == .blindTunnel {
                self.config.log("tunnel http \(host)")
                self.config.onEvent?(.tunnel(host: host))
            } else if self.config.logForeignHosts {
                self.config.log("pass http \(host)")
            }
        }
    }

    private func startRelay(context: ChannelHandlerContext, host: String, port: Int, route: HostRoute, announce: Bool = true) {
        guard acquireRelay(context: context, host: host, port: port) else { return }
        if announce {
            context.channel.writeAndFlush(ByteBuffer(bytes: connectReply), promise: nil)
        }
        openRelay(channel: context.channel, host: host, port: port, head: nil) {
            // Never log foreign hostnames: the proxy is a pass-through for
            // those and the user should not see other apps' traffic in the log.
            if route == .blindTunnel {
                self.config.log("tunnel \(host)")
                self.config.onEvent?(.tunnel(host: host))
            } else if self.config.logForeignHosts {
                self.config.log("pass \(host):\(port)")
            }
        }
    }

    /// Relays leave on the same path rules as media downloads, so a VPN client
    /// cannot capture them and hand them straight back to this proxy.
    private func openRelay(channel: Channel, host: String, port: Int, head: Data?, opened: @escaping () -> Void) {
        let loop = channel.eventLoop
        let label = policy.isBilibili(host) || config.logForeignHosts ? host : "non-Bilibili host"
        Task {
            do {
                let client = try await UpstreamClient.openTCP(host: host, port: UInt16(port))
                defer { client.cancel() }
                if let head { try await client.send(head) }
                loop.execute {
                    guard channel.isActive else { client.cancel(); return }
                    self.upstream = client
                    opened()
                    self.flushUpstream()
                }
                while let chunk = try await client.receive() {
                    try await channel.writeAndFlush(ByteBuffer(bytes: chunk)).get()
                }
            } catch {
                self.config.log("relay failed for \(label): \(error)")
            }
            channel.close(promise: nil)
        }
    }

    /// Sends what the client has written so far, in order.
    private func flushUpstream() {
        guard let upstream, !buffer.isEmpty else { return }
        let pending = buffer
        buffer.removeAll(keepingCapacity: false)
        let previous = sendTail
        sendTail = Task {
            await previous?.value
            try? await upstream.send(pending)
        }
    }

    private func firePending(on channel: Channel) {
        guard !buffer.isEmpty else { return }
        let pending = buffer
        buffer.removeAll(keepingCapacity: false)
        channel.pipeline.fireChannelRead(ByteBuffer(bytes: pending))
    }

    private func respond(_ context: ChannelHandlerContext, _ text: String) {
        respond(context, [UInt8](text.utf8))
    }

    private func respond(_ context: ChannelHandlerContext, _ bytes: [UInt8]) {
        context.writeAndFlush(NIOAny(ByteBuffer(bytes: bytes)), promise: nil)
        context.close(promise: nil)
    }

    private static func port(from target: String) -> Int {
        guard let colon = target.lastIndex(of: ":") else { return 443 }
        let text = target[target.index(after: colon)...]
        return Int(text) ?? 443
    }

    private static let validPorts = 1...65535

    func channelInactive(context: ChannelHandlerContext) {
        if let relayKey { relays.release(relayKey) }
        relayKey = nil
        upstream?.cancel()
        upstream = nil
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        upstream?.cancel()
        context.close(promise: nil)
    }
}

// MARK: - Blind relay

final class RelayGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var active: [String: Int] = [:]
    private let limit: Int

    init(limit: Int = 64) {
        self.limit = limit
    }

    func acquire(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard active[key, default: 0] < limit else { return false }
        active[key, default: 0] += 1
        return true
    }

    func release(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let count = active[key] else { return }
        active[key] = count > 1 ? count - 1 : nil
    }

    /// Other apps' host names stay out of the log unless they asked for it.
    func isBilibiliSafeLabel(_ host: String, policy: HostPolicy) -> String {
        policy.isBilibili(host) ? host : "non-Bilibili host"
    }
}

// MARK: - Media (MITM) handler

final class MediaHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let host: String
    private let port: UInt16
    private let config: MITMProxy.Configuration
    private let sessions: MediaSessionStore
    private var buffer = Data()
    private var busy = false
    private var headSent = false

    init(host: String, port: UInt16, config: MITMProxy.Configuration, sessions: MediaSessionStore) {
        self.host = host
        self.port = port
        self.config = config
        self.sessions = sessions
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // Clients that drop the connection mid-handshake (health checks, user
        // cancels) are routine; do not spam the in-app log with them.
        let text = String(describing: error)
        if !text.contains("EOF during handshake") {
            config.log("tls/http error \(host): \(error)")
        }
        context.close(promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        if let bytes = incoming.readBytes(length: incoming.readableBytes) {
            buffer.append(contentsOf: bytes)
        }
        // One request per connection, and its body is never forwarded: bytes piling
        // up here would only eat the tunnel's memory.
        if buffer.count > HTTPHeadParser.maxHeadSize * 4 {
            context.close(promise: nil)
            return
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
        // Our own upstream request came back through a VPN client: answering it
        // here stops the loop at one hop instead of letting it multiply.
        guard request.header(Self.hopHeader) == nil else {
            config.log("loop detected \(host): upstream request returned to the proxy")
            try await channel.writeAndFlush(ByteBuffer(string: "HTTP/1.1 508 Loop Detected\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")).get()
            try? await channel.close().get()
            return
        }
        guard request.method == "GET",
              let rangeHeader = request.header("Range"),
              let span = RangeHeader.parse(rangeHeader) else {
            try await forward(request, channel: channel)
            return
        }
        do {
            try await accelerate(request, span: span, channel: channel)
        } catch UpstreamClient.Failure.unexpectedStatus(let status) where !headSent {
            // Not everything under these domains speaks Range: an error page or a
            // whole-file answer belongs to the player, which knows what it asked for.
            config.log("passing through HTTP \(status) from \(host)")
            try await forward(request, channel: channel)
        }
    }

    private func forward(_ request: HTTPRequestHead, channel: Channel) async throws {
        let client = try await UpstreamClient.open(host: host, port: port, trustRootDER: config.upstreamTrustRootDER)
        defer { client.cancel() }
        InterfaceLog.note(client.interfaceName, config: config)
        let data = Self.requestData(request, host: host, range: nil, close: true)
        try await client.send(data)
        var transferred = 0
        while let chunk = try await client.receive() {
            transferred += chunk.count
            try await channel.writeAndFlush(ByteBuffer(bytes: chunk)).get()
        }
        // The query holds the media signature, which must never reach a shared log.
        let path = request.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        config.log("forward \(host)\(path.prefix(80)) \(transferred)B")
        try? await channel.close().get()
    }

    private func accelerate(_ request: HTTPRequestHead, span: ByteSpan, channel: Channel) async throws {
        let started = Date()
        let session = await sessions.session(for: request, host: host, port: port, config: config)
        let size = session.blockLength
        let first = try await session.block(span.start / size, rankingFrom: span.start)
        let total = first.total
        let end = span.end == .max ? total : min(span.end, total)
        guard end > span.start else { throw UpstreamClient.Failure.http("empty range") }

        var head = HTTPResponseHead(status: 206, reason: "Partial Content", headers: [])
        head.headers.append(("Content-Range", "bytes \(span.start)-\(end - 1)/\(total)"))
        head.headers.append(("Content-Type", first.contentType ?? "application/octet-stream"))
        head.headers.append(("Accept-Ranges", "bytes"))
        head.headers.append(("Cache-Control", "no-store"))
        let headData = HTTPHeadParser.serialize(response: head, bodyLength: end - span.start, keepAlive: false)
        headSent = true
        try await channel.writeAndFlush(ByteBuffer(bytes: [UInt8](headData))).get()

        var offset = span.start
        var used = 0
        while offset < end {
            let index = offset / size
            await session.advance(to: index)
            let block = try await session.block(index, rankingFrom: offset)
            let from = Int(offset - index * size)
            let to = min(block.data.count, Int(end - index * size))
            guard from < to else { throw UpstreamClient.Failure.closed }
            try await write(block.data.subdata(in: from..<to), to: channel)
            offset += Int64(to - from)
            used += 1
        }
        let via = await session.bestHost
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        config.log("accelerated \(host) via \(via) \(span.start)-\(end - 1)/\(total) \((end - span.start) >> 10)KB \(ms)ms \(used) blocks")
        config.onEvent?(.accelerated(host: host, chunks: used, bytes: end - span.start))
        try? await channel.close().get()
    }

    private func write(_ data: Data, to channel: Channel) async throws {
        guard !data.isEmpty else { return }
        try await channel.writeAndFlush(ByteBuffer(bytes: data)).get()
    }

    static let hopHeader = "X-BiliScope-Hop"

    static func requestData(_ request: HTTPRequestHead, host: String, range: ByteSpan?, close: Bool) -> Data {
        // With no range of our own, the client's Range header goes through untouched.
        let drop: Set<String> = [range == nil ? "" : "range", "connection", "proxy-connection", "accept-encoding", "keep-alive", "te", "upgrade", "host"]
        var text = "\(request.method) \(request.path) HTTP/1.1\r\n"
        for header in request.headers {
            let lower = header.name.lowercased()
            if drop.contains(lower) { continue }
            text += "\(header.name): \(header.value)\r\n"
        }
        text += "Host: \(host)\r\n"
        text += "\(hopHeader): 1\r\n"
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

// MARK: - SOCKS5

enum Socks5 {
    static let version: UInt8 = 0x05

    enum Request: Equatable {
        case incomplete
        case invalid
        /// A command other than CONNECT; `length` is the request's size.
        case unsupported(length: Int)
        case connect(host: String, port: Int, length: Int)
    }

    /// Parses `VER CMD RSV ATYP ADDR PORT` (RFC 1928, section 4).
    static func parseRequest(_ data: Data) -> Request {
        let bytes = [UInt8](data.prefix(262))
        guard bytes.count >= 5 else { return .incomplete }
        guard bytes[0] == version else { return .invalid }
        let host: String
        let addressEnd: Int
        switch bytes[3] {
        case 0x01:
            addressEnd = 8
            guard bytes.count >= addressEnd else { return .incomplete }
            host = bytes[4..<8].map(String.init).joined(separator: ".")
        case 0x03:
            let length = Int(bytes[4])
            addressEnd = 5 + length
            guard length > 0 else { return .invalid }
            guard bytes.count >= addressEnd else { return .incomplete }
            guard let name = String(bytes: bytes[5..<addressEnd], encoding: .utf8) else { return .invalid }
            host = name
        case 0x04:
            addressEnd = 20
            guard bytes.count >= addressEnd else { return .incomplete }
            var raw = in6_addr()
            withUnsafeMutableBytes(of: &raw) { $0.copyBytes(from: bytes[4..<20]) }
            var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &raw, &text, socklen_t(text.count)) != nil else { return .invalid }
            host = "[" + String(cString: text) + "]"
        default:
            return .invalid
        }
        guard bytes.count >= addressEnd + 2 else { return .incomplete }
        let port = Int(bytes[addressEnd]) << 8 | Int(bytes[addressEnd + 1])
        let length = addressEnd + 2
        return bytes[1] == 0x01 ? .connect(host: host, port: port, length: length) : .unsupported(length: length)
    }

    /// A reply with a zero IPv4 bind address, which clients ignore.
    static func reply(_ status: UInt8) -> [UInt8] {
        [version, status, 0x00, 0x01, 0, 0, 0, 0, 0, 0]
    }
}

