import XCTest
@testable import DProvenanceKit

/// Regressions for silent data-integrity losses: values coerced, dropped, or trapped on
/// instead of surfaced.
final class DataIntegrityRegressionTests: XCTestCase {
    enum Event: TraceableEvent, Equatable {
        case step(String)
        var typeIdentifier: String { "step" }
        var priority: TracePriority { .structural }
    }

    private var tempFiles: [URL] = []

    override func tearDown() {
        for url in tempFiles {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
        }
        tempFiles = []
        super.tearDown()
    }

    private func tempStoreURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dpk-integrity-\(UUID().uuidString).sqlite")
        tempFiles.append(url)
        return url
    }

    private func makeEvent(run: UUID, seq: UInt64, _ label: String) -> TraceEvent<Event> {
        TraceEvent(runID: run, contextID: "ctx", engineName: "e", schemaVersion: 1, sequence: seq,
                   spanID: nil, parentSpanID: nil, payload: .step(label), timestamp: Date())
    }

    /// Writes two linked events and closes the store, returning their ids.
    private func seedStore(at url: URL) async throws -> (source: UUID, target: UUID) {
        let store = try SQLiteTraceStore<Event>(fileURL: url)
        let run = UUID()
        let a = makeEvent(run: run, seq: 0, "a"), b = makeEvent(run: run, seq: 1, "b")
        store.record(a)
        store.record(b)
        store.link(source: a.id, target: b.id, type: .derivedFrom)
        try await store.flush()
        _ = await store.close()
        return (a.id, b.id)
    }

    // MARK: #4 edge decoding

    func testUnknownEdgeTypeFailsInsteadOfBecomingInformed() async throws {
        let url = tempStoreURL()
        let ids = try await seedStore(at: url)
        let raw = try SQLiteConnection(fileURL: url)
        try raw.execute("UPDATE trace_edges SET edge_type = 'refutedBy';")

        let store = try SQLiteTraceStore<Event>(fileURL: url)
        do {
            let edges = try await store.lineageEdges(of: ids.target)
            XCTFail("an unknown edge type must not be read back as \(edges.map(\.type))")
        } catch TraceError.corruptEdgeRow(_, _, let type) {
            XCTAssertEqual(type, "refutedBy")
        }
        do {
            _ = try await store.impactEdges(of: ids.source)
            XCTFail("impact traversal must fail the same way")
        } catch TraceError.corruptEdgeRow {}
        _ = await store.close()
    }

    func testMalformedEdgeUUIDFailsInsteadOfTruncatingLineage() async throws {
        let url = tempStoreURL()
        let ids = try await seedStore(at: url)
        let raw = try SQLiteConnection(fileURL: url)
        try raw.execute("INSERT INTO trace_edges (source_id, target_id, edge_type) VALUES ('not-a-uuid', '\(ids.target.uuidString)', 'informed');")

        let store = try SQLiteTraceStore<Event>(fileURL: url)
        do {
            _ = try await store.lineageEdges(of: ids.target)
            XCTFail("a malformed row used to be skipped, silently shortening lineage")
        } catch TraceError.corruptEdgeRow(let source, _, _) {
            XCTAssertEqual(source, "not-a-uuid")
        }
        _ = await store.close()
    }

    func testWellFormedEdgesStillRoundTrip() async throws {
        let url = tempStoreURL()
        let ids = try await seedStore(at: url)
        let store = try SQLiteTraceStore<Event>(fileURL: url)
        let edges = try await store.lineageEdges(of: ids.target)
        XCTAssertEqual(edges, [TraceEdge(sourceID: ids.source, targetID: ids.target, type: .derivedFrom)])
        _ = await store.close()
    }

    // MARK: #5 recordAny type mismatch

    func testTypeMismatchIsCountedNotSilent() {
        let run = DProvenanceKit<Event>.ActiveTraceRun(contextID: "ctx", store: InMemoryTraceStore<Event>())
        XCTAssertNil(run.recordAny("a foreign payload", engineName: nil))
        XCTAssertNil(run.recordAny(42, engineName: nil))
        XCTAssertEqual(run.payloadTypeMismatchCount, 2)
        XCTAssertNotNil(run.recordAny(Event.step("ok"), engineName: nil))
        XCTAssertEqual(run.payloadTypeMismatchCount, 2, "a matching payload is not a mismatch")
    }

    // MARK: #6 bounded edge queue

    func testPendingEdgesAreCappedAndOverflowIsAStructuralDrop() {
        let buffer = TraceWriteBuffer(config: OfflineConfig(capacity: BufferCapacity(maxPendingEdges: 2)))
        for _ in 0..<3 {
            buffer.enqueueEdge(TraceEdge(sourceID: UUID(), targetID: UUID(), type: .informed))
        }
        XCTAssertEqual(buffer.pendingEdgeCount, 2)
        XCTAssertEqual(buffer.dropStats.structural, 1)
        XCTAssertFalse(buffer.dropStats.preservedIntegrity)

        XCTAssertEqual(buffer.drainEdges().count, 2)
        buffer.enqueueEdge(TraceEdge(sourceID: UUID(), targetID: UUID(), type: .informed))
        XCTAssertEqual(buffer.pendingEdgeCount, 1, "draining frees capacity again")
        XCTAssertEqual(BufferCapacity().maxPendingEdges, 100_000)
    }

    // MARK: #11 raw inspector reads

    func testRawStoreSurfacesInvalidUTF8AndNegativeSequenceWithoutTrapping() async throws {
        let url = tempStoreURL()
        _ = try await seedStore(at: url)
        let raw = try SQLiteConnection(fileURL: url)
        try raw.execute("UPDATE trace_events SET payload = X'FFFE7B7D', sequence = -1 WHERE sequence = 0;")

        let runs = try await RawTraceStore(fileURL: url).fetchAllRuns()
        let events = try XCTUnwrap(runs.first?.events)
        let corrupt = try XCTUnwrap(events.first { !$0.payloadIsValidUTF8 })
        XCTAssertNotEqual(corrupt.payloadJSON, "{}", "bytes must not be replaced with a fabricated empty object")
        XCTAssertTrue(corrupt.payloadJSON.hasSuffix("{}"), "valid trailing bytes survive the lossy decode")
        XCTAssertEqual(corrupt.sequence, UInt64(bitPattern: -1))
        XCTAssertTrue(events.contains { $0.payloadIsValidUTF8 && $0.sequence == 1 })
    }

    // MARK: #12 schema version

    func testStoreRefusesAFileFromANewerSchema() async throws {
        let url = tempStoreURL()
        _ = try await seedStore(at: url)
        let raw = try SQLiteConnection(fileURL: url)
        XCTAssertEqual(try raw.readUserVersion(), SQLiteTraceStore<Event>.currentSchemaVersion)
        try raw.setUserVersion(SQLiteTraceStore<Event>.currentSchemaVersion + 1)

        XCTAssertThrowsError(try SQLiteTraceStore<Event>(fileURL: url)) { error in
            guard case SQLiteError.unsupportedSchemaVersion(let found, let supported)? = error as? SQLiteError else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(found, supported + 1)
        }
        XCTAssertEqual(try raw.readUserVersion(), SQLiteTraceStore<Event>.currentSchemaVersion + 1,
                       "the refused open must not rewrite the version")
    }

    func testUserVersionWriteFailureIsThrownNotSwallowed() throws {
        let url = tempStoreURL()
        _ = try SQLiteConnection(fileURL: url)
        let readOnly = try SQLiteConnection(fileURL: url, mode: .readOnly)
        XCTAssertThrowsError(try readOnly.setUserVersion(7))
    }
}
