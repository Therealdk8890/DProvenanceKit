import Foundation

public final class SQLiteTraceStore<T: TraceableEvent>: TraceStore, @unchecked Sendable {
    private let db: SQLiteConnection
    private let buffer: TraceWriteBuffer
    private let writer: SQLiteWriter
    
    public init(fileURL: URL, maxGlobalBuffer: Int = 50_000, maxPerRunBuffer: Int = 5_000) throws {
        let database = try SQLiteConnection(fileURL: fileURL)
        let buf = TraceWriteBuffer(maxGlobalBuffer: maxGlobalBuffer, maxPerRunBuffer: maxPerRunBuffer)
        let wr = SQLiteWriter(db: database, buffer: buf)
        
        self.db = database
        self.buffer = buf
        self.writer = wr
        
        // Ensure tables exist
        try database.transaction {
            try database.execute("""
            CREATE TABLE IF NOT EXISTS runs (
                run_id TEXT PRIMARY KEY,
                context_id TEXT,
                start_time INTEGER,
                end_time INTEGER,
                event_count INTEGER,
                fingerprint TEXT
            );
            """)
            
            try database.execute("""
            CREATE TABLE IF NOT EXISTS trace_events (
                id TEXT PRIMARY KEY,
                run_id TEXT NOT NULL,
                context_id TEXT NOT NULL,
                engine TEXT,
                type TEXT NOT NULL,
                payload BLOB NOT NULL,
                timestamp INTEGER NOT NULL
            );
            """)
            
            // Critical indices
            try database.execute("CREATE INDEX IF NOT EXISTS idx_run_id ON trace_events(run_id);")
            try database.execute("CREATE INDEX IF NOT EXISTS idx_type ON trace_events(type);")
            try database.execute("CREATE INDEX IF NOT EXISTS idx_run_type ON trace_events(run_id, type);")
            try database.execute("CREATE INDEX IF NOT EXISTS idx_timestamp ON trace_events(timestamp);")
            
            // Write-behind reconciliation
            // Ensure any runs interrupted during a crash are rebuilt from trace_events
            let reconcileSQL = """
            INSERT INTO runs (run_id, context_id, start_time, end_time, event_count, fingerprint)
            SELECT 
                run_id,
                MAX(context_id),
                MIN(timestamp),
                MAX(timestamp),
                COUNT(*),
                ''
            FROM trace_events
            GROUP BY run_id
            HAVING COUNT(*) > (SELECT COALESCE(MAX(event_count), 0) FROM runs WHERE runs.run_id = trace_events.run_id)
            ON CONFLICT(run_id) DO UPDATE SET
                end_time = excluded.end_time,
                event_count = excluded.event_count;
            """
            try database.execute(reconcileSQL)
        }
        
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
            engine: event.engineName,
            type: event.payload.typeIdentifier,
            payload: payloadData,
            timestamp: Int64(event.timestamp.timeIntervalSince1970 * 1_000_000)
        )
        
        Task {
            await buffer.enqueue(row)
        }
    }
    
    public func flush() async throws {
        try await writer.flush()
    }
    
    public func queryRuns(_ dsl: TraceQueryDSL<T>) async throws -> [TraceRun<T>] {
        // Ensure all pending events are flushed before querying so results are accurate
        try await flush()
        
        let compiled = TraceQueryCompiler.compile(node: dsl.ast)
        let stmt = try db.prepare(compiled.sql)
        for (i, binding) in compiled.bindings.enumerated() {
            try stmt.bind(binding, at: Int32(i + 1))
        }
        
        var runIDs: [String] = []
        while try stmt.step() {
            if let runID = stmt.columnString(at: 0) {
                runIDs.append(runID)
            }
        }
        
        // Hydrate runs
        var runs: [TraceRun<T>] = []
        for idString in runIDs {
            guard let uuid = UUID(uuidString: idString) else { continue }
            if let run = try await fetchRun(id: uuid) {
                runs.append(run)
            }
        }
        return runs
    }
    
    private func fetchRun(id: UUID) async throws -> TraceRun<T>? {
        let sql = "SELECT engine, type, payload, timestamp FROM trace_events WHERE run_id = ? ORDER BY timestamp ASC"
        let stmt = try db.prepare(sql)
        try stmt.bind(id.uuidString, at: 1)
        
        var events: [TraceEvent<T>] = []
        let decoder = JSONDecoder()
        
        // Fetch context_id from the runs table
        let ctxStmt = try db.prepare("SELECT context_id FROM runs WHERE run_id = ?")
        try ctxStmt.bind(id.uuidString, at: 1)
        guard try ctxStmt.step(), let contextID = ctxStmt.columnString(at: 0) else {
            return nil
        }
        
        while try stmt.step() {
            let engine = stmt.columnString(at: 0)
            _ = stmt.columnString(at: 1) // type
            let payloadData = stmt.columnData(at: 2)
            let timestampMs = stmt.columnInt64(at: 3)
            
            if let payload = try? decoder.decode(T.self, from: payloadData) {
                let event = TraceEvent(
                    runID: id,
                    contextID: contextID,
                    engineName: engine ?? "Unknown",
                    schemaVersion: 1, // Store schema version if needed, defaulting to 1
                    payload: payload,
                    timestamp: Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1_000_000.0)
                )
                events.append(event)
            }
        }
        
        guard !events.isEmpty else { return nil }
        return TraceRun(runID: id, contextID: contextID, events: events)
    }
}
