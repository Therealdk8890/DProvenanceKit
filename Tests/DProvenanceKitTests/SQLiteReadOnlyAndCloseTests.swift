import XCTest
@testable import DProvenanceKit
import Foundation

/// Covers the two store-lifecycle hardenings:
///
/// 1. `SQLiteOpenMode.readOnly` — `RawTraceStore` (the inspector read path) used to open
///    with `CREATE | READWRITE` plus WAL pragmas, so a mistyped path silently created an
///    empty database, and pointing an inspector at another app's live store could modify
///    a file it doesn't own. Read-only opens must fail on a missing file, create nothing,
///    and reject every write.
///
/// 2. `SQLiteTraceStore.close()` — the writer's `shutdown()` was previously unreachable
///    from the public API, so there was no way to quiesce a store file before archiving
///    or rotating it. `close()` must persist everything pending, fold the WAL into the
///    main file so a bare `.sqlite` copy is complete, stay idempotent, keep reads alive,
///    and count (never silently drop) writes that arrive after it.
final class SQLiteReadOnlyAndCloseTests: XCTestCase {
    private var storeURL: URL!

    override func setUp() async throws {
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sqlite")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: storeURL)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + "-wal"))
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + "-shm"))
    }

    private func event(_ payload: TestEvent, sequence: UInt64 = 0, runID: UUID = UUID()) -> TraceEvent<TestEvent> {
        TraceEvent(
            runID: runID,
            contextID: "ctx",
            engineName: "engine",
            schemaVersion: 1,
            sequence: sequence,
            spanID: nil,
            parentSpanID: nil,
            payload: payload,
            timestamp: Date()
        )
    }

    // MARK: - Read-only opens

    func testReadOnlyOpenOfMissingFileThrowsAndCreatesNothing() {
        XCTAssertThrowsError(try SQLiteConnection(fileURL: storeURL, mode: .readOnly)) { error in
            guard case SQLiteError.openFailed = error else {
                return XCTFail("expected openFailed, got \(error)")
            }
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: storeURL.path),
            "a failed read-only open must not create the database file"
        )
    }

    func testRawTraceStoreMissingPathThrowsWithoutCreatingFile() {
        // The original bug: this used to succeed, minting an empty store at the typo'd
        // path, and fetchAllRuns() then reported "no runs" instead of "no such store".
        XCTAssertThrowsError(try RawTraceStore(fileURL: storeURL))
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeURL.path))
    }

    func testReadOnlyConnectionRejectsWrites() throws {
        // Create a real store file first, through the normal write path.
        let writable = try SQLiteConnection(fileURL: storeURL)
        try writable.execute("CREATE TABLE t (x INTEGER);")

        let readOnly = try SQLiteConnection(fileURL: storeURL, mode: .readOnly)
        XCTAssertThrowsError(try readOnly.execute("INSERT INTO t VALUES (1);")) { error in
            guard case SQLiteError.executeFailed = error else {
                return XCTFail("expected executeFailed, got \(error)")
            }
        }
    }

    func testBareWALFileFallsBackToImmutableOpen() async throws {
        // Build a bare WAL-mode store file: written and cleanly closed, then stripped of
        // its -wal/-shm companions — the state of any store transferred as a single file
        // (exported, downloaded, or copied without close()'s journal-mode flip). A plain
        // read-only connection cannot read that (SQLITE_CANTOPEN: no -wal to build the
        // wal-index from), so RawTraceStore must fall back to the immutable open.
        do {
            let conn = try SQLiteConnection(fileURL: storeURL)
            try conn.execute("""
            CREATE TABLE runs (
                run_id TEXT PRIMARY KEY, context_id TEXT, start_time INTEGER,
                end_time INTEGER, event_count INTEGER, fingerprint TEXT
            );
            """)
            try conn.execute("""
            CREATE TABLE trace_events (
                id TEXT PRIMARY KEY, run_id TEXT NOT NULL, context_id TEXT NOT NULL,
                priority INTEGER NOT NULL, sequence INTEGER NOT NULL, engine TEXT,
                span_id TEXT, parent_span_id TEXT, type TEXT NOT NULL,
                payload BLOB NOT NULL, timestamp INTEGER NOT NULL
            );
            """)
            let runID = "5D2C9EDA-95A5-4B08-8C1B-3F2ABB4C0001"
            try conn.execute("""
            INSERT INTO runs VALUES ('\(runID)', 'cold', 1000, 2000, 1, 'fp');
            """)
            try conn.execute("""
            INSERT INTO trace_events VALUES
            ('9A1B2C3D-95A5-4B08-8C1B-3F2ABB4C0002', '\(runID)', 'cold', 3, 0,
             'engine', NULL, NULL, 'processStarted', X'7B7D', 1500);
            """)
        } // conn deallocates here. Apple's SQLite persists an (empty) -wal on clean
        // close, so strip the companions to produce the single-file state under test.
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + "-wal"))
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + "-shm"))

        let reader = try RawTraceStore(fileURL: storeURL)
        let runs = try await reader.fetchAllRuns()
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.contextID, "cold")
        XCTAssertEqual(runs.first?.events.count, 1)
    }

    // MARK: - close()

    func testClosePersistsPendingEventsAndIsIdempotent() async throws {
        let store = try SQLiteTraceStore<TestEvent>(fileURL: storeURL)
        await DProvenanceKit<TestEvent>.run(contextID: "closing", store: store) {
            DProvenanceKit<TestEvent>.record(.processStarted)
            DProvenanceKit<TestEvent>.record(.stepCompleted(1))
            DProvenanceKit<TestEvent>.record(.processFinished)
        }

        // No explicit flush(): close() itself must drain everything pending.
        let first = await store.close()
        let second = await store.close() // idempotent, same answer
        XCTAssertTrue(first)
        XCTAssertEqual(first, second)

        let reader = try RawTraceStore(fileURL: storeURL)
        let runs = try await reader.fetchAllRuns()
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.events.count, 3)
    }

    func testBareFileCopyAfterCloseIsComplete() async throws {
        // The retention pattern copies/renames ONLY the .sqlite file, so close() must
        // have checkpointed the WAL: any frames left in -wal would vanish in the copy.
        let store = try SQLiteTraceStore<TestEvent>(fileURL: storeURL)
        await DProvenanceKit<TestEvent>.run(contextID: "rotating", store: store) {
            DProvenanceKit<TestEvent>.record(.processStarted)
            DProvenanceKit<TestEvent>.record(.processFinished)
        }
        let complete = await store.close()
        XCTAssertTrue(complete, "no concurrent reader exists, so close() must fold the WAL fully")

        let copyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: copyURL) }
        try FileManager.default.copyItem(at: storeURL, to: copyURL)

        // The archived copy must be readable by a PLAIN read-only client — close()
        // leaves the file in rollback-journal mode precisely so that generic tools
        // (sqlite3 -readonly, other languages) need no immutable-open workaround.
        // Asserting through SQLiteConnection directly, NOT RawTraceStore, whose
        // immutable fallback would mask a failed journal-mode flip.
        let plainReadOnly = try SQLiteConnection(fileURL: copyURL, mode: .readOnly)
        let modeStmt = try plainReadOnly.prepare("PRAGMA journal_mode;")
        XCTAssertTrue(try modeStmt.step())
        XCTAssertEqual(modeStmt.columnString(at: 0)?.lowercased(), "delete")

        let reader = try RawTraceStore(fileURL: copyURL)
        let runs = try await reader.fetchAllRuns()
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.events.count, 2)
    }

    func testCloseReportsIncompleteFoldWhenReaderPinsTheWAL() async throws {
        let store = try SQLiteTraceStore<TestEvent>(fileURL: storeURL)
        let runID = UUID()
        store.record(event(.processStarted, runID: runID))
        try await store.flush()

        // Pin a WAL snapshot from a second connection: BEGIN plus a stepped SELECT
        // holds a read transaction, which blocks both the TRUNCATE checkpoint and the
        // journal-mode flip.
        let pinning = try SQLiteConnection(fileURL: storeURL, mode: .readOnly)
        try pinning.execute("BEGIN;")
        let pin = try pinning.prepare("SELECT count(*) FROM trace_events;")
        _ = try pin.step()

        // New frames after the pin guarantee the checkpoint cannot complete.
        store.record(event(.processFinished, sequence: 1, runID: runID))

        let complete = await store.close()
        XCTAssertFalse(
            complete,
            "close() must report that the .sqlite file alone is not a complete archive while a reader pins the WAL"
        )

        // The data itself is safe (persisted in the WAL) — only the single-file
        // guarantee failed. A read through the store still sees both events.
        pin.reset()
        try pinning.execute("COMMIT;")
        let fetched = try await store.getRun(id: runID)
        XCTAssertEqual(fetched?.events.count, 2)
    }

    func testConcurrentRecordAndCloseNeverLosesAnEventUncounted() async throws {
        // The buffer's closed-gate shares a lock with enqueue, so a record racing
        // close() must end up either persisted or counted in dropStats — an event that
        // is neither (admitted after the final drain, stranded forever) is the bug.
        let store = try SQLiteTraceStore<TestEvent>(fileURL: storeURL)
        let runID = UUID()
        let total = 400
        let events = (0..<total).map { event(.processStarted, sequence: UInt64($0), runID: runID) }

        await withTaskGroup(of: Void.self) { group in
            for (i, event) in events.enumerated() {
                group.addTask { store.record(event) }
                if i == total / 2 {
                    group.addTask { _ = await store.close() }
                }
            }
        }
        _ = await store.close()

        // Count persisted rows directly in SQL — independent of run metadata.
        let conn = try SQLiteConnection(fileURL: storeURL, mode: .readOnly)
        let stmt = try conn.prepare("SELECT count(*) FROM trace_events;")
        XCTAssertTrue(try stmt.step())
        let persisted = UInt64(stmt.columnInt64(at: 0))

        XCTAssertEqual(
            persisted + store.dropStats.total,
            UInt64(total),
            "every recorded event must be persisted or counted as dropped — never silently stranded"
        )
    }

    func testReadsAfterCloseDoNotModifyTheFile() async throws {
        let store = try SQLiteTraceStore<TestEvent>(fileURL: storeURL)
        let runID = UUID()
        store.record(event(.processStarted, runID: runID))
        await store.close()

        let before = try Data(contentsOf: storeURL)
        _ = try await store.getRun(id: runID)
        _ = try await store.lineageEdges(of: runID)
        let after = try Data(contentsOf: storeURL)

        XCTAssertEqual(before, after, "post-close reads must never write to the archived file")
    }

    func testLinkAfterCloseIsCountedAsStructuralLoss() async throws {
        let store = try SQLiteTraceStore<TestEvent>(fileURL: storeURL)
        await store.close()
        XCTAssertTrue(store.dropStats.preservedIntegrity)

        store.link(source: UUID(), target: UUID(), type: .derivedFrom)

        XCTAssertEqual(store.dropStats.structural, 1)
        XCTAssertFalse(
            store.dropStats.preservedIntegrity,
            "a discarded lineage edge changes what traversal would return, so it must flip preservedIntegrity"
        )
    }

    func testReadsRemainAvailableAfterClose() async throws {
        let store = try SQLiteTraceStore<TestEvent>(fileURL: storeURL)
        var runID: UUID?
        await DProvenanceKit<TestEvent>.run(contextID: "post-close-reads", store: store) {
            runID = TraceContext.currentRun?.runID
            DProvenanceKit<TestEvent>.record(.processStarted)
        }
        await store.close()

        let fetched = try await store.getRun(id: XCTUnwrap(runID))
        XCTAssertEqual(fetched?.events.count, 1)
    }

    func testRecordAfterCloseIsCountedNotSilent() async throws {
        let store = try SQLiteTraceStore<TestEvent>(fileURL: storeURL)
        await store.close()
        XCTAssertTrue(store.dropStats.preservedIntegrity)

        store.record(event(.processStarted)) // critical tier
        store.record(event(.stepCompleted(1), sequence: 1)) // telemetry tier

        let stats = store.dropStats
        XCTAssertEqual(stats.critical, 1)
        XCTAssertEqual(stats.telemetry, 1)
        XCTAssertFalse(
            stats.preservedIntegrity,
            "losing a critical event after close() must flip preservedIntegrity"
        )
    }
}
