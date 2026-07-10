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

    /// Opens an existing store file strictly read-only. This type only ever SELECTs, and
    /// it is how inspectors open store files they do not own, so the connection must not
    /// be able to mutate them: a mistyped path now throws instead of silently creating an
    /// empty database, and the file being inspected can never be written through here.
    ///
    /// Two read-only strategies cover the states a store file can be in:
    /// - Whenever a `-wal` file sits next to the database — a live writer, a cleanly
    ///   closed store on Apple platforms (which persist an empty `-wal`), or a crashed
    ///   writer — a plain read-only connection reads the committed content.
    /// - A **bare** WAL-mode file with no `-wal` at all (a store copied, exported, or
    ///   rotated as a single file) cannot be read through a plain read-only connection:
    ///   SQLite refuses with `SQLITE_CANTOPEN` because it cannot build the wal-index.
    ///   That state falls back to SQLite's `immutable=1` open, which is safe precisely
    ///   because the missing `-wal` proves no writer has the file open.
    public init(fileURL: URL) throws {
        let candidate = try SQLiteConnection(fileURL: fileURL, mode: .readOnly)
        do {
            // Preparing any statement forces the schema read that surfaces
            // SQLITE_CANTOPEN on a bare WAL-mode file.
            _ = try candidate.prepare("SELECT count(*) FROM sqlite_master;")
            self.db = candidate
        } catch {
            // Fall back to immutable only when no -wal exists. If the probe failed
            // despite a -wal being present, the file has a real problem (corruption,
            // permissions) that an immutable open would mask, not fix.
            guard !FileManager.default.fileExists(atPath: fileURL.path + "-wal") else {
                throw error
            }
            self.db = try SQLiteConnection(fileURL: fileURL, mode: .readOnlyImmutable)
        }
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
