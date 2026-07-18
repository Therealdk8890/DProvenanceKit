import XCTest
@testable import DProvenanceKit
import Foundation

private struct ChunkPayload: TraceableEvent {
    let n: Int
    var typeIdentifier: String { "chunk" }
    var priority: TracePriority { .structural }
}

/// `getEvents(ids:)` chunks its `IN` clause at 900 bound parameters per statement so an
/// unbounded lineage/impact id closure can never exceed a linked SQLite build's
/// parameter cap (999 before 3.32; Apple's system build is far higher, so the cap
/// itself is not reproducible on this platform). This pins the multi-chunk path:
/// no requested id lost, none duplicated, across chunk boundaries.
final class SQLiteGetEventsChunkingTests: XCTestCase {
    var storeURL: URL!

    override func setUp() async throws {
        storeURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: storeURL)
    }

    func testLargeIdSetSpansMultipleChunksLosslessly() async throws {
        let store = try SQLiteTraceStore<ChunkPayload>(fileURL: storeURL)
        let runID = UUID()
        var ids: Set<UUID> = []
        var expectedN: [UUID: Int] = [:]
        // 2050 ids → chunks of 900/900/250: two full statements plus a remainder.
        for n in 0..<2050 {
            let event = TraceEvent(
                runID: runID, contextID: "ctx", engineName: "e", schemaVersion: 1,
                sequence: UInt64(n + 1), spanID: nil, parentSpanID: nil,
                payload: ChunkPayload(n: n), timestamp: Date())
            ids.insert(event.id)
            expectedN[event.id] = n
            store.record(event)
        }

        let fetched = try await store.getEvents(ids: ids)

        XCTAssertEqual(fetched.count, 2050, "every requested id must come back exactly once across chunk boundaries")
        XCTAssertEqual(Set(fetched.keys), ids)
        for (id, event) in fetched {
            XCTAssertEqual(event.payload.n, expectedN[id], "payload must stay bound to its own id through the per-chunk merge")
        }
        await store.close()
    }
}
