import Foundation
import XCTest
@testable import DProvenanceKit

/// Coverage for the `SQLiteWriter` run-metadata cache fixes:
///   1. `activeRuns` is bounded — idle entries are swept and a hard cap backstops a burst
///      of concurrent runs, so a long-lived writer's cache cannot grow without limit.
///   2. Resumed runs continue their cumulative `runs.event_count` instead of restarting
///      at 0: the writer seeds a run's count from its persisted row on first touch, both
///      across a process restart and after a cache eviction.
///
/// The two are tested together because eviction (#1) is only safe *because* of re-seeding
/// (#2) — an evicted run that later resumes must not under-count.
final class SQLiteWriterRunStateTests: XCTestCase {

    private struct Step: TraceableEvent {
        let typeIdentifier: String
        let priority: TracePriority
    }

    private var storeURL: URL!

    override func setUp() {
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sqlite")
    }

    override func tearDown() {
        let base = storeURL.deletingLastPathComponent()
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(
                at: base.appendingPathComponent(storeURL.lastPathComponent + suffix))
        }
    }

    // MARK: - Helpers

    /// The minimal `runs` + `trace_events` schema the writer's INSERT/UPSERT touch, for
    /// bare-writer tests that don't go through `SQLiteTraceStore.init`.
    private func makeSchema(_ db: SQLiteConnection) throws {
        try db.execute("""
        CREATE TABLE IF NOT EXISTS runs (
            run_id TEXT PRIMARY KEY, context_id TEXT, start_time INTEGER,
            end_time INTEGER, event_count INTEGER, fingerprint TEXT
        );
        """)
        try db.execute("""
        CREATE TABLE IF NOT EXISTS trace_events (
            id TEXT PRIMARY KEY, run_id TEXT NOT NULL, context_id TEXT NOT NULL,
            priority INTEGER NOT NULL, sequence INTEGER NOT NULL, engine TEXT,
            span_id TEXT, parent_span_id TEXT, type TEXT NOT NULL, payload BLOB NOT NULL,
            timestamp INTEGER NOT NULL, schema_version INTEGER NOT NULL DEFAULT 1
        );
        """)
    }

    private func row(run: String, seq: Int64, priority: TracePriority = .critical) -> TraceEventRow {
        TraceEventRow(
            id: UUID().uuidString, runID: run, contextID: "ctx",
            priority: priority.rawValue, sequence: seq, engine: "engine",
            spanID: nil, parentSpanID: nil, type: "step",
            payload: Data("{}".utf8), timestamp: 1_700_000_000_000_000 + seq,
            schemaVersion: 1
        )
    }

    private func makeEvent(runID: UUID, sequence: UInt64) -> TraceEvent<Step> {
        TraceEvent(
            runID: runID, contextID: "ctx", engineName: "engine",
            schemaVersion: 1, sequence: sequence, spanID: nil, parentSpanID: nil,
            payload: Step(typeIdentifier: "step", priority: .critical),
            timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(sequence))
        )
    }

    private func readCount(_ db: SQLiteConnection, run: String) throws -> Int? {
        let stmt = try db.prepare("SELECT event_count FROM runs WHERE run_id = ?")
        defer { stmt.reset() }
        try stmt.bind(run, at: 1)
        guard try stmt.step() else { return nil }
        return stmt.columnInt(at: 0)
    }

    /// Reads `runs.event_count` through a fresh read-only connection so it does NOT run
    /// `SQLiteTraceStore`'s reconcile — which would self-heal the count and mask the bug.
    private func persistedCount(_ url: URL, run: String) throws -> Int? {
        let conn = try SQLiteConnection(fileURL: url, mode: .readOnly)
        defer { conn.close() }
        return try readCount(conn, run: run)
    }

    // MARK: - #2: resumed runs continue their cumulative count

    /// The regression this fixes: a run recorded across a process restart must keep
    /// accumulating `runs.event_count`, not reset to the second session's event count.
    func testResumedRunEventCountContinuesAcrossReopen() async throws {
        let runID = UUID()
        let firstSession = 4
        let secondSession = 3

        // Session 1: record N events into run R, then close (persists event_count = N).
        do {
            let store = try SQLiteTraceStore<Step>(fileURL: storeURL)
            for i in 0..<firstSession { store.record(makeEvent(runID: runID, sequence: UInt64(i))) }
            let run = try await store.getRun(id: runID)
            XCTAssertEqual(run?.events.count, firstSession)
            _ = await store.close()
        }

        // Session 2 == the process relaunching: resume the SAME run, record M more.
        do {
            let store = try SQLiteTraceStore<Step>(fileURL: storeURL)
            for i in 0..<secondSession {
                store.record(makeEvent(runID: runID, sequence: UInt64(firstSession + i)))
            }
            _ = await store.close()
        }

        // Read WITHOUT opening a SQLiteTraceStore (whose init reconcile would self-heal).
        let count = try persistedCount(storeURL, run: runID.uuidString)
        XCTAssertEqual(count, firstSession + secondSession,
                       "resumed run must continue the cumulative count, not restart at the second session's count")
    }

    /// Within a single process, with the cache entry never evicted, counts stay exact and
    /// the seed-on-first-touch read must not double-count on later touches.
    func testWithinProcessCountIsExactWithNoDoubleCount() async throws {
        let db = try SQLiteConnection(fileURL: storeURL)
        defer { db.close() }
        try makeSchema(db)
        let buffer = TraceWriteBuffer(maxGlobalBuffer: 100_000)
        let writer = SQLiteWriter(db: db, buffer: buffer)  // production defaults: no eviction here
        let run = "run-fresh"

        for i in 0..<10 { buffer.enqueue(row(run: run, seq: Int64(i))) }
        try await writer.flush()
        // More events while the entry is still cached — takes the `existing` branch, no re-seed.
        for i in 10..<15 { buffer.enqueue(row(run: run, seq: Int64(i))) }
        try await writer.flush()

        XCTAssertEqual(try readCount(db, run: run), 15)
        let cached = await writer.activeRunCount
        XCTAssertEqual(cached, 1)
    }

    // MARK: - #1: activeRuns is bounded

    /// A burst of many concurrent runs is capped to `maxActiveRuns` (the hard backstop),
    /// independent of idle time.
    func testActiveRunsHardCapBoundsCache() async throws {
        let db = try SQLiteConnection(fileURL: storeURL)
        defer { db.close() }
        try makeSchema(db)
        let buffer = TraceWriteBuffer(maxGlobalBuffer: 200_000)
        // Idle window huge so ONLY the cap drives eviction in this test.
        let writer = SQLiteWriter(db: db, buffer: buffer, maxActiveRuns: 10, activeRunIdleEvictionSeconds: 3600)

        for r in 0..<50 { buffer.enqueue(row(run: "run-\(r)", seq: 0)) }
        try await writer.flush()
        let before = await writer.activeRunCount
        XCTAssertEqual(before, 50)

        // `now` ~ present: not idle, so the cap is the only mechanism that fires.
        await writer.runMaintenance(now: Date().timeIntervalSince1970)
        let after = await writer.activeRunCount
        XCTAssertEqual(after, 10, "hard cap must bound the cache to maxActiveRuns")
    }

    /// Clean entries untouched past the idle window are swept, releasing memory for
    /// completed runs well before the hard cap is reached.
    func testIdleRunsAreEvicted() async throws {
        let db = try SQLiteConnection(fileURL: storeURL)
        defer { db.close() }
        try makeSchema(db)
        let buffer = TraceWriteBuffer(maxGlobalBuffer: 200_000)
        let writer = SQLiteWriter(db: db, buffer: buffer, maxActiveRuns: 100_000, activeRunIdleEvictionSeconds: 300)

        for r in 0..<5 { buffer.enqueue(row(run: "run-\(r)", seq: 0)) }
        try await writer.flush()
        let before = await writer.activeRunCount
        XCTAssertEqual(before, 5)

        // A `now` far past every entry's last touch makes them all idle.
        await writer.runMaintenance(now: Date().timeIntervalSince1970 + 10_000)
        let after = await writer.activeRunCount
        XCTAssertEqual(after, 0, "idle clean runs should be evicted")
    }

    // MARK: - #1 × #2: eviction is count-preserving

    /// An evicted run that later receives more events re-seeds its count from the
    /// persisted row — so bounding the cache never under-counts.
    func testEvictedRunResumesWithCorrectCount() async throws {
        let db = try SQLiteConnection(fileURL: storeURL)
        defer { db.close() }
        try makeSchema(db)
        let buffer = TraceWriteBuffer(maxGlobalBuffer: 200_000)
        let writer = SQLiteWriter(db: db, buffer: buffer, maxActiveRuns: 100_000, activeRunIdleEvictionSeconds: 300)
        let run = "run-resume"

        for i in 0..<4 { buffer.enqueue(row(run: run, seq: Int64(i))) }
        try await writer.flush()
        await writer.runMaintenance(now: Date().timeIntervalSince1970 + 10_000)  // evict (idle)
        let evicted = await writer.activeRunCount
        XCTAssertEqual(evicted, 0)

        // Resume the evicted run: first touch must re-seed from persisted 4 → total 7.
        for i in 4..<7 { buffer.enqueue(row(run: run, seq: Int64(i))) }
        try await writer.flush()

        XCTAssertEqual(try readCount(db, run: run), 7,
                       "re-seed after eviction must continue the cumulative count")
    }

    /// `runs.event_count` is monotonic: even if the cached in-memory count is lower than
    /// what is already persisted (the shape a failed re-seed would produce), the UPSERT's
    /// `MAX(...)` must never lower the stored count.
    func testPersistedEventCountNeverDecreases() async throws {
        let db = try SQLiteConnection(fileURL: storeURL)
        defer { db.close() }
        try makeSchema(db)
        let buffer = TraceWriteBuffer(maxGlobalBuffer: 100_000)
        let writer = SQLiteWriter(db: db, buffer: buffer)
        let run = "run-monotonic"

        for i in 0..<2 { buffer.enqueue(row(run: run, seq: Int64(i))) }
        try await writer.flush()
        XCTAssertEqual(try readCount(db, run: run), 2)

        // Simulate a persisted count higher than the writer's cached count (e.g. a prior
        // session's larger total that a failed re-seed didn't pick up).
        try db.execute("UPDATE runs SET event_count = 999 WHERE run_id = '\(run)';")

        // The still-cached entry increments 2 -> 3 and UPSERTs; MAX must keep 999.
        buffer.enqueue(row(run: run, seq: 2))
        try await writer.flush()
        XCTAssertEqual(try readCount(db, run: run), 999,
                       "monotonic event_count must not be clobbered downward by a lower in-memory count")
    }

    /// Dirty entries hold run metadata not yet written to `runs`; maintenance must never
    /// evict them, even under the most aggressive settings (cap 0, idle 0).
    func testDirtyRunsSurviveMaintenance() async throws {
        let db = try SQLiteConnection(fileURL: storeURL)
        defer { db.close() }
        try makeSchema(db)
        let buffer = TraceWriteBuffer(maxGlobalBuffer: 200_000)
        let writer = SQLiteWriter(db: db, buffer: buffer, maxActiveRuns: 0, activeRunIdleEvictionSeconds: 0)

        for r in 0..<3 { buffer.enqueue(row(run: "run-\(r)", seq: 0)) }
        await writer.drainWithoutRunsFlushForTesting()  // entries are now DIRTY (unflushed)
        let dirtyCount = await writer.activeRunCount
        XCTAssertEqual(dirtyCount, 3)

        // Even with cap 0 and idle 0, dirty entries must survive.
        await writer.runMaintenance(now: Date().timeIntervalSince1970 + 10_000)
        let afterMaintenance = await writer.activeRunCount
        XCTAssertEqual(afterMaintenance, 3,
                       "dirty entries hold unflushed metadata and must not be evicted")

        // Once flushed they become clean and are then evictable.
        try await writer.flush()
        await writer.runMaintenance(now: Date().timeIntervalSince1970 + 10_000)
        let afterFlushMaintenance = await writer.activeRunCount
        XCTAssertEqual(afterFlushMaintenance, 0)
    }
}
