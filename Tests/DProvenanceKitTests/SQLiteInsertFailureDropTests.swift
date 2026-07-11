import XCTest
@testable import DProvenanceKit
import Foundation

/// Regression coverage for the silent-data-loss + corrupted-metadata bug in
/// `SQLiteWriter.processBatch`. A failed batch INSERT used to roll back the rows — which
/// had already been drained out of the buffer, so they were gone — while the in-memory
/// run metadata had *already* been mutated per-event inside the transaction (inflating
/// `event_count` and the fingerprint with rolled-back events) and the loss contributed
/// nothing to `dropStats`, so `preservedIntegrity` still reported `true` after losing
/// `structural`/`critical` events.
///
/// The fix: fold run metadata in only *after* a successful commit, and tally a failed
/// batch into the shared `TraceDropTally` so the loss is honest.
final class SQLiteInsertFailureDropTests: XCTestCase {
    private var dbURL: URL!

    override func setUp() async throws {
        dbURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dbURL)
    }

    private func row(_ tier: TracePriority, seq: Int64, run: String = "run-1") -> TraceEventRow {
        TraceEventRow(
            id: UUID().uuidString,
            runID: run,
            contextID: "ctx",
            priority: tier.rawValue,
            sequence: seq,
            engine: "engine",
            spanID: nil,
            parentSpanID: nil,
            type: "event",
            payload: Data("{}".utf8),
            timestamp: 1_000 + seq
        )
    }

    private func createRunsTable(_ db: SQLiteConnection) throws {
        try db.execute("""
        CREATE TABLE runs (
            run_id TEXT PRIMARY KEY, context_id TEXT, start_time INTEGER,
            end_time INTEGER, event_count INTEGER, fingerprint TEXT
        );
        """)
    }

    private func createTraceEventsTable(_ db: SQLiteConnection) throws {
        try db.execute("""
        CREATE TABLE trace_events (
            id TEXT PRIMARY KEY, run_id TEXT NOT NULL, context_id TEXT NOT NULL,
            priority INTEGER NOT NULL, sequence INTEGER NOT NULL, engine TEXT,
            span_id TEXT, parent_span_id TEXT, type TEXT NOT NULL,
            payload BLOB NOT NULL, timestamp INTEGER NOT NULL,
            schema_version INTEGER NOT NULL DEFAULT 1
        );
        """)
    }

    private func count(_ db: SQLiteConnection, _ sql: String) throws -> Int64 {
        let stmt = try db.prepare(sql)
        return try stmt.step() ? stmt.columnInt64(at: 0) : 0
    }

    /// With no `trace_events` table, every batch INSERT fails. The drained rows are gone,
    /// but the loss must be counted per tier so `preservedIntegrity` tells the truth — and
    /// no phantom run metadata may be written for the rolled-back batch.
    func testFailedBatchInsertIsTalliedAndBreaksIntegrity() async throws {
        let db = try SQLiteConnection(fileURL: dbURL)
        // Create only `runs` (so flushRunsTable succeeds); omit `trace_events` so the
        // batch INSERT is guaranteed to fail.
        try createRunsTable(db)

        let buffer = TraceWriteBuffer(maxGlobalBuffer: 1_000)
        let tally = TraceDropTally()
        let writer = SQLiteWriter(db: db, buffer: buffer, dropTally: tally)

        buffer.enqueue(row(.structural, seq: 0))
        buffer.enqueue(row(.telemetry, seq: 1))

        // flush() drains the buffer and attempts the (doomed) batch insert.
        try await writer.flush()

        let stats = tally.snapshot
        XCTAssertEqual(stats.structural, 1, "the lost structural event must be counted")
        XCTAssertEqual(stats.telemetry, 1, "the lost telemetry event must be counted")
        XCTAssertEqual(stats.total, 2)
        XCTAssertFalse(
            stats.preservedIntegrity,
            "losing a structural event to a failed batch insert must break integrity"
        )

        // The corrupted-metadata half: a rolled-back batch must leave no run metadata.
        let runRows = try count(db, "SELECT COUNT(*) FROM runs;")
        XCTAssertEqual(runRows, 0, "a failed batch must not write phantom run metadata")
    }

    /// An edge-only batch that fails to persist must ALSO break integrity: lineage is
    /// structural data (it changes what traversal and an attestation's edge set would
    /// contain), so losing it while `preservedIntegrity` stays `true` is a lie.
    func testFailedEdgeOnlyBatchIsCountedAsStructuralLoss() async throws {
        let db = try SQLiteConnection(fileURL: dbURL)
        try createRunsTable(db)
        try createTraceEventsTable(db)
        // No trace_edges table: the edge INSERT is guaranteed to fail.

        let buffer = TraceWriteBuffer(maxGlobalBuffer: 1_000)
        let tally = TraceDropTally()
        let writer = SQLiteWriter(db: db, buffer: buffer, dropTally: tally)

        buffer.enqueueEdge(TraceEdge(sourceID: UUID(), targetID: UUID(), type: .derivedFrom))
        buffer.enqueueEdge(TraceEdge(sourceID: UUID(), targetID: UUID(), type: .informed))

        try await writer.flush()

        let stats = tally.snapshot
        XCTAssertEqual(stats.structural, 2, "each lost edge must be counted as a structural loss")
        XCTAssertFalse(stats.preservedIntegrity,
                       "losing lineage edges must break integrity even when no event was lost")
    }

    /// A failed MIXED batch (events + edges in one transaction) must count both: the
    /// events per their tiers AND the edges as structural losses. Losing only-the-edge
    /// accounting here would leave preservedIntegrity true after lineage was lost.
    func testFailedMixedBatchCountsEventsAndEdges() async throws {
        let db = try SQLiteConnection(fileURL: dbURL)
        try createRunsTable(db)
        // No trace_events and no trace_edges tables: the whole transaction fails.

        let buffer = TraceWriteBuffer(maxGlobalBuffer: 1_000)
        let tally = TraceDropTally()
        let writer = SQLiteWriter(db: db, buffer: buffer, dropTally: tally)

        buffer.enqueue(row(.critical, seq: 0))
        buffer.enqueue(row(.telemetry, seq: 1))
        buffer.enqueueEdge(TraceEdge(sourceID: UUID(), targetID: UUID(), type: .derivedFrom))

        try await writer.flush()

        let stats = tally.snapshot
        XCTAssertEqual(stats.critical, 1, "the lost critical event must be counted")
        XCTAssertEqual(stats.telemetry, 1, "the lost telemetry event must be counted")
        XCTAssertEqual(stats.structural, 1, "the lost edge must be counted as structural")
        XCTAssertFalse(stats.preservedIntegrity)
    }

    /// Consumers may pair SQLiteWriter with a connection to a pre-existing store file
    /// directly, bypassing SQLiteTraceStore's migration. The writer must migrate the
    /// schema_version column itself, or every batch against a legacy file fails.
    func testDirectWriterUseMigratesLegacySchema() async throws {
        let db = try SQLiteConnection(fileURL: dbURL)
        try createRunsTable(db)
        // Legacy shape: no schema_version column.
        try db.execute("""
        CREATE TABLE trace_events (
            id TEXT PRIMARY KEY, run_id TEXT NOT NULL, context_id TEXT NOT NULL,
            priority INTEGER NOT NULL, sequence INTEGER NOT NULL, engine TEXT,
            span_id TEXT, parent_span_id TEXT, type TEXT NOT NULL,
            payload BLOB NOT NULL, timestamp INTEGER NOT NULL
        );
        """)

        let buffer = TraceWriteBuffer(maxGlobalBuffer: 1_000)
        let tally = TraceDropTally()
        let writer = SQLiteWriter(db: db, buffer: buffer, dropTally: tally)

        buffer.enqueue(row(.structural, seq: 0))
        try await writer.flush()

        XCTAssertEqual(tally.snapshot.total, 0, "the batch must persist, not be tallied as dropped")
        XCTAssertEqual(try count(db, "SELECT COUNT(*) FROM trace_events;"), 1)
        XCTAssertEqual(try count(db, "SELECT schema_version FROM trace_events;"), 1,
                       "the writer must have migrated the column (rows default to version 1)")
    }

    /// Control: the happy path tallies nothing, keeps integrity intact, persists every
    /// row, and records run metadata whose `event_count` matches the rows actually on disk.
    func testSuccessfulInsertTalliesNothingAndRecordsAccurateMetadata() async throws {
        let db = try SQLiteConnection(fileURL: dbURL)
        try createRunsTable(db)
        try createTraceEventsTable(db)

        let buffer = TraceWriteBuffer(maxGlobalBuffer: 1_000)
        let tally = TraceDropTally()
        let writer = SQLiteWriter(db: db, buffer: buffer, dropTally: tally)

        buffer.enqueue(row(.structural, seq: 0))
        buffer.enqueue(row(.critical, seq: 1))
        buffer.enqueue(row(.telemetry, seq: 2))

        try await writer.flush()

        XCTAssertEqual(tally.snapshot.total, 0, "a successful batch must not tally drops")
        XCTAssertTrue(tally.snapshot.preservedIntegrity)

        let eventRows = try count(db, "SELECT COUNT(*) FROM trace_events;")
        XCTAssertEqual(eventRows, 3, "every enqueued event must be persisted")

        let recordedCount = try count(db, "SELECT event_count FROM runs WHERE run_id = 'run-1';")
        XCTAssertEqual(recordedCount, 3, "run metadata must match the rows actually committed")
    }
}
