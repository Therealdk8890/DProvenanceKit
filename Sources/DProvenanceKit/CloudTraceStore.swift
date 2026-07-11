import Foundation



public enum CloudTraceStoreError: Error {
    case notImplemented
    case serverError(Int)
    case unsupportedSchema(expected: String, received: String)
}

public final class CloudTraceStore<T: TraceableEvent>: TraceStore, @unchecked Sendable {
    private let endpoint: URL
    private let apiKey: String
    private let buffer: TraceWriteBuffer
    private let writer: CloudWriter
    private let session: URLSession

    /// Events lost before they reach the buffer — payloads that fail to JSON-encode.
    /// Folded into `dropStats` so an unencodable payload can never vanish while the
    /// store still reports `preservedIntegrity == true`.
    private let dropTally = TraceDropTally()

    /// Reused across the concurrent `record` entrypoint: configured once and only read
    /// during `encode`, so concurrent calls are data-race-free while avoiding a fresh
    /// allocation per event. `.sortedKeys` produces the canonical payload bytes required
    /// by Trace Specification v1 §2 (sorted keys).
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    public init(endpoint: URL, apiKey: String, config: OfflineConfig = OfflineConfig(), session: URLSession = .shared) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.buffer = TraceWriteBuffer(config: config)
        self.session = session

        let ingestionURL = endpoint.appendingPathComponent("ingest")
        self.writer = CloudWriter(endpoint: ingestionURL, apiKey: apiKey, buffer: buffer, session: session)

        Task {
            await self.writer.start()
        }
    }

    public func record(_ event: TraceEvent<T>) {
        guard let payloadData = try? encoder.encode(event.payload) else {
            // An unencodable payload can't be transmitted — but it must not vanish
            // silently. Count it in its own tier so the loss shows up in dropStats.
            dropTally.record(priority: event.payload.priority.rawValue)
            return
        }

        let row = TraceEventRow(
            // The recorded TraceEvent.id must survive the wire: a fresh UUID here would
            // break ID-based correlation (replay manifests, lineage joins, quarantine
            // round-trips) between the device and the server.
            id: event.id.uuidString,
            runID: event.runID.uuidString,
            contextID: event.contextID,
            priority: event.payload.priority.rawValue,
            sequence: Int64(event.sequence),
            engine: event.engineName,
            spanID: event.spanID,
            parentSpanID: event.parentSpanID,
            type: event.payload.typeIdentifier,
            payload: payloadData,
            timestamp: Int64(event.timestamp.timeIntervalSince1970 * 1_000_000),
            schemaVersion: event.schemaVersion
        )

        buffer.enqueue(row)
    }

    public func link(source: UUID, target: UUID, type: TraceEdgeType) {
        buffer.enqueueEdge(TraceEdge(sourceID: source, targetID: target, type: type))
    }
    
    public func flush() async throws {
        try await writer.flush()
    }

    /// Bounded variant of `flush()`: throws `CloudWriterError.flushTimedOut` instead of
    /// blocking indefinitely when the endpoint is unreachable.
    public func flush(timeout: TimeInterval) async throws {
        try await writer.flush(timeout: timeout)
    }

    /// Buffer congestion drops plus payloads that failed to encode in `record`.
    /// Quarantined batches are NOT counted here — they remain retrievable via
    /// `queryQuarantinedEvents`.
    public var dropStats: TraceDropStats { buffer.dropStats + dropTally.snapshot }
    
    private struct QueryPayload: Encodable {
        let schemaVersion: String
        let dsl: TraceQueryDSL<T>
        let limit: Int
    }
    
    private struct ErrorResponse: Decodable {
        let error: String
        let expected: String?
        let received: String?
    }
    
    public func negotiateCapabilities() async throws {
        let capURL = endpoint.appendingPathComponent("capabilities")
        var request = URLRequest(url: capURL)
        request.httpMethod = "GET"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    public func queryRuns(_ dsl: TraceQueryDSL<T>) async throws -> [TraceRun<T>] {
        let queryURL = endpoint.appendingPathComponent("query")
        var request = URLRequest(url: queryURL)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let payload = QueryPayload(schemaVersion: TraceQueryDSL<T>.schemaVersion, dsl: dsl, limit: 100)
        request.httpBody = try JSONEncoder().encode(payload)
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        
        if httpResponse.statusCode == 400 || httpResponse.statusCode == 422 {
            if let errResp = try? JSONDecoder().decode(ErrorResponse.self, from: data), errResp.error == "UNSUPPORTED_SCHEMA" {
                throw CloudTraceStoreError.unsupportedSchema(expected: errResp.expected ?? "", received: errResp.received ?? "")
            }
        }
        
        if httpResponse.statusCode == 501 {
            throw CloudTraceStoreError.notImplemented
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw CloudTraceStoreError.serverError(httpResponse.statusCode)
        }
        
        return []
    }
    
    public func getRun(id: UUID) async throws -> TraceRun<T>? {
        // The hosted read path is a separate commercial layer; like `queryRuns`, the
        // client-side stub does not yet reconstruct runs from the server. Returning nil
        // (rather than throwing) keeps this consistent with `queryRuns` returning [] —
        // both signal "no server-side read wired here yet", not an error. Recorded
        // events still ship via the write buffer; reads happen against a local store.
        return nil
    }

    public func queryQuarantinedEvents(_ dsl: TraceQueryDSL<T>) async throws -> [TraceEvent<T>] {
        let rows = await writer.getQuarantinedEvents()
        
        let allEvents = rows.compactMap { row -> TraceEvent<T>? in
            guard let runID = UUID(uuidString: row.runID),
                  let payload = try? JSONDecoder().decode(T.self, from: row.payload),
                  let eventID = UUID(uuidString: row.id) else {
                return nil
            }
            
            return TraceEvent(
                id: eventID,
                runID: runID,
                contextID: row.contextID,
                engineName: row.engine ?? "Unknown",
                schemaVersion: row.schemaVersion,
                sequence: UInt64(row.sequence),
                spanID: row.spanID,
                parentSpanID: row.parentSpanID,
                payload: payload,
                timestamp: Date(timeIntervalSince1970: TimeInterval(row.timestamp) / 1_000_000.0)
            )
        }
        
        var runs: [UUID: [TraceEvent<T>]] = [:]
        for e in allEvents {
            runs[e.runID, default: []].append(e)
        }
        
        var matchedEvents: [TraceEvent<T>] = []
        for (runID, events) in runs {
            let sorted = events.sorted { $0.sequence < $1.sequence }
            let run = TraceRun(runID: runID, contextID: sorted[0].contextID, events: sorted)
            if dsl.ast.evaluate(run: run) {
                matchedEvents.append(contentsOf: events)
            }
        }
        
        return matchedEvents
    }

    public func lineageEdges(of id: UUID) async throws -> [TraceEdge] {
        throw CloudTraceStoreError.notImplemented
    }
    
    public func impactEdges(of id: UUID) async throws -> [TraceEdge] {
        throw CloudTraceStoreError.notImplemented
    }
    
    public func getEvents(ids: Set<UUID>) async throws -> [UUID: TraceEvent<T>] {
        throw CloudTraceStoreError.notImplemented
    }
}
