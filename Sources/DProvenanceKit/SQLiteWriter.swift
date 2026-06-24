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
    }
    
    private var activeRuns: [String: RunState] = [:]
    
    public init(db: SQLiteConnection, buffer: TraceWriteBuffer, dropTally: TraceDropTally = TraceDropTally()) {
        self.db = db
        self.buffer = buffer
        self.dropTally = dropTally
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
        try db.transaction {
            try flushRunsTable(force: true)
        }
    }
    
    public func shutdown() async {
        isShuttingDown = true
        await writeTask?.value
        await processBatch(drainAll: true)
        try? db.transaction {
            try flushRunsTable(force: true)
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
                try db.transaction {
                    try flushRunsTable()
                }
                lastRunFlushTime = now
            } catch {
                print("🚨 [DProvenanceKit] SQLiteWriter failed to flush runs: \(error)")
            }
        }
        
        if sleepMs > 0 {
            try? await Task.sleep(nanoseconds: sleepMs * 1_000_000)
        }
    }
    
    private func processBatch(drainAll: Bool = false, maxBatch: Int = 1000) async {
        let batch = drainAll ? buffer.flushAll() : buffer.drain(max: maxBatch)
        guard !batch.isEmpty else { return }

        do {
            try db.transaction {
                try insert(batch)
            }
            // The rows are durably committed, so it is now safe to fold them into the
            // in-memory run metadata. Doing this *after* commit — not per-event inside
            // the transaction — keeps event_count and the fingerprint consistent with
            // what is actually on disk; a rolled-back batch never inflates them.
            for event in batch {
                updateRunState(for: event)
            }
        } catch {
            // The transaction rolled back: these rows were already drained out of the
            // buffer and are now gone. Count the loss per tier so it surfaces in
            // dropStats/preservedIntegrity instead of being a silent drop that still
            // reports the run as fully retained.
            for event in batch {
                dropTally.record(priority: event.priority)
            }
            print("🚨 [DProvenanceKit] SQLiteWriter failed to insert batch: \(error)")
        }
    }
    
    private func insert(_ events: [TraceEventRow]) throws {
        let insertSQL = """
        INSERT INTO trace_events (id, run_id, context_id, priority, sequence, engine, span_id, parent_span_id, type, payload, timestamp)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
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
            
            _ = try stmt.step()
            stmt.reset()
        }
    }
    
    private func updateRunState(for event: TraceEventRow) {
        let runID = event.runID
        var state = activeRuns[runID] ?? RunState(
            contextID: event.contextID,
            startTime: event.timestamp,
            latestTime: event.timestamp,
            eventCount: 0,
            fingerprintHash: Insecure.SHA1(),
            isDirty: false
        )
        
        state.latestTime = event.timestamp
        state.eventCount += 1
        state.isDirty = true
        
        // Incremental fingerprinting
        let signature = "\(event.type):\(event.engine ?? "")|"
        if let data = signature.data(using: .utf8) {
            state.fingerprintHash.update(data: data)
        }
        
        activeRuns[runID] = state
    }
    
    private func flushRunsTable(force: Bool = false) throws {
        let upsertSQL = """
        INSERT INTO runs (run_id, context_id, start_time, end_time, event_count, fingerprint)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(run_id) DO UPDATE SET
        end_time = excluded.end_time,
        event_count = excluded.event_count,
        fingerprint = excluded.fingerprint;
        """
        
        let stmt = try db.prepare(upsertSQL)
        
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
                
                activeRuns[runID]?.isDirty = false
            }
        }
    }
}
