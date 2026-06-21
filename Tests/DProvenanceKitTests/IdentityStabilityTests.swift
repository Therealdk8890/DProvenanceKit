import XCTest
@testable import DProvenanceKit
@testable import DProvenanceUI

final class IdentityStabilityTests: XCTestCase {
    
    // Minimal mock event for testing the UI models
    struct MockUIEvent: TraceableEvent {
        let typeIdentifier: String = "TestEvent"
        let priority: TracePriority = .diagnostic
    }
    
    private func createEvent(runID: UUID, seq: UInt64, spanID: String?, parentSpanID: String?) -> TraceEvent<MockUIEvent> {
        return TraceEvent(
            id: UUID(),
            runID: runID,
            contextID: "ctx",
            engineName: "engine",
            schemaVersion: 1,
            sequence: seq,
            spanID: spanID,
            parentSpanID: parentSpanID,
            payload: MockUIEvent(),
            timestamp: Date()
        )
    }
    
    func testStableIdentityAcrossSnapshots() {
        let runID = UUID()
        let spanA = "spanA"
        
        let e1 = createEvent(runID: runID, seq: 1, spanID: spanA, parentSpanID: nil)
        let engine1 = TraceReplayEngine(committed: [e1])
        let snap1 = engine1.snapshot()
        
        let e2 = createEvent(runID: runID, seq: 2, spanID: spanA, parentSpanID: nil)
        let engine2 = TraceReplayEngine(committed: [e1, e2])
        let snap2 = engine2.snapshot()
        
        let hints = RenderHints()
        
        let viewModels1 = snap1.roots.map { 
            SpanViewModel(node: $0, snapshotID: "snap_1", localPathHash: "hash1", depth: 0, hints: hints) 
        }
        
        let viewModels2 = snap2.roots.map { 
            SpanViewModel(node: $0, snapshotID: "snap_2", localPathHash: "hash1", depth: 0, hints: hints) 
        }
        
        XCTAssertEqual(viewModels1.count, 1)
        XCTAssertEqual(viewModels2.count, 1)
        
        // renderIDs should reflect the distinct snapshots but map to the same base identity concept
        XCTAssertEqual(viewModels1[0].renderID, "spanA::snap_1::hash1")
        XCTAssertEqual(viewModels2[0].renderID, "spanA::snap_2::hash1")
    }
    
    func testNoDuplicateRenderIDsInFlattenedOutput() {
        let runID = UUID()
        let rootSpan = "root"
        let child1 = "child1"
        let child2 = "child2" // Another span at the same level
        
        let events = [
            createEvent(runID: runID, seq: 1, spanID: rootSpan, parentSpanID: nil),
            createEvent(runID: runID, seq: 2, spanID: child1, parentSpanID: rootSpan),
            createEvent(runID: runID, seq: 3, spanID: child2, parentSpanID: rootSpan)
        ]
        
        let snap = TraceReplayEngine(committed: events).snapshot()
        let hints = RenderHints(collapsedByDefault: [])
        
        let rootModels = snap.roots.map { 
            SpanViewModel(node: $0, snapshotID: "snap_1", localPathHash: "baseHash", depth: 0, hints: hints) 
        }
        
        let flattened = flattenSpanTree(roots: rootModels, dynamicCollapsed: [])
        
        let ids = flattened.map { $0.id }
        let uniqueIDs = Set(ids)
        
        XCTAssertEqual(ids.count, uniqueIDs.count, "Flattened nodes must have strictly unique identities.")
        XCTAssertEqual(ids.count, 3, "Expected 3 flattened nodes")
        
        // All nodes should be marked visible by default
        XCTAssertTrue(flattened.allSatisfy { $0.isVisible })
    }
}
