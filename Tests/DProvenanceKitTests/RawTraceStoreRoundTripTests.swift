import XCTest
@testable import DProvenanceKit
import Foundation

/// Exercises the *viewer's* read path — `RawTraceStore.fetchAllRuns()` — which is
/// exactly what the trace UI (e.g. CaseClarity's "AI Thought Process" view) uses to
/// reopen a database written by another connection. Nothing else in the suite reads
/// through `RawTraceStore`, so this is the test that fails if a bound string or blob
/// is corrupted on the round trip (the SQLITE_STATIC-vs-SQLITE_TRANSIENT class of bug:
/// SQLite reads bound text/blob pointers lazily at step() time, so a pointer that does
/// not outlive `bind()` silently rots the persisted value).
final class RawTraceStoreRoundTripTests: XCTestCase {
    var storeURL: URL!

    override func setUp() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        storeURL = tempDir.appendingPathComponent(UUID().uuidString + ".sqlite")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: storeURL)
    }

    func testWrittenRunSurvivesRawTraceStoreReopen() async throws {
        // Write a known run through the production write path...
        let store = try SQLiteTraceStore<TestEvent>(fileURL: storeURL)
        await DProvenanceKit<TestEvent>.run(contextID: "roundtrip", store: store) {
            DProvenanceKit<TestEvent>.record(.processStarted)
            DProvenanceKit<TestEvent>.record(.stepCompleted(7))
            DProvenanceKit<TestEvent>.record(.errorDetected)
            DProvenanceKit<TestEvent>.record(.processFinished)
        }
        try await store.flush()

        // ...then reopen through the exact path the viewer uses. The data is
        // durable on disk after flush(), so a fresh connection must see it.
        let reader = try RawTraceStore(fileURL: storeURL)
        let runs = try await reader.fetchAllRuns()

        // Run-level strings must survive (catches `bind(String)` corruption).
        XCTAssertEqual(runs.count, 1)
        let run = try XCTUnwrap(runs.first)
        XCTAssertEqual(run.contextID, "roundtrip")
        XCTAssertEqual(run.eventCount, 4)
        XCTAssertEqual(run.events.count, 4)

        // Event type identifiers must survive, in recorded sequence order.
        XCTAssertEqual(
            run.events.map(\.typeIdentifier),
            ["processStarted", "stepCompleted", "errorDetected", "processFinished"]
        )
        XCTAssertEqual(run.events.map(\.sequence), [0, 1, 2, 3] as [UInt64])

        // Payload blobs must survive intact and decode back to the original events
        // (catches `bind(Data)` corruption on the lazily-read blob column).
        let decoder = JSONDecoder()
        for raw in run.events {
            XCTAssertFalse(raw.payloadJSON.isEmpty, "payload for \(raw.typeIdentifier) was empty")
            XCTAssertNotEqual(raw.payloadJSON, "{}", "payload for \(raw.typeIdentifier) came back blank")
            let decoded = try decoder.decode(TestEvent.self, from: Data(raw.payloadJSON.utf8))
            XCTAssertEqual(decoded.typeIdentifier, raw.typeIdentifier)
        }

        // The event carrying an associated value must preserve it verbatim.
        let step = try XCTUnwrap(run.events.first { $0.typeIdentifier == "stepCompleted" })
        let decodedStep = try decoder.decode(TestEvent.self, from: Data(step.payloadJSON.utf8))
        XCTAssertEqual(decodedStep, .stepCompleted(7))
    }
}
