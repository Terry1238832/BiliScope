import Foundation
import Network
import Security

/// Thin async wrapper around `NWConnection` used for upstream requests.
///
/// Deliberately *not* `URLSession`: URLSession honours the system HTTP proxy,
/// which is this very proxy, and would recurse. Raw connections also let us
/// speak plain HTTP/1.1 with an explicit `Range` header.
public final class UpstreamClient: @unchecked Sendable {
    public enum Failure: Error {
        case timedOut
        case closed
        case tls
        case http(String)
    }

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var cancelled = false

    public static func open(host: String,
                            port: UInt16 = 443,
                            timeout: TimeInterval = 15,
                            trustRootDER: Data? = nil) async throws -> UpstreamClient {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)

        if let trustRootDER, let anchor = SecCertificateCreateWithData(nil, trustRootDER as CFData) {
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, secTrust, complete in
                let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
                SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
                SecTrustSetAnchorCertificatesOnly(trust, true)
                var error: CFError?
                complete(SecTrustEvaluateWithError(trust, &error))
            }, DispatchQueue(label: "com.biliscope.upstream.verify"))
        }

        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = Int(timeout)
        tcp.noDelay = true

        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        // "localhost" may resolve to ::1 first, while our loopback listeners
        // are IPv4-only. Keep the TLS server name but dial 127.0.0.1.
        let endpointHost = host == "localhost" ? "127.0.0.1" : host
        let client = UpstreamClient(connection: NWConnection(host: NWEndpoint.Host(endpointHost),
                                                             port: NWEndpoint.Port(rawValue: port)!,
                                                             using: parameters))
        try await client.start(timeout: timeout)
        return client
    }

    private init(connection: NWConnection) {
        self.connection = connection
        self.queue = DispatchQueue(label: "com.biliscope.upstream", qos: .userInitiated)
    }

    private func start(timeout: TimeInterval) async throws {
        final class Box: @unchecked Sendable {
            var resumed = false
            let lock = NSLock()
            func once(_ body: () -> Void) {
                lock.lock(); defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                body()
            }
        }
        let box = Box()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    box.once { continuation.resume() }
                case .failed(let error):
                    box.once { continuation.resume(throwing: error) }
                case .cancelled:
                    box.once { continuation.resume(throwing: Failure.closed) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                box.once { continuation.resume(throwing: Failure.timedOut) }
            }
        }
    }

    public func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    /// Returns the next chunk of application data, or `nil` at end of stream.
    public func receive(maxLength: Int = 128 * 1024) async throws -> Data? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maxLength) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                    return
                }
                if isComplete {
                    continuation.resume(returning: nil)
                    return
                }
                // No data and not complete: ask again.
                self.connection.receive(minimumIncompleteLength: 1, maximumLength: maxLength) { data, _, isComplete, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let data, !data.isEmpty {
                        continuation.resume(returning: data)
                    } else if isComplete {
                        continuation.resume(returning: nil)
                    } else {
                        continuation.resume(throwing: Failure.closed)
                    }
                }
            }
        }
    }

    public func cancel() {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        cancelled = true
        lock.unlock()
        connection.cancel()
    }
}

/// Buffered HTTP/1.1 response reader on top of `UpstreamClient`.
public final class ResponseStream {
    private let client: UpstreamClient
    private var buffer = Data()

    public init(client: UpstreamClient) {
        self.client = client
    }

    public func readHead() async throws -> HTTPResponseHead {
        while HTTPHeadParser.parseResponse(buffer) == nil {
            guard buffer.count < HTTPHeadParser.maxHeadSize else {
                throw UpstreamClient.Failure.http("head too large")
            }
            guard let chunk = try await client.receive() else { throw UpstreamClient.Failure.closed }
            buffer.append(chunk)
        }
        guard let (head, end) = HTTPHeadParser.parseResponse(buffer) else {
            throw UpstreamClient.Failure.http("malformed head")
        }
        buffer.removeFirst(end)
        return head
    }

    public func readSome() async throws -> Data? {
        if !buffer.isEmpty {
            let chunk = buffer
            buffer.removeAll(keepingCapacity: true)
            return chunk
        }
        return try await client.receive()
    }

    public func readExactly(_ count: Int) async throws -> Data {
        if count <= 0 { return Data() }
        while buffer.count < count {
            guard let chunk = try await client.receive() else { throw UpstreamClient.Failure.closed }
            buffer.append(chunk)
        }
        let result = buffer.prefix(count)
        buffer.removeFirst(count)
        return Data(result)
    }
}
