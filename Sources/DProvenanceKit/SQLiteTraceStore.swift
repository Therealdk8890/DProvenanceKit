import Foundation

public final class SQLiteTraceStore<T: TraceableEvent>: TraceStore, @unchecked Sendable {
    private let db: SQLiteConnection
    /// A second connection to the same file, used only for reads. The writer's
    /// inserts bind/step between BEGIN and COMMIT on `db`, and a reader sharing that
    /// connection would see its own uncommitted rows mid-transaction. On a separate
    /// connection, WAL gives the reader a committed snapshot, so a query can never
    /// observe a half-written batch. Reads flush the writer first, so "committed"
    /// includes everything recorded before the read.
    private let readDB: SQLiteConnection
    private let buffer: TraceWriteBuffer
    private let writer: SQLiteWriter

    /// Events lost outside the write buffer, counted by tier rather than dropped
    /// silently: payloads that fail to JSON-encode here, plus batches the writer fails
    /// to persist. Shared with `writer` so both loss sites land in one accounting and
    /// surface in `dropStats.preservedIntegrity` exactly like a congestion drop.
    private let dropTally: TraceDropTally

    /// Reused across the concurrent `record` entrypoint: configured once and only read
    /// during `encode`, so concurrent calls are data-race-free while avoiding a fresh
    /// allocation per event. `.sortedKeys` produces the canonical payload bytes required
    /// by Trace Specification v1 §2 (sorted keys).
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    public init(fileURL: URL, maxGlobalBuffer: Int = 50_000, maxPerRunBuffer: Int = 5_000) throws {
        let database = try SQLiteConnection(fileURL: fileURL)
        let buf = TraceWriteBuffer(maxGlobalBuffer: maxGlobalBuffer, maxPerRunBuffer: maxPerRunBuffer)
        let tally = TraceDropTally()
        let wr = SQLiteWriter(db: database, buffer: buf, dropTally: tally)

        self.db = database
        self.buffer = buf
        self.writer = wr
        self.dropTally = tally
        
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
                priority INTEGER NOT NULL,
                sequence INTEGER NOT NULL,
                engine TEXT,
                span_id TEXT,
                parent_span_id TEXT,
                type TEXT NOT NULL,
                payload BLOB NOT NULL,
                timestamp INTEGER NOT NULL
            );
            """)
            
            // Backwards compatibility for existing databases
            try? database.execute("ALTER TABLE trace_events ADD COLUMN span_id TEXT;")
            try? database.execute("ALTER TABLE trace_events ADD COLUMN parent_span_id TEXT;")
            
            // Critical indices
            try database.execute("CREATE INDEX IF NOT EXISTS idx_run_id ON trace_events(run_id);")
            try database.execute("CREATE INDEX IF NOT EXISTS idx_type ON trace_events(type);")
            try database.execute("CREATE INDEX IF NOT EXISTS idx_run_type ON trace_events(run_id, type);")
            try database.execute("CREATE INDEX IF NOT EXISTS idx_timestamp ON trace_events(timestamp);")
            try database.execute("CREATE INDEX IF NOT EXISTS idx_run_sequence ON trace_events(run_id, sequence);")
            try database.execute("CREATE INDEX IF NOT EXISTS idx_priority ON trace_events(priority);")
            // Recency listing (e.g. the inspector's "all runs, newest first") sorts on
            // runs.start_time; without this index it degrades to a full-table sort as the
            // corpus grows.
            try database.execute("CREATE INDEX IF NOT EXISTS idx_runs_start_time ON runs(start_time);")
            
            if database.userVersion < 2 {
                try database.execute("""
                CREATE TABLE IF NOT EXISTS trace_edges (
                    source_id TEXT NOT NULL,
                    target_id TEXT NOT NULL,
                    edge_type TEXT NOT NULL
                );
                """)
                try database.execute("CREATE INDEX IF NOT EXISTS idx_edge_source ON trace_edges(source_id, edge_type);")
                try database.execute("CREATE INDEX IF NOT EXISTS idx_edge_target ON trace_edges(target_id, edge_type);")
                database.userVersion = 2
            }
            
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

        // Opened after the schema is committed so the reader sees the tables; WAL then
        // keeps it isolated from the writer's in-flight transactions from here on.
        self.readDB = try SQLiteConnection(fileURL: fileURL)

        Task {
            await self.writer.start()
        }
    }
    
    public func record(_ event: TraceEvent<T>) {
        guard let payloadData = try? encoder.encode(event.payload) else {
            // An unencodable payload can't be persisted — but it must not vanish
            // silently. Count it in its own tier so the loss shows up in dropStats.
            dropTally.record(priority: event.payload.priority.rawValue)
            return
        }
        
        let row = TraceEventRow(
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
            timestamp: Int64(event.timestamp.timeIntervalSince1970 * 1_000_000)
        )
        
        buffer.enqueue(row)
    }

    public func link(source: UUID, target: UUID, type: TraceEdgeType) {
        buffer.enqueueEdge(TraceEdge(sourceID: source, targetID: target, type: type))
    }
    
    public func flush() async throws {
        try await writer.flush()
    }

    /// Every event this store failed to retain, by priority tier: the write buffer's
    /// congestion drops plus events lost outside it — payloads that could not be encoded
    /// and batches the writer failed to persist. `preservedIntegrity` is `true` when no
    /// `structural` or `critical` event was lost by any path, i.e. when diffs over these
    /// runs are fully trustworthy.
    public var dropStats: TraceDropStats {
        buffer.dropStats + dropTally.snapshot
    }
    
    public func queryRuns(_ dsl: TraceQueryDSL<T>) async throws -> [TraceRun<T>] {
        try await queryRuns(dsl, limit: nil)
    }

    public func queryRuns(_ dsl: TraceQueryDSL<T>, limit: Int?) async throws -> [TraceRun<T>] {
        // Ensure all pending events are flushed before querying so results are accurate
        try await flush()

        let compiled = TraceQueryCompiler.compile(node: dsl.ast)
        let stmt = try readDB.prepare(compiled.sql)
        for (i, binding) in compiled.bindings.enumerated() {
            try stmt.bind(binding, at: Int32(i + 1))
        }

        var runIDs: [String] = []
        while try stmt.step() {
            if let runID = stmt.columnString(at: 0) {
                runIDs.append(runID)
            }
        }

        // Cap BEFORE hydration: matching one full run means N per-run fetches, so
        // bounding the id list here is what actually saves work on a large corpus,
        // not trimming the hydrated array afterward.
        if let limit, limit >= 0 {
            runIDs = Array(runIDs.prefix(limit))
        }

        var runs: [TraceRun<T>] = []
        for idString in runIDs {
            guard let uuid = UUID(uuidString: idString) else { continue }
            if let run = try await fetchRun(id: uuid) {
                runs.append(run)
            }
        }
        return runs
    }
    
    public func getRun(id: UUID) async throws -> TraceRun<T>? {
        // Flush pending writes first so a run recorded moments ago is visible, matching
        // `queryRuns`' read-your-writes contract.
        try await flush()
        return try await fetchRun(id: id)
    }

    private func fetchRun(id: UUID) async throws -> TraceRun<T>? {
        // Select `id` too: the recorded TraceEvent.id must survive the round-trip, or a
        // fresh UUID is minted on read and lineage edges (keyed on the original id) and
        // the exported dpk.event_id no longer line up.
        let sql = "SELECT id, engine, span_id, parent_span_id, type, payload, timestamp, sequence FROM trace_events WHERE run_id = ? ORDER BY sequence ASC"
        let stmt = try readDB.prepare(sql)
        try stmt.bind(id.uuidString, at: 1)

        var events: [TraceEvent<T>] = []
        let decoder = JSONDecoder()

        // Fetch context_id from the runs table
        let ctxStmt = try readDB.prepare("SELECT context_id FROM runs WHERE run_id = ?")
        try ctxStmt.bind(id.uuidString, at: 1)
        guard try ctxStmt.step(), let contextID = ctxStmt.columnString(at: 0) else {
            return nil
        }

        while try stmt.step() {
            let eventID = stmt.columnString(at: 0).flatMap(UUID.init(uuidString:)) ?? UUID()
            let engine = stmt.columnString(at: 1)
            let spanID = stmt.columnString(at: 2)
            let parentSpanID = stmt.columnString(at: 3)
            _ = stmt.columnString(at: 4) // type
            let payloadData = stmt.columnData(at: 5)
            let timestampMs = stmt.columnInt64(at: 6)
            let sequence = UInt64(stmt.columnInt64(at: 7))

            if let payload = try? decoder.decode(T.self, from: payloadData) {
                let event = TraceEvent(
                    id: eventID,
                    runID: id,
                    contextID: contextID,
                    engineName: engine ?? "Unknown",
                    schemaVersion: 1,
                    sequence: sequence,
                    spanID: spanID,
                    parentSpanID: parentSpanID,
                    payload: payload,
                    timestamp: Date(timeIntervalSince1970: Double(timestampMs) / 1_000_000.0)
                )
                events.append(event)
            }
        }
        
        guard !events.isEmpty else { return nil }
        return TraceRun(runID: id, contextID: contextID, events: events)
    }

    public func lineageEdges(of id: UUID) async throws -> [TraceEdge] {
        // Ensure pending edges are flushed so we get the complete graph
        try await flush()
        
        // UNION (not UNION ALL) deduplicates rows, so traversal terminates even when
        // the edge set contains a cycle: once every reachable edge is in the result,
        // the recursive step yields no new rows. It also removes duplicate edges that
        // multiple paths would otherwise produce.
        let sql = """
        WITH RECURSIVE lineage_cte(source_id, target_id, edge_type) AS (
            SELECT source_id, target_id, edge_type
            FROM trace_edges
            WHERE target_id = ?
            UNION
            SELECT e.source_id, e.target_id, e.edge_type
            FROM trace_edges e
            JOIN lineage_cte l ON e.target_id = l.source_id
        )
        SELECT source_id, target_id, edge_type FROM lineage_cte;
        """
        
        let stmt = try readDB.prepare(sql)
        try stmt.bind(id.uuidString, at: 1)
        
        var edges: [TraceEdge] = []
        while try stmt.step() {
            guard let sourceStr = stmt.columnString(at: 0),
                  let targetStr = stmt.columnString(at: 1),
                  let typeStr = stmt.columnString(at: 2),
                  let sourceUUID = UUID(uuidString: sourceStr),
                  let targetUUID = UUID(uuidString: targetStr) else {
                continue
            }
            edges.append(TraceEdge(sourceID: sourceUUID, targetID: targetUUID, type: TraceEdgeType(rawValue: typeStr) ?? .informed))
        }
        return edges
    }
    
    public func impactEdges(of id: UUID) async throws -> [TraceEdge] {
        try await flush()
        
        // UNION (not UNION ALL) deduplicates rows, so traversal terminates even when
        // the edge set contains a cycle, and returns distinct edges.
        let sql = """
        WITH RECURSIVE impact_cte(source_id, target_id, edge_type) AS (
            SELECT source_id, target_id, edge_type
            FROM trace_edges
            WHERE source_id = ?
            UNION
            SELECT e.source_id, e.target_id, e.edge_type
            FROM trace_edges e
            JOIN impact_cte l ON e.source_id = l.target_id
        )
        SELECT source_id, target_id, edge_type FROM impact_cte;
        """
        
        let stmt = try readDB.prepare(sql)
        try stmt.bind(id.uuidString, at: 1)
        
        var edges: [TraceEdge] = []
        while try stmt.step() {
            guard let sourceStr = stmt.columnString(at: 0),
                  let targetStr = stmt.columnString(at: 1),
                  let typeStr = stmt.columnString(at: 2),
                  let sourceUUID = UUID(uuidString: sourceStr),
                  let targetUUID = UUID(uuidString: targetStr) else {
                continue
            }
            edges.append(TraceEdge(sourceID: sourceUUID, targetID: targetUUID, type: TraceEdgeType(rawValue: typeStr) ?? .informed))
        }
        return edges
    }
    
    public func getEvents(ids: Set<UUID>) async throws -> [UUID: TraceEvent<T>] {
        if ids.isEmpty { return [:] }
        try await flush()
        
        // SQLite limits IN clauses, so we batch if necessary, but graphs are usually small.
        let idStrings = ids.map { $0.uuidString }
        let placeholders = Array(repeating: "?", count: idStrings.count).joined(separator: ", ")
        
        let sql = """
        SELECT e.id, e.run_id, r.context_id, e.engine, e.span_id, e.parent_span_id, e.payload, e.timestamp, e.sequence 
        FROM trace_events e
        JOIN runs r ON e.run_id = r.run_id
        WHERE e.id IN (\(placeholders))
        """
        
        let stmt = try readDB.prepare(sql)
        for (i, idString) in idStrings.enumerated() {
            try stmt.bind(idString, at: Int32(i + 1))
        }
        
        var events: [UUID: TraceEvent<T>] = [:]
        let decoder = JSONDecoder()
        
        while try stmt.step() {
            guard let idStr = stmt.columnString(at: 0),
                  let runIDStr = stmt.columnString(at: 1),
                  let contextID = stmt.columnString(at: 2),
                  let engine = stmt.columnString(at: 3),
                  let id = UUID(uuidString: idStr),
                  let runID = UUID(uuidString: runIDStr) else {
                continue
            }
            
            let payloadData = stmt.columnData(at: 6)
            
            let spanID = stmt.columnString(at: 4)
            let parentSpanID = stmt.columnString(at: 5)
            let timestampMs = stmt.columnInt64(at: 7)
            let sequence = UInt64(stmt.columnInt64(at: 8))
            
            if let payload = try? decoder.decode(T.self, from: payloadData) {
                let event = TraceEvent(
                    id: id,
                    runID: runID,
                    contextID: contextID,
                    engineName: engine,
                    schemaVersion: 1,
                    sequence: sequence,
                    spanID: spanID,
                    parentSpanID: parentSpanID,
                    payload: payload,
                    timestamp: Date(timeIntervalSince1970: Double(timestampMs) / 1_000_000.0)
                )
                events[id] = event
            }
        }
        
        return events
    }
}
