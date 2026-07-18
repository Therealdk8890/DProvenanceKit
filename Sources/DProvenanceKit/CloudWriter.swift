import Foundation

/// Raised by `CloudWriter.flush(timeout:)` when the backlog can't be delivered before
/// the deadline — e.g. the endpoint is unreachable and the circuit breaker is holding
/// requests off. The events remain buffered/inflight (not lost); the caller decides
/// whether to retry. This is what keeps `flush` from blocking forever on an outage.
public enum CloudWriterError: Error, Equatable {
    case flushTimedOut(undelivered: Int)
}

public actor CloudWriter {
    /// One drained unit of work: the events and lineage edges taken from the buffer
    /// together, kept together through retry and quarantine so neither can be
    /// silently left behind while the other is delivered.
    struct Batch: Sendable {
        var events: [TraceEventRow]
        var edges: [TraceEdge]
        var count: Int { events.count + edges.count }
        var isEmpty: Bool { events.isEmpty && edges.isEmpty }
    }

    private let endpoint: URL
    private let apiKey: String
    private let buffer: TraceWriteBuffer
    private let session: URLSession

    private var writeTask: Task<Void, Never>?
    /// Kept separately because `Task` exposes cancellation but not completion state.
    /// The detached loop clears this through `writerTaskDidStop`, allowing shutdown
    /// to poll against one deadline without awaiting a non-cooperative task forever.
    private var writeTaskIsRunning = false
    private var isShuttingDown = false
    private var isSending = false

    private var inflightBatch: Batch? = nil
    private var attemptCount = 0
    private var quarantineQueue: [Batch] = []

    private let circuitBreaker: CircuitBreaker

    public init(
        endpoint: URL,
        apiKey: String,
        buffer: TraceWriteBuffer,
        session: URLSession = .shared,
        circuitBreaker: CircuitBreaker = CircuitBreaker()
    ) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.buffer = buffer
        self.session = session
        self.circuitBreaker = circuitBreaker
    }
    
    public func start() {
        guard writeTask == nil, !isShuttingDown else { return }
        writeTaskIsRunning = true
        writeTask = Task.detached { [weak self] in
            while true {
                guard let self = self else { break }
                let isShuttingDown = await self.isShuttingDown
                if isShuttingDown { break }
                
                await self.tick()
            }
            await self?.writerTaskDidStop()
        }
    }
    
    /// Drains the backlog — pending events AND lineage edges — to the server, bounded
    /// by `timeout`. Returns when everything is delivered (or quarantined); throws
    /// `CloudWriterError.flushTimedOut` (undelivered = events + edges) if the deadline
    /// passes first — it never blocks indefinitely on an unreachable endpoint.
    public func flush(timeout: TimeInterval = 30.0) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while buffer.currentDepth > 0 || buffer.pendingEdgeCount > 0 || inflightBatch != nil {
            if Date() >= deadline {
                let backlog = buffer.currentDepth + buffer.pendingEdgeCount
                throw CloudWriterError.flushTimedOut(undelivered: backlog + (inflightBatch?.count ?? 0))
            }
            if isSending {
                try await Task.sleep(nanoseconds: 20_000_000)
                continue
            }
            await processNextBatch(drainAll: true, deadline: deadline)
            // Don't hot-spin while the circuit breaker is holding sends off.
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Compatibility wrapper for callers that used the original best-effort shutdown.
    /// New code should call `shutdown(timeout:)` so an incomplete drain is observable.
    public func shutdown() async {
        try? await shutdown(timeout: 30.0)
    }

    /// Stops the background ticker and then performs a bounded, honest drain.
    ///
    /// Cancellation only wakes the ticker from its sleep; `inflightBatch` and buffered
    /// rows remain owned by this actor and are delivered by `flush(timeout:)`. On
    /// timeout they remain retained for an explicit retry. One deadline covers BOTH
    /// waiting for the ticker to exit and the final drain.
    public func shutdown(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        isShuttingDown = true
        writeTask?.cancel()

        while writeTaskIsRunning {
            guard Date() < deadline else {
                throw CloudWriterError.flushTimedOut(undelivered: undeliveredCount)
            }
            // Actor reentrancy lets `writerTaskDidStop()` clear the flag.
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        writeTask = nil

        let remaining = max(0, deadline.timeIntervalSinceNow)
        try await flush(timeout: remaining)
    }

    private var undeliveredCount: Int {
        buffer.currentDepth
            + buffer.pendingEdgeCount
            + (inflightBatch?.count ?? 0)
    }

    private func writerTaskDidStop() {
        writeTaskIsRunning = false
    }

    #if DEBUG
    /// Installs a deliberately cancellation-ignoring ticker for deterministic timeout
    /// tests. It exercises shutdown's task-wait deadline without involving URLSession,
    /// whose cancellation behavior varies by URLProtocol implementation.
    func startNonCooperativeTaskForShutdownTesting(duration: TimeInterval) {
        guard writeTask == nil else { return }
        writeTaskIsRunning = true
        writeTask = Task.detached { [weak self] in
            let end = Date().addingTimeInterval(duration)
            while Date() < end {
                // Intentionally ignore cancellation. The loop is short and test-only.
                _ = 1 &+ 1
            }
            await self?.writerTaskDidStop()
        }
    }
    #endif

    public func getQuarantinedEvents() -> [TraceEventRow] {
        return quarantineQueue.flatMap { $0.events }
    }

    /// Lineage edges that were drained alongside a batch the server permanently
    /// rejected (400, 409, or 422) or that exhausted retries. Like quarantined
    /// events, they are retained — not lost.
    public func getQuarantinedEdges() -> [TraceEdge] {
        return quarantineQueue.flatMap { $0.edges }
    }

    /// Per-tier tally of everything sitting in quarantine, computed from the queue
    /// itself so it can never drift from what `getQuarantinedEvents` would return.
    /// Edges count as `structural`, mirroring how a lost edge is tallied elsewhere:
    /// they change what lineage traversal contains.
    public func quarantinedStats() -> TraceDropStats {
        var stats = TraceDropStats.zero
        for batch in quarantineQueue {
            for event in batch.events {
                // Rows are built by record() from TracePriority.rawValue, so an
                // out-of-range tier only occurs through misuse — fail toward
                // visibility (critical), never silence. This deliberately diverges
                // from the buffer's shed-path fallback (`?? .telemetry`): a shed
                // row is gone either way, but a mis-tiered quarantined row still
                // exists and must not read as "safe to lose".
                switch TracePriority(rawValue: event.priority) ?? .critical {
                case .telemetry: stats.telemetry &+= 1
                case .diagnostic: stats.diagnostic &+= 1
                case .structural: stats.structural &+= 1
                case .critical: stats.critical &+= 1
                }
            }
            stats.structural &+= UInt64(batch.edges.count)
        }
        return stats
    }
    
    private func tick() async {
        let sleepMs: UInt64 = 500
        await processNextBatch(maxBatch: 1000)
        try? await Task.sleep(nanoseconds: sleepMs * 1_000_000)
    }

    #if DEBUG
    /// Test hook: run exactly one processing pass (no background ticker, no trailing
    /// sleep). Used to drive the idle-tick / probe-window path deterministically.
    func processOnceForTesting(drainAll: Bool = false) async {
        await processNextBatch(drainAll: drainAll)
    }
    #endif
    
    private func processNextBatch(drainAll: Bool = false, maxBatch: Int = 1000, deadline: Date? = nil) async {
        guard !isSending else { return }
        isSending = true
        defer { isSending = false }

        // Determine the unit of work BEFORE consulting the circuit breaker. The breaker
        // grants exactly one probe when it moves .open -> .halfOpen, and that probe is
        // only "spent" honestly by a send that then records success or failure. If we
        // asked the breaker for permission first and then found nothing to drain, an idle
        // tick during the probe window would consume the probe and strand the breaker in
        // .halfOpen forever — permanently wedging the writer even after the endpoint
        // recovered. Draining first means an empty buffer returns here, breaker untouched.
        let batch: Batch
        if let inflight = inflightBatch {
            batch = inflight
        } else {
            // Edges ride with the event batch: they are drained atomically here and
            // stay attached through retry/quarantine, so a lineage edge can never sit
            // in the buffer forever while the events it references are delivered.
            let drained = Batch(
                events: drainAll ? buffer.flushAll() : buffer.drain(max: maxBatch),
                edges: buffer.drainEdges()
            )
            guard !drained.isEmpty else { return }
            batch = drained
            inflightBatch = batch
            attemptCount = 0
        }

        let waitTime = await circuitBreaker.timeUntilAllowed()
        if waitTime > 0 {
            // Under a caller deadline (flush), don't block past it waiting for the
            // breaker to reopen — return and let the caller decide to time out. The
            // batch stays inflight and is retried on the next pass, never dropped.
            if let deadline, Date().addingTimeInterval(waitTime) >= deadline {
                return
            }
            try? await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))
        }

        guard await circuitBreaker.allowRequest() else { return }

        let maxAttempts = 10
        let baseBackoff: Double = 1.0
        let maxBackoff: Double = 60.0
        
        while attemptCount < maxAttempts {
            do {
                let statusCode = try await sendBatch(batch, deadline: deadline)

                if Self.isPermanentRejection(statusCode) {
                    DPKLog.cloud.error("Permanent batch rejection (HTTP \(statusCode)); quarantining \(batch.events.count) events and \(batch.edges.count) edges.")
                    quarantineQueue.append(batch)
                    inflightBatch = nil
                    attemptCount = 0
                    await circuitBreaker.recordSuccess()
                    return
                }

                inflightBatch = nil
                attemptCount = 0
                await circuitBreaker.recordSuccess()
                return
            } catch {
                // Cancellation of THIS task is caller intent — shutdown(timeout:)
                // cancelling the ticker mid-send — not endpoint feedback. Counting it
                // would burn the retry budget instantly (backoff sleeps are no-ops
                // once cancelled) and open the breaker with zero real failures,
                // stalling the final drain for the breaker's full recovery window.
                // Leave the batch inflight; the caller's uncancelled flush delivers
                // it. Deliberately narrow: a URLError(.cancelled) arriving on an
                // UNCANCELLED task (TLS-pinning delegate rejection, session
                // invalidation) is endpoint/session feedback and must keep counting,
                // or the batch would retry forever with the breaker bypassed and no
                // quarantine ever surfacing it.
                if error is CancellationError || Task.isCancelled {
                    DPKLog.cloud.info("Send cancelled mid-flight; batch of \(batch.events.count) events and \(batch.edges.count) edges retained inflight for the final drain.")
                    return
                }
                attemptCount += 1
                await circuitBreaker.recordFailure()
                
                if attemptCount >= maxAttempts {
                    DPKLog.cloud.error("Batch failed \(maxAttempts) times; quarantining \(batch.events.count) events and \(batch.edges.count) edges.")
                    quarantineQueue.append(batch)
                    inflightBatch = nil
                    attemptCount = 0
                    return
                }
                
                guard await circuitBreaker.allowRequest() else {
                    return
                }

                let backoff: Double
                if attemptCount == 1 {
                    backoff = Double.random(in: 0.1...1.0)
                } else {
                    let cap = min(maxBackoff, baseBackoff * pow(2.0, Double(attemptCount)))
                    backoff = Double.random(in: 0...cap)
                }

                // Leave the batch inflight rather than sleep past a caller's deadline;
                // the flush loop will re-check and time out cleanly.
                if let deadline, Date().addingTimeInterval(backoff) >= deadline {
                    return
                }
                try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            }
        }
    }
    
    private func sendBatch(_ batch: Batch, deadline: Date? = nil) async throws -> Int {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        // A caller deadline (flush/shutdown) bounds each attempt so URLSession's
        // 60s default can't overshoot it by an entire request. The deadline-less
        // ticker path keeps the session default: it has no deadline to overshoot,
        // and shortening it would newly fail slow-but-succeeding bulk ingests.
        if let deadline {
            request.timeoutInterval = max(0.5, min(30.0, deadline.timeIntervalSinceNow))
        }

        let eventObjects = batch.events.map { event in
            [
                "id": event.id,
                "run_id": event.runID,
                "context_id": event.contextID,
                "priority": event.priority,
                "sequence": event.sequence,
                "engine": event.engine ?? NSNull(),
                "span_id": event.spanID ?? NSNull(),
                "parent_span_id": event.parentSpanID ?? NSNull(),
                "type": event.type,
                // .fragmentsAllowed keeps single-value payloads (a String raw-value
                // enum encodes as a bare JSON string) riding the wire as real JSON.
                // Without it they fell into the base64 fallback, which the typed
                // read path cannot reverse — the simplest legal event type would
                // round-trip as permanently undecodable.
                "payload": (try? JSONSerialization.jsonObject(with: event.payload, options: [.fragmentsAllowed])) ?? event.payload.base64EncodedString(),
                "timestamp": event.timestamp,
                "schema_version": event.schemaVersion
            ] as [String : Any]
        }
        let edgeObjects = batch.edges.map { edge in
            [
                "source_id": edge.sourceID.uuidString,
                "target_id": edge.targetID.uuidString,
                "edge_type": edge.type.rawValue
            ] as [String : Any]
        }

        // Envelope form (see docs/CLOUD.md "Wire contract"): lineage edges ship in the
        // same request as the events they arrived with.
        let payload: [String: Any] = ["events": eventObjects, "edges": edgeObjects]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        
        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        
        if !(200...299).contains(httpResponse.statusCode)
            && !Self.isPermanentRejection(httpResponse.statusCode) {
            throw URLError(.badServerResponse)
        }
        
        return httpResponse.statusCode
    }

    /// FastAPI uses 422 for request-validation failures and the hosted store uses
    /// 409 when an existing ID conflicts with different content. Neither can be
    /// repaired by replaying the same bytes, just like a 400 malformed request.
    /// Rate limits and server failures remain retryable.
    private static func isPermanentRejection(_ statusCode: Int) -> Bool {
        statusCode == 400 || statusCode == 409 || statusCode == 422
    }
}
