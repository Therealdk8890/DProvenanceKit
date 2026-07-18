import Foundation

public final class SQLiteTraceStore<T: TraceableEvent>: TraceStore, @unchecked Sendable {
    private let db: SQLiteConnection
    private let fileURL: URL
    /// A second connection to the same file, used only for reads. The writer's
    /// inserts bind/step between BEGIN and COMMIT on `db`, and a reader sharing that
    /// connection would see its own uncommitted rows mid-transaction. On a separate
    /// connection, WAL gives the reader a committed snapshot, so a query can never
    /// observe a half-written batch. Reads flush the writer first, so "committed"
    /// includes everything recorded before the read.
    ///
    /// Mutable only inside `close()`, which must close it (exiting WAL mode requires
    /// being the file's sole connection) and reopens it strictly read-only. All read
    /// paths go through `reader()`, which hands out the current connection under
    /// `closedLock`.
    private var readDB: SQLiteConnection
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

    /// Guards `isClosed`, `closeTask`, and `readDB` reassignment. The store-level
    /// `isClosed` check in `record()` is a fast path only — the authoritative gate is
    /// inside `TraceWriteBuffer`, whose closed-check shares the buffer's own lock with
    /// the enqueue, so a record racing `close()` is either drained by the writer's
    /// final flush or counted as dropped, never stranded.
    private let closedLock = NSLock()
    private var isClosed = false
    /// The single in-flight (or completed) close. Every `close()` caller awaits the
    /// same task, so a second concurrent `close()` cannot return before the first has
    /// actually finished draining and quiescing.
    private var closeTask: Task<Bool, Never>?

    private var closedNow: Bool {
        closedLock.lock()
        defer { closedLock.unlock() }
        return isClosed
    }

    private func reader() -> SQLiteConnection {
        closedLock.lock()
        defer { closedLock.unlock() }
        return readDB
    }

    /// Lowercased `trace_events` column names. SQLite compares identifiers
    /// case-insensitively (an `ALTER … ADD COLUMN span_id` fails "duplicate column"
    /// against an existing `SPAN_ID`), so the presence check must be
    /// case-insensitive too or a legacy DB with non-lowercase columns would make
    /// the guarded ALTER below throw where it should no-op.
    private static func traceEventColumnNames(in database: SQLiteConnection) throws -> Set<String> {
        let statement = try database.prepare("PRAGMA table_info(trace_events);")
        var names = Set<String>()
        while try statement.step() {
            if let name = statement.columnString(at: 1) {
                names.insert(name.lowercased())
            }
        }
        return names
    }

    public init(fileURL: URL, maxGlobalBuffer: Int = 50_000, maxPerRunBuffer: Int = 5_000) throws {
        let database = try SQLiteConnection(fileURL: fileURL)
        let buf = TraceWriteBuffer(maxGlobalBuffer: maxGlobalBuffer, maxPerRunBuffer: maxPerRunBuffer)
        let tally = TraceDropTally()
        let wr = SQLiteWriter(db: database, buffer: buf, dropTally: tally)

        self.fileURL = fileURL
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
                timestamp INTEGER NOT NULL,
                schema_version INTEGER NOT NULL DEFAULT 1
            );
            """)

            // Backwards compatibility for databases created before these columns.
            // Check first instead of swallowing duplicate-column errors: SQLite logs
            // failed ALTER statements before Swift can catch them, and `try?` would
            // also hide genuine migration failures.
            let eventColumns = try Self.traceEventColumnNames(in: database)
            if !eventColumns.contains("span_id") {
                try database.execute("ALTER TABLE trace_events ADD COLUMN span_id TEXT;")
            }
            if !eventColumns.contains("parent_span_id") {
                try database.execute("ALTER TABLE trace_events ADD COLUMN parent_span_id TEXT;")
            }
            // Rows written before the column existed carry version 1, the only schema
            // version that shipped without it.
            if !eventColumns.contains("schema_version") {
                try database.execute("ALTER TABLE trace_events ADD COLUMN schema_version INTEGER NOT NULL DEFAULT 1;")
            }
            
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
        if closedNow {
            // The background writer is gone, so this event can never reach disk. Count
            // the loss in its tier — a write after close() must not vanish silently.
            // (Fast path only: a record that slips past this check mid-close is caught
            // and counted by the buffer's own gate.)
            dropTally.record(priority: event.payload.priority.rawValue)
            return
        }

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
            timestamp: Int64(event.timestamp.timeIntervalSince1970 * 1_000_000),
            schemaVersion: event.schemaVersion
        )

        buffer.enqueue(row)
    }

    public func link(source: UUID, target: UUID, type: TraceEdgeType) {
        // No closed-check here: the buffer's gate discards, logs, and counts an edge
        // linked after close() as a structural loss, atomically with its own lock.
        buffer.enqueueEdge(TraceEdge(sourceID: source, targetID: target, type: type))
    }

    public func flush() async throws {
        // After close() the writer has already drained everything it will ever drain,
        // and its run-metadata flush would WRITE to the quiesced file (`force: true`
        // re-stages every run). Reads triggered after close() must not touch the file.
        if closedNow { return }
        try await writer.flush()
    }

    /// Flushes every pending event and edge, stops the background writer, and folds the
    /// WAL back into the main database file, leaving it in rollback-journal mode when
    /// possible. Call this before archiving or rotating a store file — see the retention
    /// pattern in `docs/ATTESTATION.md`.
    ///
    /// Returns `true` when the `.sqlite` file alone is a complete archive of the store
    /// (every WAL frame folded in). Returns `false` when a concurrent reader pinned the
    /// WAL so the fold could not complete — in that case keep the `-wal`/`-shm`
    /// companions next to the file when archiving it. The result is computed once;
    /// subsequent calls await the same close and return the same answer.
    ///
    /// Reads (`queryRuns`, `getRun`, lineage traversal) remain available after `close()`
    /// through a read-only connection that cannot modify the archived file — but only
    /// while the file stays at its path. SQLite forbids renaming a database out from
    /// under an open connection, so once the file is rotated away this handle's reads
    /// throw (`SQLITE_IOERR`); read the archive through a fresh `RawTraceStore` instead.
    /// Events recorded after `close()` are counted in `dropStats` like any other loss,
    /// and edges linked after `close()` are counted as structural losses.
    @discardableResult
    public func close() async -> Bool {
        await ensureCloseTask().value
    }

    /// Creates the single close task on first call; synchronous because `NSLock` may
    /// not be held across suspension points.
    private func ensureCloseTask() -> Task<Bool, Never> {
        closedLock.lock()
        defer { closedLock.unlock() }
        if closeTask == nil {
            isClosed = true
            // Gate the buffer BEFORE the writer's final drain: everything admitted up
            // to this point is persisted by shutdown(); everything after is counted.
            buffer.close()
            closeTask = Task { [self] in
                await writer.shutdown()
                return quiesceFile()
            }
        }
        return closeTask!
    }

    /// Runs after the writer has fully stopped. Returns whether the `.sqlite` file
    /// alone is a complete archive.
    private func quiesceFile() -> Bool {
        // Fold the -wal into the main file. The busy column must be inspected: SQLite
        // reports a blocked checkpoint as SQLITE_OK with busy=1, so exec-and-ignore
        // would silently rotate an archive that is missing committed events.
        var checkpointComplete = false
        if let stmt = try? db.prepare("PRAGMA wal_checkpoint(TRUNCATE);"),
           (try? stmt.step()) == true {
            checkpointComplete = stmt.columnInt(at: 0) == 0
        }

        // Exiting WAL mode requires being the file's only connection, so the read
        // connection must close first; it reopens strictly read-only below. (With it
        // open, the pragma fails SQLITE_BUSY unconditionally — verified empirically.)
        reader().close()

        // Leave the file in rollback-journal mode so the archived artifact is readable
        // by ANY read-only client (a bare WAL-mode file needs an immutable open; a
        // rollback-mode file does not). The flip performs its own full checkpoint, so
        // its success also proves completeness. The next SQLiteTraceStore opened at
        // this path switches the file back to WAL.
        var flipped = false
        if let stmt = try? db.prepare("PRAGMA journal_mode=DELETE;"),
           (try? stmt.step()) == true {
            flipped = stmt.columnString(at: 0)?.lowercased() == "delete"
        }

        // Restore post-close reads on a connection that can never write the archive.
        if let reopened = try? SQLiteConnection(fileURL: fileURL, mode: .readOnly) {
            closedLock.lock()
            readDB = reopened
            closedLock.unlock()
        }

        if !flipped && !checkpointComplete {
            DPKLog.store.error("close() could not fold the WAL (a concurrent reader is pinning it); the .sqlite file alone is NOT a complete archive — keep the -wal/-shm files with it.")
        } else if !flipped {
            DPKLog.store.warning("close() folded the WAL but the file stays in WAL mode; a bare copy needs an immutable read-only open (RawTraceStore does this automatically).")
        }
        return flipped || checkpointComplete
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
        let stmt = try reader().prepare(compiled.sql)
        for (i, binding) in compiled.bindings.enumerated() {
            try stmt.bind(binding, at: Int32(i + 1))
        }

        var runIDs: [String] = []
        while try stmt.step() {
            if let runID = stmt.columnString(at: 0) {
                runIDs.append(runID)
            }
        }

        // A payload predicate can't be pushed into SQL, so the compiled query returns a
        // candidate SUPERSET; the authoritative filter is the in-process evaluator, run
        // after hydration. Structural-only queries compile exactly, so they trust the SQL.
        let needsInProcessFilter = dsl.ast.hasPayloadPredicate

        // Cap BEFORE hydration only when the SQL is exact — bounding the id list is what
        // saves the N per-run fetches. With a payload predicate the ids are a superset,
        // so we must hydrate every candidate, refine, then apply the limit afterward.
        if let limit, limit >= 0, !needsInProcessFilter {
            runIDs = Array(runIDs.prefix(limit))
        }

        var runs: [TraceRun<T>] = []
        for idString in runIDs {
            guard let uuid = UUID(uuidString: idString) else { continue }
            guard let run = try await fetchRun(id: uuid) else { continue }
            if needsInProcessFilter {
                // A payload predicate can neither match nor clear a run with zero
                // decodable events: evaluating one over the empty array would report
                // "no event matches" for payloads that were never inspectable, so a
                // NEGATED predicate would positively assert such a run is clean.
                // Excluding it here keeps payload queries scoped to runs whose
                // payloads can actually be read (structural queries still surface it).
                guard !run.events.isEmpty || run.undecodedEventCount == 0 else { continue }
                if !dsl.ast.evaluate(run: run) { continue }
            }
            runs.append(run)
        }

        if let limit, limit >= 0, needsInProcessFilter {
            runs = Array(runs.prefix(limit))
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
        let sql = "SELECT id, engine, span_id, parent_span_id, type, payload, timestamp, sequence, schema_version FROM trace_events WHERE run_id = ? ORDER BY sequence ASC"
        let stmt = try reader().prepare(sql)
        try stmt.bind(id.uuidString, at: 1)

        var events: [TraceEvent<T>] = []
        var undecodedCount = 0
        let decoder = JSONDecoder()

        // Fetch context_id from the runs table
        let ctxStmt = try reader().prepare("SELECT context_id FROM runs WHERE run_id = ?")
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
            // Authoritative as stored: legacy rows were backfilled to the column's
            // NOT NULL DEFAULT 1 by the ALTER in init, and a recorded value — even an
            // unconventional 0 — must round-trip unchanged or attestation digests
            // computed before and after a reload diverge.
            let schemaVersion = Int(stmt.columnInt64(at: 8))

            if let payload = try? decoder.decode(T.self, from: payloadData) {
                let event = TraceEvent(
                    id: eventID,
                    runID: id,
                    contextID: contextID,
                    engineName: engine ?? "Unknown",
                    schemaVersion: schemaVersion,
                    sequence: sequence,
                    spanID: spanID,
                    parentSpanID: parentSpanID,
                    payload: payload,
                    timestamp: Date(timeIntervalSince1970: Double(timestampMs) / 1_000_000.0)
                )
                events.append(event)
            } else {
                // The row is durably on disk but its payload no longer decodes as `T`
                // (schema drift or corruption). Omitting it silently would present a
                // subset as the whole run — and hide the run entirely if every row
                // failed — so the miss is counted on the returned run instead.
                undecodedCount += 1
            }
        }

        // nil means "this run has no persisted events" — it must NOT mean "the events
        // exist but none decode as T", or payload-schema drift makes whole runs vanish
        // from getRun/queryRuns while their rows sit on disk.
        guard !events.isEmpty || undecodedCount > 0 else { return nil }
        if undecodedCount > 0 {
            DPKLog.store.error("fetchRun(\(id.uuidString, privacy: .public)): \(undecodedCount) of \(events.count + undecodedCount) persisted events failed to decode as \(String(describing: T.self), privacy: .public) and are omitted; see TraceRun.undecodedEventCount")
        }
        return TraceRun(
            runID: id,
            contextID: contextID,
            events: events,
            undecodedEventCount: undecodedCount
        )
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
        
        let stmt = try reader().prepare(sql)
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
        
        let stmt = try reader().prepare(sql)
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
        
        // SQLite caps bound parameters per statement (999 before 3.32, 32766 stock
        // after, higher on Apple's build). Lineage/impact closures pass unbounded id
        // sets, so chunk below the oldest cap rather than trust whichever build is
        // linked. The result is a dictionary, so per-chunk merge order is irrelevant.
        let chunkSize = 900
        let idStrings = ids.map { $0.uuidString }

        var events: [UUID: TraceEvent<T>] = [:]
        var undecodedCount = 0
        let decoder = JSONDecoder()

        for chunkStart in stride(from: 0, to: idStrings.count, by: chunkSize) {
            let chunk = idStrings[chunkStart..<min(chunkStart + chunkSize, idStrings.count)]
            try fetchEventsChunk(chunk, decoder: decoder, into: &events, undecodedCount: &undecodedCount)
        }

        if undecodedCount > 0 {
            DPKLog.store.error("getEvents: \(undecodedCount) of \(events.count + undecodedCount) matching persisted events failed to decode as \(String(describing: T.self), privacy: .public) and are omitted from the result")
        }
        return events
    }

    private func fetchEventsChunk(
        _ chunk: ArraySlice<String>,
        decoder: JSONDecoder,
        into events: inout [UUID: TraceEvent<T>],
        undecodedCount: inout Int
    ) throws {
        let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")

        let sql = """
        SELECT e.id, e.run_id, r.context_id, e.engine, e.span_id, e.parent_span_id, e.payload, e.timestamp, e.sequence, e.schema_version
        FROM trace_events e
        JOIN runs r ON e.run_id = r.run_id
        WHERE e.id IN (\(placeholders))
        """

        let stmt = try reader().prepare(sql)
        for (i, idString) in chunk.enumerated() {
            try stmt.bind(idString, at: Int32(i + 1))
        }

        while try stmt.step() {
            guard let idStr = stmt.columnString(at: 0),
                  let runIDStr = stmt.columnString(at: 1),
                  let contextID = stmt.columnString(at: 2),
                  let id = UUID(uuidString: idStr),
                  let runID = UUID(uuidString: runIDStr) else {
                continue
            }
            // NULL engine is data, not malformation — fetchRun reads the same rows as
            // "Unknown", and a guard here would silently drop them from this path only.
            let engine = stmt.columnString(at: 3) ?? "Unknown"

            let payloadData = stmt.columnData(at: 6)

            let spanID = stmt.columnString(at: 4)
            let parentSpanID = stmt.columnString(at: 5)
            let timestampMs = stmt.columnInt64(at: 7)
            let sequence = UInt64(stmt.columnInt64(at: 8))
            // Authoritative as stored (see fetchRun): the migration backfills legacy
            // rows to 1, so no read-side coercion may rewrite a recorded value.
            let schemaVersion = Int(stmt.columnInt64(at: 9))

            if let payload = try? decoder.decode(T.self, from: payloadData) {
                let event = TraceEvent(
                    id: id,
                    runID: runID,
                    contextID: contextID,
                    engineName: engine,
                    schemaVersion: schemaVersion,
                    sequence: sequence,
                    spanID: spanID,
                    parentSpanID: parentSpanID,
                    payload: payload,
                    timestamp: Date(timeIntervalSince1970: Double(timestampMs) / 1_000_000.0)
                )
                events[id] = event
            } else {
                // Same contract as fetchRun: a persisted row that no longer decodes as
                // `T` must not vanish silently. Callers detect the miss as a requested
                // id absent from the result; the log carries the count.
                undecodedCount += 1
            }
        }
    }
}
