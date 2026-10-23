import Foundation

/// One STT result as the live path sees it. Times are ms on the call timeline (audio), `arrivalMs` on the
/// stream clock (when the result reached us). `words` = final word end times (ms), for the lag metric.
public struct STTUpdate: Sendable {
    public var channel: String
    public var text: String
    public var startMs: Int
    public var endMs: Int
    public var isFinal: Bool
    public var lang: String
    public var arrivalMs: Int
    public var words: [(word: String, endMs: Int)]
    public var generation: Int

    public init(channel: String, text: String, startMs: Int, endMs: Int, isFinal: Bool, lang: String,
                arrivalMs: Int, words: [(word: String, endMs: Int)] = [], generation: Int = 1) {
        self.channel = channel; self.text = text; self.startMs = startMs; self.endMs = endMs; self.isFinal = isFinal
        self.lang = lang; self.arrivalMs = arrivalMs; self.words = words; self.generation = generation
    }
}

/// Hands a channel's audio to whichever worker generation is alive. The feeder keeps pushing on the wall
/// clock across restarts; audio pushed while no worker is attached is dropped (counted in `frames`).
public final class LiveRelay<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: AsyncStream<Element>.Continuation?
    private var finished = false
    /// Frames pushed so far (all generations): a new worker's time offset.
    public private(set) var frames = 0

    public init() {}

    /// New stream for a new worker generation + the frame offset it starts at.
    public func attach() -> (stream: AsyncStream<Element>, offsetFrames: Int) {
        let (stream, c) = AsyncStream<Element>.makeStream()
        lock.lock(); defer { lock.unlock() }
        cont?.finish()
        if finished { c.finish() } else { cont = c }
        return (stream, frames)
    }

    public func push(_ e: Element, frames n: Int) {
        lock.lock(); defer { lock.unlock() }
        frames += n
        cont?.yield(e)
    }

    /// End of input: the current worker drains and returns normally (no restart).
    public func finish() {
        lock.lock(); defer { lock.unlock() }
        finished = true
        cont?.finish(); cont = nil
    }
}

/// Keeps one STT worker per channel alive. A worker that returns normally is done (input finished);
/// one that throws or is cancelled (`kill()`, engine crash) is restarted after `backoff`.
public actor STTSupervisor {
    public typealias Worker = @Sendable (_ generation: Int) async throws -> Void

    let name: String
    let backoff: Duration
    let work: Worker
    private var current: Task<Void, Error>?
    private var loop: Task<Void, Never>?
    private var stopped = false
    private var killedAt: ContinuousClock.Instant?
    public private(set) var generation = 0
    /// Kill (or crash) → next worker started, per restart.
    public private(set) var restartLatencies: [Duration] = []
    public private(set) var lastError: String?

    public init(name: String, backoff: Duration = .milliseconds(200), work: @escaping Worker) {
        self.name = name; self.backoff = backoff; self.work = work
    }

    public func start() {
        guard loop == nil else { return }
        loop = Task { await self.run() }
    }

    private func run() async {
        while !stopped {
            generation += 1
            let g = generation
            if let k = killedAt { restartLatencies.append(k.duration(to: .now)); killedAt = nil }
            let t = Task { try await work(g) }
            current = t
            let result = await t.result
            // Normal return = input finished, unless we killed it (a worker that swallowed the cancel).
            if case .success = result, killedAt == nil { return }
            if case .failure(let e) = result { lastError = "\(e)" }
            if killedAt == nil { killedAt = .now }
            if stopped { return }
            try? await Task.sleep(for: backoff)
        }
    }

    /// Cancels the running worker as a crash would; the loop restarts it.
    public func kill() {
        killedAt = .now
        current?.cancel()
    }

    /// Stops for good: no restart.
    public func stop() {
        stopped = true
        current?.cancel()
    }

    /// Waits until the loop ended (input finished or `stop()`).
    public func wait() async { await loop?.value }
}
