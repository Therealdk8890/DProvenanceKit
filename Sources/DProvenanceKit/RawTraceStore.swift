import Foundation

public struct RawTraceEvent: Sendable, Identifiable, Equatable {
    public let id = UUID()
    public let runID: UUID
    public let contextID: String
    public let priority: Int
    public let sequence: UInt64
    public let engineName: String
    public let spanID: String?
    public let parentSpanID: String?
    public let typeIdentifier: String
    public let payloadJSON: String
    public let timestamp: Date
}

public struct RawTraceRun: Sendable, Identifiable, Equatable {
    public var id: UUID { runID }
    public let runID: UUID
    public let contextID: String
    public let startTime: Date
    public let endTime: Date
    public let eventCount: Int
    public let events: [RawTraceEvent]
}

public final class RawTraceStore: @unchecked Sendable {
    private let db: SQLiteConnection
    
    public init(fileURL: URL) throws {
        self.db = try SQLiteConnection(fileURL: fileURL)
    }
    
    public func fetchAllRuns() async throws -> [RawTraceRun] {
        let sql = "SELECT run_id, context_id, start_time, end_time, event_count FROM runs ORDER BY start_time DESC"
        let stmt = try db.prepare(sql)
        
        var runs: [RawTraceRun] = []
        while try stmt.step() {
            guard let runIDString = stmt.columnString(at: 0),
                  let runID = UUID(uuidString: runIDString),
                  let contextID = stmt.columnString(at: 1) else { continue }
            
            let startMs = stmt.columnInt64(at: 2)
            let endMs = stmt.columnInt64(at: 3)
            let eventCount = stmt.columnInt(at: 4)
            
            let events = try await fetchEventsForRun(id: runIDString)
            
            let run = RawTraceRun(
                runID: runID,
                contextID: contextID,
                startTime: Date(timeIntervalSince1970: Double(startMs) / 1_000_000.0),
                endTime: Date(timeIntervalSince1970: Double(endMs) / 1_000_000.0),
                eventCount: Int(eventCount),
                events: events
            )
            runs.append(run)
        }
        return runs
    }
    
    private func fetchEventsForRun(id: String) async throws -> [RawTraceEvent] {
        let sql = "SELECT context_id, priority, sequence, engine, span_id, parent_span_id, type, payload, timestamp FROM trace_events WHERE run_id = ? ORDER BY sequence ASC"
        let stmt = try db.prepare(sql)
        try stmt.bind(id, at: 1)
        
        var events: [RawTraceEvent] = []
        while try stmt.step() {
            let contextID = stmt.columnString(at: 0) ?? ""
            let priority = Int(stmt.columnInt64(at: 1))
            let sequence = UInt64(stmt.columnInt64(at: 2))
            let engine = stmt.columnString(at: 3) ?? "Unknown"
            let spanID = stmt.columnString(at: 4)
            let parentSpanID = stmt.columnString(at: 5)
            let type = stmt.columnString(at: 6) ?? "Unknown"
            let payloadData = stmt.columnData(at: 7)
            let timestampMs = stmt.columnInt64(at: 8)
            
            let payloadJSON = String(data: payloadData, encoding: .utf8) ?? "{}"
            
            let event = RawTraceEvent(
                runID: UUID(uuidString: id) ?? UUID(),
                contextID: contextID,
                priority: priority,
                sequence: sequence,
                engineName: engine,
                spanID: spanID,
                parentSpanID: parentSpanID,
                typeIdentifier: type,
                payloadJSON: payloadJSON,
                timestamp: Date(timeIntervalSince1970: Double(timestampMs) / 1_000_000.0)
            )
            events.append(event)
        }
        return events
    }
}
