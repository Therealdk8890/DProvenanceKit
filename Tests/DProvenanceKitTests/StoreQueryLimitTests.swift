import XCTest
@testable import DProvenanceKit
import Foundation

/// Covers the bounded `queryRuns(_:limit:)` addition and confirms the SQLite store's
/// dedicated reader connection still observes the writer's committed data.
final class StoreQueryLimitTests: XCTestCase {

    private func recordRuns(_ n: Int, into store: any TraceStore<TestEvent>) async {
        for i in 0..<n {
            await DProvenanceKit<TestEvent>.run(contextID: "shared", store: store) {
                DProvenanceKit<TestEvent>.record(.processStarted)
                DProvenanceKit<TestEvent>.record(.stepCompleted(i))
            }
        }
    }

    func testInMemoryQueryRunsLimit() async throws {
        let store = InMemoryTraceStore<TestEvent>()
        await recordRuns(5, into: store)
        let dsl = TraceQueryDSL<TestEvent>().filter(contextID: "shared")

        let all = try await store.queryRuns(dsl)
        let capped = try await store.queryRuns(dsl, limit: 2)
        let zero = try await store.queryRuns(dsl, limit: 0)
        let unbounded = try await store.queryRuns(dsl, limit: nil)
        XCTAssertEqual(all.count, 5)
        XCTAssertEqual(capped.count, 2)
        XCTAssertEqual(zero.count, 0)
        XCTAssertEqual(unbounded.count, 5, "nil = unbounded")
    }

    func testSQLiteQueryRunsLimitBoundsResults() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteTraceStore<TestEvent>(fileURL: url)
        await recordRuns(5, into: store)
        let dsl = TraceQueryDSL<TestEvent>().filter(contextID: "shared")

        let all = try await store.queryRuns(dsl)
        let capped = try await store.queryRuns(dsl, limit: 3)
        let zero = try await store.queryRuns(dsl, limit: 0)
        XCTAssertEqual(all.count, 5)
        XCTAssertEqual(capped.count, 3)
        XCTAssertEqual(zero.count, 0)
    }

    /// Reads now use a separate connection; a record → flush → read round-trip must
    /// still return the committed data (the reader observes the writer's commits).
    func testReaderConnectionSeesCommittedWrites() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteTraceStore<TestEvent>(fileURL: url)

        let (_, runID) = await DProvenanceKit<TestEvent>.runReturningID(contextID: "iso", store: store) { _ in
            DProvenanceKit<TestEvent>.record(.processStarted)
            DProvenanceKit<TestEvent>.record(.processFinished)
        }
        let fetched = try await store.getRun(id: runID)
        let run = try XCTUnwrap(fetched)
        XCTAssertEqual(run.events.count, 2)
    }
}
