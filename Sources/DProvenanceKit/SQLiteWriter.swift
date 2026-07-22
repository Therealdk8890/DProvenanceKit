import Foundation
import CryptoKit

/// Background writer that periodically drains the buffer and executes batched INSERTs.
public actor SQLiteWriter {
    private let db: SQLiteConnection
    private let buffer: TraceWriteBuffer
    /// Where losses from a failed batch insert are recorded so they surface in the
    /// store's `dropStats`/`preservedIntegrity` instead of vanishing silently.
    private let dropTally: TraceDropTally
    private var writeTask: Task<Void, Never>?
    private var isShuttingDown = false

    // EMA smoothing state
    private var smoothedLoad: Double = 0
    private let alpha: Double = 0.2 // Smoothing factor

    // Adaptive idle cadence: when the buffer is empty the loop backs off geometrically
    // from `baseIdleSleepMs` up to `maxIdleSleepMs` so a quiet writer isn't waking
    // ~20×/second to drain nothing. The next enqueued event resets it on the next tick.
    private let baseIdleSleepMs: UInt64 = 50
    private let maxIdleSleepMs: UInt64 = 500
    private var idleSleepMs: UInt64 = 50

    private var lastRunFlushTime: TimeInterval = Date().timeIntervalSince1970
    
    // Incremental run state cache to throttle UPSERTs to the `runs` table
    private struct RunState {
        var contextID: String
        var startTime: Int64
        var latestTime: Int64
        var eventCount: Int
        var fingerprintHash: Insecure.SHA1
        var isDirty: Bool
        /// Wall-clock time (seconds since 1970) this run last received an event. Drives
        /// the idle-eviction sweep in `runMaintenance`.
        var lastTouchTime: TimeInterval
    }

    private var activeRuns: [String: RunState] = [:]

    /// Upper bound on cached run states. `activeRuns` holds one entry per run the writer
    /// has folded metadata for, and nothing in the event stream signals "run complete",
    /// so without a bound a long-lived process accumulates one entry per distinct run_id
    /// forever — and rescans them all every flush. Idle entries are dropped by the
    /// periodic maintenance pass; this cap is the hard backstop for a burst of concurrent
    /// runs that outpaces the idle window. An evicted run re-seeds its count from the
    /// persisted `runs.event_count` on its next event (see `updateRunState`), so eviction
    /// never under-counts.
    private let maxActiveRuns: Int

    /// A cached run untouched for longer than this (seconds) is treated as complete and
    /// dropped on the next maintenance pass. Re-seeding makes this safe even if it resumes.
    private let activeRunIdleEvictionSeconds: TimeInterval

    /// The re-seed SELECT, prepared once and reused (reset per call) so a workload with
    /// high run cardinality doesn't re-parse it on every first-touch. Lazily created
    /// because `runs` may not exist at init time (a bare writer over a not-yet-migrated
    /// file); prepared on first use, when the table is guaranteed present. Actor-isolated
    /// like every other cache field.
    private var eventCountStmt: SQLiteStatement?

    public init(
        db: SQLiteConnection,
        buffer: TraceWriteBuffer,
        dropTally: TraceDropTally = TraceDropTally(),
        maxActiveRuns: Int = 50_000,
        activeRunIdleEvictionSeconds: TimeInterval = 300
    ) {
        self.db = db
        self.buffer = buffer
        self.dropTally = dropTally
        self.maxActiveRuns = maxActiveRuns
        self.activeRunIdleEvictionSeconds = activeRunIdleEvictionSeconds
        // The INSERT names schema_version, but consumers may pair this writer with a
        // connection to a pre-existing store file directly (bypassing
        // SQLiteTraceStore's migration). Migrate here too, or every batch against a
        // legacy file would fail and be tallied as dropped. Harmless when the table
        // doesn't exist yet or the column is already present.
        try? db.execute("ALTER TABLE trace_events ADD COLUMN schema_version INTEGER NOT NULL DEFAULT 1;")
    }
    
    public func start() {
        guard writeTask == nil else { return }
        writeTask = Task.detached { [weak self] in
            while true {
                guard let self = self else { break }
                let isShuttingDown = await self.isShuttingDown
                if isShuttingDown { break }
                
                await self.tick()
            }
        }
    }
    
    public func flush() async throws {
        await processBatch(drainAll: true)
        let stagedRunIDs = try db.transaction {
            try flushRunsTable(force: true)
        }
        markRunsClean(stagedRunIDs)
    }
    
    public func shutdown() async {
        isShuttingDown = true
        await writeTask?.value
        await processBatch(drainAll: true)
        if let stagedRunIDs = try? db.transaction({
            try flushRunsTable(force: true)
        }) {
            markRunsClean(stagedRunIDs)
        }
    }
    
    private func tick() async {
        let depth = buffer.currentDepth
        smoothedLoad = (alpha * Double(depth)) + ((1.0 - alpha) * smoothedLoad)
        
        let batchSize: Int
        let sleepMs: UInt64
        
        if smoothedLoad > 5_000 {
            // High load
            batchSize = 5_000
            sleepMs = UInt64.random(in: 0...5)
            idleSleepMs = baseIdleSleepMs
        } else if smoothedLoad > 500 {
            // Medium load
            batchSize = 1_000
            sleepMs = UInt64.random(in: 10...20)
            idleSleepMs = baseIdleSleepMs
        } else {
            batchSize = 500
            if depth > 0 {
                // Light but non-empty: stay responsive.
                sleepMs = baseIdleSleepMs
                idleSleepMs = baseIdleSleepMs
            } else {
                // Genuinely idle: back off geometrically up to the cap to save power.
                // flush()/shutdown() drain directly and never wait on this loop, so the
                // only effect of a longer sleep is a wider crash-durability window for
                // events recorded while idle — bounded by maxIdleSleepMs.
                sleepMs = idleSleepMs
                idleSleepMs = Swift.min(idleSleepMs * 2, maxIdleSleepMs)
            }
        }

        await processBatch(maxBatch: batchSize)
        
        // Throttled UPSERTs (every 1s)
        let now = Date().timeIntervalSince1970
        if now - lastRunFlushTime > 1.0 {
            do {
                let stagedRunIDs = try db.transaction {
                    try flushRunsTable()
                }
                markRunsClean(stagedRunIDs)
                runMaintenance(now: now)
                lastRunFlushTime = now
            } catch {
                DPKLog.store.error("SQLiteWriter failed to flush runs: \(String(describing: error), privacy: .public)")
            }
        }
        
        if sleepMs > 0 {
            try? await Task.sleep(nanoseconds: sleepMs * 1_000_000)
        }
    }
    
    private func processBatch(drainAll: Bool = false, maxBatch: Int = 1000) async {
        let batch = drainAll ? buffer.flushAll() : buffer.drain(max: maxBatch)
        let edgesBatch = buffer.drainEdges()
        
        guard !batch.isEmpty || !edgesBatch.isEmpty else { return }
        
        do {
            try db.transaction {
                if !batch.isEmpty {
                    try insert(batch)
                }
                if !edgesBatch.isEmpty {
                    try insertEdges(edgesBatch)
                }
            }
            // The rows are durably committed, so it is now safe to fold them into the
            // in-memory run metadata. Doing this *after* commit — not per-event inside
            // the transaction — keeps event_count and the fingerprint consistent with
            // what is actually on disk; a rolled-back batch never inflates them.
            let now = Date().timeIntervalSince1970
            for event in batch {
                updateRunState(for: event, now: now)
            }
        } catch {
            // The transaction rolled back: these rows were already drained out of the
            // buffer and are now gone. Count the loss per tier so it surfaces in
            // dropStats/preservedIntegrity instead of being a silent drop that still
            // reports the run as fully retained.
            for event in batch {
                dropTally.record(priority: event.priority)
            }
            // Edges are structural data (they change what lineage traversal and an
            // attestation's edge set contain), so a lost edge must flip
            // preservedIntegrity exactly like a lost structural event — including
            // when the failed batch contained only edges.
            if !edgesBatch.isEmpty {
                dropTally.record(priority: TracePriority.structural.rawValue, count: UInt64(edgesBatch.count))
            }
            DPKLog.store.error("SQLiteWriter failed to insert batch of \(batch.count) events and \(edgesBatch.count) edges: \(String(describing: error), privacy: .public)")
        }
    }
    
    private func insertEdges(_ edges: [TraceEdge]) throws {
        let insertSQL = """
        INSERT INTO trace_edges (source_id, target_id, edge_type)
        VALUES (?, ?, ?);
        """
        let stmt = try db.prepare(insertSQL)
        
        for edge in edges {
            try stmt.bind(edge.sourceID.uuidString, at: 1)
            try stmt.bind(edge.targetID.uuidString, at: 2)
            try stmt.bind(edge.type.rawValue, at: 3)
            
            _ = try stmt.step()
            stmt.reset()
        }
    }
    
    private func insert(_ events: [TraceEventRow]) throws {
        let insertSQL = """
        INSERT INTO trace_events (id, run_id, context_id, priority, sequence, engine, span_id, parent_span_id, type, payload, timestamp, schema_version)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        let stmt = try db.prepare(insertSQL)
        
        for event in events {
            try stmt.bind(event.id, at: 1)
            try stmt.bind(event.runID, at: 2)
            try stmt.bind(event.contextID, at: 3)
            try stmt.bind(Int64(event.priority), at: 4)
            try stmt.bind(event.sequence, at: 5)
            if let engine = event.engine {
                try stmt.bind(engine, at: 6)
            } else {
                try stmt.bindNull(at: 6)
            }
            if let spanID = event.spanID {
                try stmt.bind(spanID, at: 7)
            } else {
                try stmt.bindNull(at: 7)
            }
            if let parentSpanID = event.parentSpanID {
                try stmt.bind(parentSpanID, at: 8)
            } else {
                try stmt.bindNull(at: 8)
            }
            try stmt.bind(event.type, at: 9)
            try stmt.bind(event.payload, at: 10)
            try stmt.bind(event.timestamp, at: 11)
            try stmt.bind(Int64(event.schemaVersion), at: 12)

            _ = try stmt.step()
            stmt.reset()
        }
    }
    
    private func updateRunState(for event: TraceEventRow, now: TimeInterval) {
        let runID = event.runID
        var state: RunState
        if let existing = activeRuns[runID] {
            state = existing
        } else {
            // First time this process folds metadata for `runID` — either a brand-new run
            // (no persisted row yet) or one whose cache entry was evicted for being idle.
            // Seed the count from the persisted `runs` row so a resumed run continues from
            // its true cumulative total; otherwise the next UPSERT overwrites
            // runs.event_count (which RawTraceStore surfaces) with only the events seen
            // since this touch. The streaming fingerprint hash cannot be resumed from the
            // stored digest (SHA1 is one-way), so it restarts and thereafter covers only
            // post-seed events — acceptable because runs.fingerprint is written but never
            // read anywhere in the library.
            state = RunState(
                contextID: event.contextID,
                startTime: event.timestamp,
                latestTime: event.timestamp,
                eventCount: persistedEventCount(runID: runID) ?? 0,
                fingerprintHash: Insecure.SHA1(),
                isDirty: false,
                lastTouchTime: now
            )
        }

        state.latestTime = event.timestamp
        state.eventCount += 1
        state.isDirty = true
        state.lastTouchTime = now

        // Incremental fingerprinting
        let signature = "\(event.type):\(event.engine ?? "")|"
        if let data = signature.data(using: .utf8) {
            state.fingerprintHash.update(data: data)
        }

        activeRuns[runID] = state
    }

    /// The persisted cumulative `event_count` for a run, or nil when it has no `runs` row
    /// yet (a genuinely new run). Called from `updateRunState` after that batch's
    /// transaction has committed and on the actor's serial executor, so it never
    /// interleaves with the writer's own open transaction.
    private func persistedEventCount(runID: String) -> Int? {
        do {
            let stmt: SQLiteStatement
            if let cached = eventCountStmt {
                stmt = cached
            } else {
                stmt = try db.prepare("SELECT event_count FROM runs WHERE run_id = ?")
                eventCountStmt = stmt
            }
            defer { stmt.reset() }
            try stmt.bind(runID, at: 1)
            guard try stmt.step() else { return nil }
            return stmt.columnInt(at: 0)
        } catch {
            // A read failure falls back to the historical seed of 0. The next restart's
            // reconcile still corrects runs.event_count from COUNT(*), so a transient
            // read error cannot permanently corrupt the persisted total.
            return nil
        }
    }

    /// Bounds `activeRuns` so a long-lived writer's metadata cache cannot grow without
    /// limit. Both stages evict only CLEAN entries — a dirty entry holds metadata not yet
    /// written to `runs`, so evicting it would lose that delta until the next restart's
    /// reconcile. Any evicted run re-seeds its count from the persisted row on its next
    /// event, so eviction is always count-preserving.
    ///
    /// `internal` (not `private`) so tests can drive it deterministically with a supplied
    /// `now`; production calls it from `tick` on the 1s runs-flush cadence.
    internal func runMaintenance(now: TimeInterval) {
        guard !activeRuns.isEmpty else { return }

        // Stage 1: idle sweep — drop clean entries untouched past the idle window (very
        // likely completed runs). Collect keys first; mutating a Dictionary while
        // iterating it is unsafe.
        var idleRunIDs: [String] = []
        for (runID, state) in activeRuns
        where !state.isDirty && now - state.lastTouchTime > activeRunIdleEvictionSeconds {
            idleRunIDs.append(runID)
        }
        for runID in idleRunIDs {
            activeRuns.removeValue(forKey: runID)
        }

        // Stage 2: hard-cap backstop — if a burst of concurrent runs still leaves the
        // cache over the cap, drop the least-recently-touched clean entries down to it.
        guard activeRuns.count > maxActiveRuns else { return }
        let evictable = activeRuns
            .filter { !$0.value.isDirty }
            .sorted { $0.value.lastTouchTime < $1.value.lastTouchTime }
        let overBy = activeRuns.count - maxActiveRuns
        for (runID, _) in evictable.prefix(overBy) {
            activeRuns.removeValue(forKey: runID)
        }
        if activeRuns.count > maxActiveRuns {
            // Everything left is dirty (unflushed metadata) and cannot be evicted without
            // loss; it flushes within the next cycle and becomes evictable then.
            DPKLog.store.warning("SQLiteWriter activeRuns exceeds cap \(self.maxActiveRuns, privacy: .public); \(self.activeRuns.count, privacy: .public) retained (excess entries are dirty, will flush next cycle).")
        }
    }

    /// Number of cached run states currently held. Test/diagnostic hook for the
    /// eviction and re-seeding behavior.
    internal var activeRunCount: Int { activeRuns.count }

    /// Test seam: drain the buffer into `trace_events` and fold run metadata WITHOUT the
    /// throttled `runs` flush, leaving the touched entries DIRTY. Production never needs
    /// this — `tick` always pairs a drain with the periodic flush — but tests use it to
    /// exercise the "dirty entries are never evicted" invariant of `runMaintenance`.
    internal func drainWithoutRunsFlushForTesting() async {
        await processBatch(drainAll: true)
    }
    
    /// Stages dirty run metadata inside the caller's transaction and returns the run IDs whose
    /// UPSERTs succeeded. Dirty flags are cleared only after that transaction commits; otherwise
    /// a later statement failure could roll the database back while leaving the cache marked clean.
    @discardableResult
    private func flushRunsTable(force: Bool = false) throws -> [String] {
        let upsertSQL = """
        INSERT INTO runs (run_id, context_id, start_time, end_time, event_count, fingerprint)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(run_id) DO UPDATE SET
        end_time = excluded.end_time,
        event_count = MAX(event_count, excluded.event_count),
        fingerprint = excluded.fingerprint;
        """
        // event_count is monotonic — events are append-only, so a run's count never
        // legitimately decreases. Taking MAX(existing, new) makes that a hard invariant:
        // even if the seed-on-first-touch read in `updateRunState` transiently failed and
        // seeded 0, this UPSERT can only hold or raise the persisted count, never clobber
        // it downward. The normal path is unaffected (the in-memory count always exceeds
        // the last-flushed one), so MAX == excluded there.
        
        let stmt = try db.prepare(upsertSQL)
        var stagedRunIDs: [String] = []
        
        for (runID, state) in activeRuns {
            if state.isDirty || force {
                let digest = state.fingerprintHash.finalize()
                let fingerprintString = digest.map { String(format: "%02x", $0) }.joined()
                
                try stmt.bind(runID, at: 1)
                try stmt.bind(state.contextID, at: 2)
                try stmt.bind(state.startTime, at: 3)
                try stmt.bind(state.latestTime, at: 4)
                try stmt.bind(Int64(state.eventCount), at: 5)
                try stmt.bind(fingerprintString, at: 6)
                
                _ = try stmt.step()
                stmt.reset()

                stagedRunIDs.append(runID)
            }
        }

        return stagedRunIDs
    }

    private func markRunsClean(_ runIDs: [String]) {
        for runID in runIDs {
            activeRuns[runID]?.isDirty = false
        }
    }
}
