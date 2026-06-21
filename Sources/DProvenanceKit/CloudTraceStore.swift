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
        guard let payloadData = try? JSONEncoder().encode(event.payload) else { return }
        
        let row = TraceEventRow(
            id: UUID().uuidString,
            runID: event.runID.uuidString,
            contextID: event.contextID,
            priority: event.payload.priority.rawValue,
            sequence: Int64(event.sequence),
            engine: event.engineName,
            spanID: event.spanID,
            parentSpanID: event.parentSpanID,
            type: event.payload.typeIdentifier,
            payload: payloadData,
            timestamp: Int64(event.timestamp.timeIntervalSince1970 * 1_000_000)
        )
        
        buffer.enqueue(row)
    }
    
    public func flush() async throws {
        try await writer.flush()
    }
    
    public var dropStats: TraceDropStats { buffer.dropStats }
    
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
                schemaVersion: Int(TraceQueryDSL<T>.schemaVersion.prefix(while: { $0.isNumber })) ?? 1,
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
}
