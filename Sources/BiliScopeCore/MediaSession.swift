import Foundation

/// One downloaded, block-aligned piece of a media file.
struct MediaBlock: Sendable {
    let data: Data
    let total: Int64
    let contentType: String?
}

/// Players ask for about 1 MB at a time, one request after another, so splitting
/// a request gains nothing: short ranges on fresh connections spend their time in
/// the handshake and slow start. Real parallelism comes from downloading the
/// blocks *after* the play position, which then answer the next requests at once.
actor MediaSession {
    private let request: HTTPRequestHead
    private let port: UInt16
    private let config: MITMProxy.Configuration
    private let blockSize: Int64
    private let window: Int64
    private let family: String
    private var hosts: [String]
    private var speeds: [String: Double] = [:]
    private var blocks: [Int64: Task<MediaBlock, Error>] = [:]
    private var total: Int64?
    private var picks = 0
    private var ranking: Task<Void, Error>?
    private var waiting: [Int64: Int] = [:]
    private var failedAt: [String: Date] = [:]
    private let failureCooldown: TimeInterval = 20

    init(request: HTTPRequestHead, host: String, port: UInt16, config: MITMProxy.Configuration) {
        self.request = request
        self.port = port
        self.config = config
        self.blockSize = max(1, config.chunkSize)
        self.window = Int64(max(1, config.concurrency))
        self.hosts = MirrorPlanner.candidates(for: host)
        self.family = MirrorPlanner.family(for: host) ?? host
    }

    nonisolated var blockLength: Int64 { max(1, config.chunkSize) }

    /// The host currently expected to be fastest, for the log.
    var bestHost: String { rankedHosts().first ?? "" }

    func block(_ index: Int64, rankingFrom offset: Int64) async throws -> MediaBlock {
        waiting[index, default: 0] += 1
        defer { waiting[index, default: 1] -= 1 }
        try await rank(from: offset)
        return try await task(for: index).value
    }

    /// Moves the read-ahead window to the play position and drops what fell out of it.
    func advance(to index: Int64) {
        for (key, task) in blocks where key < index - 1 || key >= index + window * 2 {
            task.cancel()
            blocks[key] = nil
        }
        guard let total else { return }
        let lastBlock = (total - 1) / blockSize
        for next in index..<(index + window) where next <= lastBlock {
            _ = task(for: next)
        }
    }

    func cancelAll() {
        blocks.values.forEach { $0.cancel() }
        blocks.removeAll()
    }

    private func task(for index: Int64) -> Task<MediaBlock, Error> {
        if let existing = blocks[index] { return existing }
        let task = Task { try await self.download(index) }
        blocks[index] = task
        return task
    }

    private enum Attempt: Sendable {
        case done(host: String, seconds: TimeInterval, head: HTTPResponseHead, body: Data)
        case failed(host: String, error: Error)
        case hedgeDue
    }

    private func download(_ index: Int64) async throws -> MediaBlock {
        let span = ByteSpan(start: index * blockSize, end: (index + 1) * blockSize)
        let order = nextHostOrder()
        let request = self.request, port = self.port, config = self.config

        func launch(_ host: String, in group: inout TaskGroup<Attempt>) {
            group.addTask {
                let started = Date()
                do {
                    let result = try await MediaFetch.fetch(request, span: span, host: host, port: port, config: config)
                    return .done(host: host, seconds: max(0.001, Date().timeIntervalSince(started)),
                                 head: result.head, body: result.body)
                } catch {
                    return .failed(host: host, error: error)
                }
            }
        }
        func scheduleHedge(in group: inout TaskGroup<Attempt>) {
            let delay = UInt64(config.hedgeDelay * 1_000_000_000)
            group.addTask {
                try? await Task.sleep(nanoseconds: delay)
                return .hedgeDue
            }
        }

        // A slow download keeps what it has: a block the player is waiting for gets
        // a second mirror alongside it, and whichever finishes first wins.
        let result: Result<MediaBlock, Error> = await withTaskGroup(of: Attempt.self) { group in
            var next = 1
            var running = 1
            var lastError: Error = UpstreamClient.Failure.http("no mirror available")
            launch(order[0], in: &group)
            // After a seek nothing has been read ahead and the player is already
            // waiting, so this block starts on two mirrors at once.
            if waiting[index, default: 0] > 0, order.count > 1 {
                launch(order[1], in: &group)
                next = 2
                running = 2
            }
            scheduleHedge(in: &group)
            while let attempt = await group.next() {
                switch attempt {
                case .done(let host, let seconds, let head, let body):
                    running -= 1
                    record(host, speed: Double(body.count) / seconds)
                    guard let range = RangeHeader.parseContentRange(head.header("Content-Range")),
                          let length = range.total else {
                        lastError = UpstreamClient.Failure.http("missing Content-Range")
                        if next < order.count {
                            launch(order[next], in: &group)
                            next += 1
                            running += 1
                        } else if running == 0 {
                            group.cancelAll()
                            return .failure(lastError)
                        }
                        continue
                    }
                    total = length
                    group.cancelAll()
                    return .success(MediaBlock(data: body, total: length, contentType: head.header("Content-Type")))
                case .failed(let host, let error):
                    running -= 1
                    if Task.isCancelled {
                        group.cancelAll()
                        return .failure(error)
                    }
                    record(host, speed: nil)
                    config.log("block failed \(host) #\(index): \(error)")
                    lastError = error
                    if next < order.count {
                        launch(order[next], in: &group)
                        next += 1
                        running += 1
                    } else if running == 0 {
                        group.cancelAll()
                        return .failure(lastError)
                    }
                case .hedgeDue:
                    guard !Task.isCancelled, next < order.count else { continue }
                    if running < 3, waiting[index, default: 0] > 0 {
                        config.log("hedge #\(index) -> \(order[next])")
                        launch(order[next], in: &group)
                        next += 1
                        running += 1
                    }
                    scheduleHedge(in: &group)
                }
            }
            return .failure(lastError)
        }
        if case .failure = result { blocks[index] = nil }
        return try result.get()
    }

    private func record(_ host: String, speed: Double?) {
        if let speed {
            failedAt[host] = nil
            speeds[host] = speeds[host].map { $0 * 0.6 + speed * 0.4 } ?? speed
            if let best = rankedHosts().first { MirrorCache.shared.remember(best, for: family) }
        } else {
            failedAt[host] = Date()
        }
    }

    private func rankedHosts() -> [String] {
        // A mirror that just failed waits behind even unmeasured ones, otherwise
        // the same stalled mirror keeps being retried while others sit unused.
        let now = Date()
        let cooling = hosts.filter { failedAt[$0].map { now.timeIntervalSince($0) < failureCooldown } ?? false }
        let healthy = hosts.filter { !cooling.contains($0) }
        let measured = healthy.filter { speeds[$0] != nil }
            .sorted { (speeds[$0] ?? 0) > (speeds[$1] ?? 0) }
        return measured + healthy.filter { speeds[$0] == nil } + cooling
    }

    /// Mostly the fastest mirror, but every fourth block samples the runner-up,
    /// because a mirror that was fast for one file can be slow for the next.
    private func nextHostOrder() -> [String] {
        var order = rankedHosts()
        picks += 1
        if picks % 4 == 0, order.count > 1 { order.swapAt(0, 1) }
        return order
    }

    /// Whether a mirror has a file cached differs per file, so every file races.
    /// With a likely winner known the race runs on the side and only reorders hosts.
    private func rank(from offset: Int64) async throws {
        guard hosts.count > 1 else { return }
        let preferred = MirrorCache.shared.preferred(for: family).flatMap { hosts.contains($0) ? $0 : nil }
        if ranking == nil {
            if let preferred { promote(preferred) }
            let candidates = hosts
            ranking = Task {
                let winner = try await MediaFetch.race(self.request, offset: offset, hosts: candidates,
                                                       port: self.port, config: self.config)
                await self.promote(winner)
            }
        }
        guard preferred == nil else { return }
        do {
            try await ranking?.value
        } catch {
            // A failed race must not poison the session; the next request races again.
            ranking = nil
            throw error
        }
    }

    private func promote(_ host: String) {
        hosts.removeAll { $0 == host }
        hosts.insert(host, at: 0)
    }
}

/// Keeps the sessions of the tracks being played. Each one is bounded by its
/// read-ahead window, and this bounds how many exist.
actor MediaSessionStore {
    private var sessions: [String: MediaSession] = [:]
    private var recent: [String] = []
    private let limit = 4

    func session(for request: HTTPRequestHead, host: String, port: UInt16,
                 config: MITMProxy.Configuration) async -> MediaSession {
        // Mirrors serve identical bytes for one signed path, so the host is not part of the key.
        let key = request.path
        recent.removeAll { $0 == key }
        recent.append(key)
        if let existing = sessions[key] { return existing }
        let session = MediaSession(request: request, host: host, port: port, config: config)
        sessions[key] = session
        while recent.count > limit {
            let oldest = recent.removeFirst()
            if let evicted = sessions.removeValue(forKey: oldest) { await evicted.cancelAll() }
        }
        return session
    }
}

/// Logs the upstream interface when it changes: `utun` here would mean a loop.
enum InterfaceLog {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var last: String?

    static func note(_ name: String?, config: MITMProxy.Configuration) {
        guard let name else { return }
        lock.lock()
        let changed = last != name
        last = name
        lock.unlock()
        if changed { config.log("upstream via \(name)") }
    }
}

enum MediaFetch {
    private final class Progress: @unchecked Sendable {
        private let lock = NSLock()
        private var last = Date()
        func touch() { lock.lock(); last = Date(); lock.unlock() }
        var idle: TimeInterval { lock.lock(); defer { lock.unlock() }; return Date().timeIntervalSince(last) }
    }

    /// Fetches one range. A connection that stops delivering is cancelled, so a
    /// stuck mirror fails over instead of freezing playback.
    static func fetch(_ request: HTTPRequestHead,
                      span: ByteSpan,
                      host: String,
                      port: UInt16,
                      config: MITMProxy.Configuration,
                      connectTimeout: TimeInterval = 8) async throws -> (head: HTTPResponseHead, body: Data) {
        let client = try await UpstreamClient.open(host: host,
                                                   port: port,
                                                   timeout: connectTimeout,
                                                   trustRootDER: config.upstreamTrustRootDER)
        defer { client.cancel() }
        InterfaceLog.note(client.interfaceName, config: config)
        let progress = Progress()
        let stallTimeout = config.stallTimeout
        let watchdog = Task {
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 250_000_000)
                if progress.idle > stallTimeout {
                    client.cancel()
                    return
                }
            }
        }
        defer { watchdog.cancel() }
        return try await withTaskCancellationHandler {
            try await client.send(MediaHandler.requestData(request, host: host, range: span, close: true))
            let stream = ResponseStream(client: client)
            let head = try await stream.readHead()
            guard head.status == 206 else {
                throw UpstreamClient.Failure.unexpectedStatus(head.status)
            }
            guard let length = Int(head.header("Content-Length") ?? ""), length > 0 else {
                throw UpstreamClient.Failure.http("chunk without Content-Length")
            }
            var body = Data(capacity: length)
            while body.count < length {
                guard let chunk = try await stream.readSome() else { throw UpstreamClient.Failure.closed }
                progress.touch()
                body.append(chunk)
            }
            return (head, body.count == length ? body : Data(body.prefix(length)))
        } onCancel: {
            client.cancel()
        }
    }

    /// Asks every mirror for the same small range and returns the first to answer.
    /// The losers are cancelled, so this costs little compared to racing real blocks.
    static func race(_ request: HTTPRequestHead,
                     offset: Int64,
                     hosts: [String],
                     port: UInt16,
                     config: MITMProxy.Configuration) async throws -> String {
        let span = ByteSpan(start: offset, end: offset + (64 << 10))
        let tasks = TaskList()
        defer { tasks.cancelAll() }
        return try await withCheckedThrowingContinuation { continuation in
            let box = MirrorRaceBox(count: hosts.count, continuation: continuation)
            for host in hosts {
                tasks.add(Task {
                    do {
                        _ = try await fetch(request, span: span, host: host, port: port, config: config)
                        box.succeed(host: host)
                    } catch {
                        box.fail(error)
                    }
                })
            }
        }
    }

    private final class TaskList: @unchecked Sendable {
        private let lock = NSLock()
        private var tasks: [Task<Void, Never>] = []
        func add(_ task: Task<Void, Never>) { lock.lock(); tasks.append(task); lock.unlock() }
        func cancelAll() { lock.lock(); tasks.forEach { $0.cancel() }; lock.unlock() }
    }
}

private final class MirrorRaceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var remaining: Int
    private let continuation: CheckedContinuation<String, Error>

    init(count: Int, continuation: CheckedContinuation<String, Error>) {
        self.remaining = count
        self.continuation = continuation
    }

    func succeed(host: String) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        lock.unlock()
        continuation.resume(returning: host)
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
