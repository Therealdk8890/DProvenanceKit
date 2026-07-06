import XCTest
@testable import DProvenanceKit
import Foundation

/// Covers the reachability fix: `run` now hands back the `runID`, and `getRun` is on
/// the `TraceStore` protocol, so the Run → Record → Query → Diff loop closes from a
/// single call instead of requiring an empty-query detour to recover the run.
final class RunHandleLoopTests: XCTestCase {

    func testRunReturnsRunIDAndGetRunClosesLoop_InMemory() async throws {
        let store = InMemoryTraceStore<TestEvent>()

        let (result, runID) = await DProvenanceKit<TestEvent>.runReturningID(contextID: "loop", store: store) { run in
            _ = run.record(.processStarted, engineName: nil)
            DProvenanceKit<TestEvent>.record(.stepCompleted(1))
            _ = run.record(.processFinished, engineName: nil)
            return "done"
        }

        XCTAssertEqual(result, "done")

        let fetched = try await store.getRun(id: runID)
        let run = try XCTUnwrap(fetched, "getRun must return the run just recorded")
        XCTAssertEqual(run.runID, runID)
        XCTAssertEqual(run.events.map { $0.payload.typeIdentifier },
                       ["processStarted", "stepCompleted", "processFinished"])
    }

    func testRunReturnsRunIDAndGetRunClosesLoop_SQLite() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteTraceStore<TestEvent>(fileURL: url, maxGlobalBuffer: 10_000, maxPerRunBuffer: 1000)

        let (_, runID) = await DProvenanceKit<TestEvent>.runReturningID(contextID: "loop", store: store) { _ in
            DProvenanceKit<TestEvent>.record(.processStarted)
            DProvenanceKit<TestEvent>.record(.processFinished)
        }

        let fetched = try await store.getRun(id: runID)
        let run = try XCTUnwrap(fetched)
        XCTAssertEqual(run.runID, runID)
        XCTAssertEqual(run.events.count, 2)
    }

    func testGetRunReturnsNilForUnknownID() async throws {
        let store = InMemoryTraceStore<TestEvent>()
        let missing = try await store.getRun(id: UUID())
        XCTAssertNil(missing)
    }

    func testRecordedRunsCanBeDiffedViaGetRun() async throws {
        // The payoff: fetch two runs back by id and diff them directly.
        let store = InMemoryTraceStore<TestEvent>()

        let (_, idA) = await DProvenanceKit<TestEvent>.runReturningID(contextID: "A", store: store) { _ in
            DProvenanceKit<TestEvent>.record(.processStarted)
            DProvenanceKit<TestEvent>.record(.stepCompleted(1))
            DProvenanceKit<TestEvent>.record(.processFinished)
        }
        let (_, idB) = await DProvenanceKit<TestEvent>.runReturningID(contextID: "B", store: store) { _ in
            DProvenanceKit<TestEvent>.record(.processStarted)
            DProvenanceKit<TestEvent>.record(.processFinished)
        }

        let fetchedA = try await store.getRun(id: idA)
        let fetchedB = try await store.getRun(id: idB)
        let runA = try XCTUnwrap(fetchedA)
        let runB = try XCTUnwrap(fetchedB)

        // `stepCompleted` is telemetry priority, so diff at that floor to include it.
        let diff = TraceDiffEngine<TestEvent>().diff(base: runA, comparison: runB, minimumPriority: .telemetry)
        // B dropped the `stepCompleted` step that A had, so the diff is non-empty.
        XCTAssertFalse(diff.changes.isEmpty)
        XCTAssertTrue(diff.changes.contains { $0.kind == .removed },
                      "the run fetched by id must diff as missing the dropped step")
    }
}
