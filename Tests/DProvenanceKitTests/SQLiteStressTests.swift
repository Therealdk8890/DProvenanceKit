import XCTest
@testable import DProvenanceKit
import Foundation

// A dummy event for testing
enum TestEvent: TraceableEvent {
    case processStarted
    case stepCompleted(Int)
    case errorDetected
    case processFinished
    
    var typeIdentifier: String {
        switch self {
        case .processStarted: return "processStarted"
        case .stepCompleted: return "stepCompleted"
        case .errorDetected: return "errorDetected"
        case .processFinished: return "processFinished"
        }
    }
    
    var priority: TracePriority {
        switch self {
        case .processStarted, .processFinished: return .critical
        case .errorDetected: return .structural
        case .stepCompleted: return .telemetry
        }
    }
}

final class SQLiteStressTests: XCTestCase {
    var storeURL: URL!
    var store: SQLiteTraceStore<TestEvent>!
    
    override func setUp() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        storeURL = tempDir.appendingPathComponent(UUID().uuidString + ".sqlite")
        store = try SQLiteTraceStore(fileURL: storeURL, maxGlobalBuffer: 10_000, maxPerRunBuffer: 1000)
    }
    
    override func tearDown() async throws {
        try FileManager.default.removeItem(at: storeURL)
    }
    
    func testConcurrency10k() async throws {
        let store = self.store!
        // Run 100 concurrent tasks, each generating 100 events (10k total)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    let context = "stress_test_\(i)"
                    await DProvenanceKit<TestEvent>.run(contextID: context, store: store) {
                        DProvenanceKit<TestEvent>.record(.processStarted)
                        for j in 0..<98 {
                            DProvenanceKit<TestEvent>.record(.stepCompleted(j))
                        }
                        DProvenanceKit<TestEvent>.record(.processFinished)
                    }
                }
            }
        }
        
        try await store.flush()
        
        // Query to verify all 10k events made it
        let query = TraceQueryDSL<TestEvent>().requiring(step: "processFinished")
        let runs = try await store.queryRuns(query)
        
        XCTAssertEqual(runs.count, 100, "Should have 100 completed runs")
        let totalEvents = runs.reduce(0) { $0 + $1.events.count }
        XCTAssertEqual(totalEvents, 10000, "Should have exactly 10,000 recorded events")
    }
    
    func testQueryEngine() async throws {
        // Generate a run that matches our complex query
        await DProvenanceKit<TestEvent>.run(contextID: "q1", store: store) {
            DProvenanceKit<TestEvent>.record(.processStarted)
            DProvenanceKit<TestEvent>.record(.stepCompleted(1))
            DProvenanceKit<TestEvent>.record(.errorDetected)
            DProvenanceKit<TestEvent>.record(.processFinished)
        }
        
        // Generate a run that fails the query (missing error)
        await DProvenanceKit<TestEvent>.run(contextID: "q2", store: store) {
            DProvenanceKit<TestEvent>.record(.processStarted)
            DProvenanceKit<TestEvent>.record(.stepCompleted(1))
            DProvenanceKit<TestEvent>.record(.processFinished)
        }
        
        try await store.flush()
        
        // Query: Requires processFinished AND errorDetected AND missing stepCompleted(2) (which means stepCompleted type generally... wait, we only check type string)
        let query = TraceQueryDSL<TestEvent>()
            .requiring(step: "processFinished")
            .requiring(step: "errorDetected")
        
        let runs = try await store.queryRuns(query)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.contextID, "q1")
        
        // Test sequence logic translated to SQL
        let seqQuery = TraceQueryDSL<TestEvent>()
            .requiring(sequence: ["processStarted", "errorDetected", "processFinished"])
            
        let seqRuns = try await store.queryRuns(seqQuery)
        XCTAssertEqual(seqRuns.count, 1)
    }
    
    func testFlushIsBarrierAndPreservesRecordOrder() async throws {
        // After a run completes, an immediate flush + query must see EVERY recorded
        // event, in record order. With synchronous enqueue this is a structural
        // guarantee rather than a timing accident: `record` returns only once the
        // event is in the buffer, so `flush` cannot drain a partial run.
        let n = 500 // well under maxPerRunBuffer (1000) so nothing is legitimately dropped
        await DProvenanceKit<TestEvent>.run(contextID: "barrier", store: store) {
            DProvenanceKit<TestEvent>.record(.processStarted)
            for j in 0..<(n - 2) {
                DProvenanceKit<TestEvent>.record(.stepCompleted(j))
            }
            DProvenanceKit<TestEvent>.record(.processFinished)
        }

        try await store.flush()

        let runs = try await store.queryRuns(
            TraceQueryDSL<TestEvent>().filter(contextID: "barrier")
        )
        XCTAssertEqual(runs.count, 1)

        let events = runs.first!.events
        XCTAssertEqual(events.count, n, "Every recorded event must survive the flush barrier")

        // Sequence numbers must be contiguous 0..<n with no gaps or reordering.
        let sequences = events.map { $0.sequence }
        XCTAssertEqual(sequences, Array(0..<UInt64(n)), "Events must be contiguous and in record order")
    }

    func testBurstIngestionCollapse() async throws {
        // We set up a store with a very small global buffer to force dropping
        let tempDir = FileManager.default.temporaryDirectory
        let burstURL = tempDir.appendingPathComponent(UUID().uuidString + "_burst.sqlite")
        let smallStore = try SQLiteTraceStore<TestEvent>(fileURL: burstURL, maxGlobalBuffer: 100, maxPerRunBuffer: 50)
        
        // Run a task that floods the buffer with 200 telemetry events and 10 critical events
        await DProvenanceKit<TestEvent>.run(contextID: "rogue_agent", store: smallStore) {
            DProvenanceKit<TestEvent>.record(.processStarted) // Priority: critical (should survive)
            for j in 0..<200 {
                DProvenanceKit<TestEvent>.record(.stepCompleted(j)) // Priority: telemetry (should drop)
            }
            DProvenanceKit<TestEvent>.record(.processFinished) // Priority: critical (should survive)
        }
        
        try await smallStore.flush()
        
        let query = TraceQueryDSL<TestEvent>().requiring(step: "processStarted")
        let runs = try await smallStore.queryRuns(query)
        
        XCTAssertEqual(runs.count, 1)
        let events = runs.first!.events
        
        // The total events should be heavily truncated down to maxPerRunBuffer (50) or maxGlobalBuffer
        // But the critical events MUST still be there
        let hasStart = events.contains(where: { $0.payload.typeIdentifier == "processStarted" })
        let hasEnd = events.contains(where: { $0.payload.typeIdentifier == "processFinished" })
        
        XCTAssertTrue(hasStart, "Critical event 'processStarted' should survive the burst drop")
        XCTAssertTrue(hasEnd, "Critical event 'processFinished' should survive the burst drop")
        XCTAssertLessThan(events.count, 202, "Telemetry events should have been dropped")

        // The drop counter turns the survival check above into a guarantee: not only
        // did the critical events survive, but the only thing shed was telemetry, so
        // any diff over this run is still trustworthy. `preservedIntegrity` is the
        // load-bearing assertion — it is the difference between "we dropped some
        // events" and "we dropped nothing that could change a diff result".
        let drops = smallStore.dropStats
        XCTAssertGreaterThan(drops.total, 0, "The burst must have shed events under the small cap")
        XCTAssertGreaterThan(drops.telemetry, 0, "Telemetry is what should have been shed")
        XCTAssertEqual(drops.critical, 0, "No critical event may be dropped")
        XCTAssertEqual(drops.structural, 0, "No structural event may be dropped")
        XCTAssertTrue(drops.preservedIntegrity, "Shedding must leave diff integrity intact")

        try FileManager.default.removeItem(at: burstURL)
    }
}
