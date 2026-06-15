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
}

final class SQLiteStressTests: XCTestCase {
    var storeURL: URL!
    var store: SQLiteTraceStore<TestEvent>!
    
    override func setUp() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        storeURL = tempDir.appendingPathComponent(UUID().uuidString + ".sqlite")
        store = try SQLiteTraceStore(fileURL: storeURL, maxBufferSize: 10_000)
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
}
