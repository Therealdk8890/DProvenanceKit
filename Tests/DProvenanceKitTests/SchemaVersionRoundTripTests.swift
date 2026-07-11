import XCTest
@testable import DProvenanceKit
import Foundation

/// The storage round-trip must not rewrite evidence. Two bugs lived here:
///
/// 1. `SQLiteTraceStore` never persisted `TraceEvent.schemaVersion` and both typed
///    read paths reconstructed every event as version 1 — so a version-2 event could
///    be reloaded and SIGNED into an attestation carrying false schema metadata.
/// 2. `RawTraceEvent.id` was minted fresh (`UUID()`) on every read instead of
///    restoring `trace_events.id`, so inspector reloads broke stable lineage joins
///    and two reads of the same row never compared equal.
final class SchemaVersionRoundTripTests: XCTestCase {
    private var storeURL: URL!

    override func setUp() async throws {
        storeURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
    }

    override func tearDown() async throws {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: storeURL.path + suffix)
        }
    }

    private func event(
        id: UUID = UUID(),
        runID: UUID,
        schemaVersion: Int,
        sequence: UInt64,
        payload: TestEvent = .processStarted
    ) -> TraceEvent<TestEvent> {
        TraceEvent(
            id: id, runID: runID, contextID: "ctx", engineName: "engine",
            schemaVersion: schemaVersion, sequence: sequence,
            spanID: nil, parentSpanID: nil, payload: payload,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(sequence))
        )
    }

    func testSchemaVersionSurvivesTypedRoundTrip() async throws {
        let store = try SQLiteTraceStore<TestEvent>(fileURL: storeURL)
        let runID = UUID()
        let v1ID = UUID()
        let v2ID = UUID()

        store.record(event(id: v1ID, runID: runID, schemaVersion: 1, sequence: 0))
        store.record(event(id: v2ID, runID: runID, schemaVersion: 2, sequence: 1, payload: .stepCompleted(3)))
        try await store.flush()

        // getRun path
        let maybeRun = try await store.getRun(id: runID)
        let run = try XCTUnwrap(maybeRun)
        XCTAssertEqual(run.events.map(\.schemaVersion), [1, 2],
                       "reloading must reproduce each event's recorded schemaVersion, not flatten to 1")
        XCTAssertEqual(run.events.map(\.id), [v1ID, v2ID])

        // getEvents path
        let byID = try await store.getEvents(ids: [v1ID, v2ID])
        XCTAssertEqual(byID[v1ID]?.schemaVersion, 1)
        XCTAssertEqual(byID[v2ID]?.schemaVersion, 2)
    }

    func testReloadedRunSignsWithTrueSchemaMetadata() async throws {
        // End-to-end version of the trust bug: reload a v2 event and attest it. The
        // attestation's canonical bytes cover schemaVersion, so a flattened reload
        // would sign FALSE metadata — and verification against the honest trace
        // would then fail with digestMismatch.
        let store = try SQLiteTraceStore<TestEvent>(fileURL: storeURL)
        let runID = UUID()
        let recorded = event(id: UUID(), runID: runID, schemaVersion: 2, sequence: 0)
        store.record(recorded)
        try await store.flush()

        let maybeReloaded = try await store.getRun(id: runID)
        let reloaded = try XCTUnwrap(maybeReloaded)
        let document = try TraceAttestationDocument.signed(run: reloaded, using: SoftwareTraceAttestationKey())
        XCTAssertEqual(document.trace.events.first?.schemaVersion, 2,
                       "the signed artifact must carry the schema version the event was recorded with")
        XCTAssertTrue(document.verify().isValid)
    }

    func testRawTraceStorePreservesIdentityAndSchemaVersion() async throws {
        let store = try SQLiteTraceStore<TestEvent>(fileURL: storeURL)
        let runID = UUID()
        let ids = [UUID(), UUID(), UUID()]
        for (i, id) in ids.enumerated() {
            store.record(event(id: id, runID: runID, schemaVersion: 2, sequence: UInt64(i)))
        }
        try await store.flush()

        let firstLoad = try await RawTraceStore(fileURL: storeURL).fetchAllRuns()
        let secondLoad = try await RawTraceStore(fileURL: storeURL).fetchAllRuns()

        let firstEvents = try XCTUnwrap(firstLoad.first?.events)
        XCTAssertEqual(firstEvents.map(\.id), ids,
                       "the inspector must see the ids the events were recorded with")
        XCTAssertEqual(firstEvents.map(\.schemaVersion), [2, 2, 2])

        // Identity is stable across reloads: this is what lets the inspector keep
        // selection/join state, and what makes lineage edges (keyed on event id)
        // resolvable against the rows.
        XCTAssertEqual(firstLoad, secondLoad,
                       "two reads of the same store must be equal — identity is persisted, not minted per read")
    }

    func testUnconventionalSchemaVersionsRoundTripUnchanged() async throws {
        // Fidelity, not normalization: a recorded version of 0 must come back as 0.
        // Coercing it to 1 on read would change the attestation's canonical bytes —
        // signing in memory and verifying against the reloaded run would diverge.
        let store = try SQLiteTraceStore<TestEvent>(fileURL: storeURL)
        let runID = UUID()
        store.record(event(id: UUID(), runID: runID, schemaVersion: 0, sequence: 0))
        try await store.flush()

        let maybeRun = try await store.getRun(id: runID)
        let run = try XCTUnwrap(maybeRun)
        XCTAssertEqual(run.events.first?.schemaVersion, 0)

        let raw = try await RawTraceStore(fileURL: storeURL).fetchAllRuns()
        XCTAssertEqual(raw.first?.events.first?.schemaVersion, 0)
    }

    func testUnparseableEventIDStillSurfacesInRawStore() async throws {
        // A corrupted id must not make the row disappear from the inspector; it
        // surfaces under a fresh UUID instead.
        let store = try SQLiteTraceStore<TestEvent>(fileURL: storeURL)
        let runID = UUID()
        store.record(event(id: UUID(), runID: runID, schemaVersion: 1, sequence: 0))
        store.record(event(id: UUID(), runID: runID, schemaVersion: 1, sequence: 1))
        try await store.flush()
        _ = await store.close()

        let db = try SQLiteConnection(fileURL: storeURL)
        try db.execute("UPDATE trace_events SET id = 'not-a-uuid' WHERE sequence = 0;")
        db.close()

        let raw = try await RawTraceStore(fileURL: storeURL).fetchAllRuns()
        let events = try XCTUnwrap(raw.first?.events)
        XCTAssertEqual(events.count, 2, "a row with a corrupt id must still surface")
    }

    func testLegacyDatabaseWithoutSchemaVersionColumnReadsAsVersionOne() async throws {
        // Hand-build a pre-migration database: no schema_version column anywhere.
        let runID = UUID()
        let eventID = UUID()
        let payload = try JSONEncoder().encode(TestEvent.processStarted)
        do {
            let db = try SQLiteConnection(fileURL: storeURL)
            try db.execute("""
            CREATE TABLE runs (
                run_id TEXT PRIMARY KEY, context_id TEXT, start_time INTEGER,
                end_time INTEGER, event_count INTEGER, fingerprint TEXT
            );
            """)
            try db.execute("""
            CREATE TABLE trace_events (
                id TEXT PRIMARY KEY, run_id TEXT NOT NULL, context_id TEXT NOT NULL,
                priority INTEGER NOT NULL, sequence INTEGER NOT NULL, engine TEXT,
                span_id TEXT, parent_span_id TEXT, type TEXT NOT NULL,
                payload BLOB NOT NULL, timestamp INTEGER NOT NULL
            );
            """)
            try db.execute("INSERT INTO runs VALUES ('\(runID.uuidString)', 'ctx', 1, 1, 1, '');")
            let stmt = try db.prepare("""
            INSERT INTO trace_events (id, run_id, context_id, priority, sequence, engine, span_id, parent_span_id, type, payload, timestamp)
            VALUES (?, ?, ?, 2, 0, 'engine', NULL, NULL, 'processStarted', ?, 1000);
            """)
            try stmt.bind(eventID.uuidString, at: 1)
            try stmt.bind(runID.uuidString, at: 2)
            try stmt.bind("ctx", at: 3)
            try stmt.bind(payload, at: 4)
            _ = try stmt.step()
            db.close()
        }

        // RawTraceStore opens read-only, so it cannot migrate — it must fall back to
        // the legacy SELECT and report version 1 (the only version that predates the
        // column) while still restoring the persisted id.
        let raw = try await RawTraceStore(fileURL: storeURL).fetchAllRuns()
        let rawEvent = try XCTUnwrap(raw.first?.events.first)
        XCTAssertEqual(rawEvent.id, eventID)
        XCTAssertEqual(rawEvent.schemaVersion, 1)

        // SQLiteTraceStore opens read-write and migrates the column in place.
        let store = try SQLiteTraceStore<TestEvent>(fileURL: storeURL)
        let maybeRun = try await store.getRun(id: runID)
        let run = try XCTUnwrap(maybeRun)
        XCTAssertEqual(run.events.first?.schemaVersion, 1)
        XCTAssertEqual(run.events.first?.id, eventID)
    }
}
