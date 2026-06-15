import Foundation
import CryptoKit

/// Background writer that periodically drains the buffer and executes batched INSERTs.
public actor SQLiteWriter {
    private let db: SQLiteConnection
    private let buffer: TraceWriteBuffer
    private var writeTask: Task<Void, Never>?
    private var isShuttingDown = false
    
    // Incremental run state cache to throttle UPSERTs to the `runs` table
    private struct RunState {
        var contextID: String
        var startTime: Int64
        var latestTime: Int64
        var eventCount: Int
        var fingerprintHash: Insecure.SHA1 // Using SHA1 for fast incremental hashing (non-cryptographic use-case)
        var uncommittedEvents: Int
    }
    
    private var activeRuns: [String: RunState] = [:]
    
    public init(db: SQLiteConnection, buffer: TraceWriteBuffer) {
        self.db = db
        self.buffer = buffer
    }
    
    public func start() {
        guard writeTask == nil else { return }
        writeTask = Task.detached { [weak self] in
            while true {
                guard let self = self else { break }
                let isShuttingDown = await self.isShuttingDown
                if isShuttingDown { break }
                
                await self.processBatch()
                try? await Task.sleep(nanoseconds: 50_000_000) // 50ms batching
            }
        }
    }
    
    public func flush() async throws {
        await processBatch(drainAll: true)
    }
    
    public func shutdown() async {
        isShuttingDown = true
        await writeTask?.value
        await processBatch(drainAll: true)
    }
    
    private func processBatch(drainAll: Bool = false) async {
        let batch = drainAll ? await buffer.flushAll() : await buffer.drain(max: 1000)
        guard !batch.isEmpty else { return }
        
        do {
            try db.transaction {
                try insert(batch)
                try flushRunsTable(force: drainAll)
            }
        } catch {
            print("🚨 [DProvenanceKit] SQLiteWriter failed to insert batch: \(error)")
        }
    }
    
    private func insert(_ events: [TraceEventRow]) throws {
        let insertSQL = """
        INSERT INTO trace_events (id, run_id, engine, type, payload, timestamp)
        VALUES (?, ?, ?, ?, ?, ?);
        """
        let stmt = try db.prepare(insertSQL)
        
        for event in events {
            try stmt.bind(event.id, at: 1)
            try stmt.bind(event.runID, at: 2)
            if let engine = event.engine {
                try stmt.bind(engine, at: 3)
            } else {
                try stmt.bindNull(at: 3)
            }
            try stmt.bind(event.type, at: 4)
            try stmt.bind(event.payload, at: 5)
            try stmt.bind(event.timestamp, at: 6)
            
            _ = try stmt.step()
            stmt.reset()
            
            updateRunState(for: event)
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
            uncommittedEvents: 0
        )
        
        state.latestTime = event.timestamp
        state.eventCount += 1
        state.uncommittedEvents += 1
        
        // Incremental fingerprinting: hash(type + engine)
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
            // Throttling: only update if we have a significant number of new events,
            // or if we are forced to flush (e.g., shutdown or explicit flush)
            if state.uncommittedEvents >= 50 || (force && state.uncommittedEvents > 0) {
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
                
                // Reset uncommitted tracker
                activeRuns[runID]?.uncommittedEvents = 0
            }
        }
        
        // Cleanup old runs from memory cache?
        // In a real system, we'd evict runs that haven't been updated in e.g., 5 minutes.
        // For now, they live in memory during the execution lifetime.
    }
}
