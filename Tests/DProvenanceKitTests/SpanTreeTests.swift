import XCTest
@testable import DProvenanceKit

final class SpanTreeTests: XCTestCase {
    
    enum MockEvent: TraceableEvent {
        case taskStarted
        case processingData
        case taskCompleted
        
        var typeIdentifier: String {
            switch self {
            case .taskStarted: return "taskStarted"
            case .processingData: return "processingData"
            case .taskCompleted: return "taskCompleted"
            }
        }
        
        var priority: TracePriority {
            switch self {
            case .taskStarted, .taskCompleted: return .structural
            case .processingData: return .telemetry
            }
        }
    }
    
    var storeURL: URL!
    var store: SQLiteTraceStore<MockEvent>!
    
    override func setUp() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        storeURL = tempDir.appendingPathComponent(UUID().uuidString + ".sqlite")
        store = try SQLiteTraceStore(fileURL: storeURL)
    }
    
    override func tearDown() async throws {
        try FileManager.default.removeItem(at: storeURL)
    }
    
    func testNestedSpans() async throws {
        let contextID = "hierarchy_test_1"
        
        await DProvenanceKit<MockEvent>.run(contextID: contextID, store: store) {
            
            // At root, there is no spanID
            DProvenanceKit<MockEvent>.record(.taskStarted)
            
            _ = await DProvenanceKit<MockEvent>.withSpan {
                // Inside the first span
                DProvenanceKit<MockEvent>.record(.processingData)
                
                _ = await DProvenanceKit<MockEvent>.withSpan {
                    // Inside the nested span
                    DProvenanceKit<MockEvent>.record(.taskCompleted)
                }
            }
        }
        
        try await store.flush()
        
        // Query the DB directly
        let query = TraceQueryDSL<MockEvent>()
        let runs = try await store.queryRuns(query)
        
        XCTAssertEqual(runs.count, 1)
        let events = runs.first!.events
        XCTAssertEqual(events.count, 3)
        
        // 1. Root event
        let rootEvent = events.first { $0.payload.typeIdentifier == "taskStarted" }!
        XCTAssertNil(rootEvent.spanID)
        XCTAssertNil(rootEvent.parentSpanID)
        
        // 2. Child event
        let childEvent = events.first { $0.payload.typeIdentifier == "processingData" }!
        XCTAssertNotNil(childEvent.spanID)
        XCTAssertNil(childEvent.parentSpanID) // Parent was root
        
        // 3. Grandchild event
        let grandchildEvent = events.first { $0.payload.typeIdentifier == "taskCompleted" }!
        XCTAssertNotNil(grandchildEvent.spanID)
        XCTAssertEqual(grandchildEvent.parentSpanID, childEvent.spanID, "Grandchild parent should equal child spanID")
        XCTAssertNotEqual(grandchildEvent.spanID, childEvent.spanID, "Grandchild should have a unique spanID")
    }
}
