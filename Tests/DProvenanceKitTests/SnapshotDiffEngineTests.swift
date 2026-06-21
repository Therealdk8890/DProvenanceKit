import XCTest
@testable import DProvenanceKit

final class SnapshotDiffEngineTests: XCTestCase {
    
    enum MockEvent: TraceableEvent, Equatable {
        case start
        case middle(String)
        case end
        
        var typeIdentifier: String {
            switch self {
            case .start: return "start"
            case .middle: return "middle"
            case .end: return "end"
            }
        }
        
        var priority: TracePriority { .structural }
    }
    
    func createEvent(id: UUID = UUID(), runID: UUID, seq: UInt64, spanID: String?, parentSpanID: String?, payload: MockEvent) -> TraceEvent<MockEvent> {
        return TraceEvent(
            id: id,
            runID: runID,
            contextID: "test_context",
            engineName: "test_engine",
            schemaVersion: 1,
            sequence: seq,
            spanID: spanID,
            parentSpanID: parentSpanID,
            payload: payload
        )
    }
    
    func testTemporalAdditions() {
        let runID = UUID()
        let spanA = UUID().uuidString
        
        let e1 = createEvent(runID: runID, seq: 1, spanID: spanA, parentSpanID: nil, payload: .start)
        let e2 = createEvent(runID: runID, seq: 2, spanID: spanA, parentSpanID: nil, payload: .middle("A"))
        
        let engineBase = TraceReplayEngine(committed: [e1])
        let baseSnapshot = engineBase.snapshot()
        
        let engineComp = TraceReplayEngine(committed: [e1, e2])
        let compSnapshot = engineComp.snapshot()
        
        let diffEngine = SnapshotDiffEngine<MockEvent>()
        let diff = diffEngine.diff(base: baseSnapshot, comparison: compSnapshot)
        
        XCTAssertEqual(diff.summary.addedSpans, 0)
        XCTAssertEqual(diff.summary.addedEvents, 1)
        XCTAssertEqual(diff.summary.modifiedEvents, 0)
        XCTAssertEqual(diff.summary.divergencePoints, 0)
        
        if case .added(let e, let spanID) = diff.eventChanges.first! {
            XCTAssertEqual(e.event.sequence, 2)
            XCTAssertEqual(spanID, spanA)
        } else {
            XCTFail("Expected added event")
        }
    }
    
    func testPayloadModifications() {
        let runID = UUID()
        let eventID = UUID()
        let spanA = UUID().uuidString
        
        let e1 = createEvent(id: eventID, runID: runID, seq: 1, spanID: spanA, parentSpanID: nil, payload: .middle("A"))
        let e1Modified = createEvent(id: eventID, runID: runID, seq: 1, spanID: spanA, parentSpanID: nil, payload: .middle("B"))
        
        let baseSnapshot = TraceReplayEngine(committed: [e1]).snapshot()
        let compSnapshot = TraceReplayEngine(committed: [e1Modified]).snapshot()
        
        let diff = SnapshotDiffEngine<MockEvent>().diff(base: baseSnapshot, comparison: compSnapshot)
        
        XCTAssertEqual(diff.summary.addedEvents, 0)
        XCTAssertEqual(diff.summary.removedEvents, 0)
        XCTAssertEqual(diff.summary.modifiedEvents, 1)
        XCTAssertEqual(diff.summary.divergencePoints, 1) // Divergence triggers at seq 1 because signature differs
        
        if case .modified(let before, let after, _) = diff.eventChanges.first! {
            XCTAssertEqual(before.event.payload, .middle("A"))
            XCTAssertEqual(after.event.payload, .middle("B"))
        } else {
            XCTFail("Expected modified event")
        }
    }
    
    func testSpanReparenting() {
        let runID = UUID()
        let spanA = "spanA"
        let spanB = "spanB"
        let spanC = "spanC"
        
        let rootA = createEvent(runID: runID, seq: 0, spanID: spanA, parentSpanID: nil, payload: .start)
        let rootB = createEvent(runID: runID, seq: 0, spanID: spanB, parentSpanID: nil, payload: .start)
        
        // Base: spanA -> spanC
        let baseEvent = createEvent(runID: runID, seq: 1, spanID: spanC, parentSpanID: spanA, payload: .start)
        
        // Comp: spanB -> spanC
        let compEvent = createEvent(runID: runID, seq: 1, spanID: spanC, parentSpanID: spanB, payload: .start)
        
        let baseSnapshot = TraceReplayEngine(committed: [rootA, rootB, baseEvent]).snapshot()
        let compSnapshot = TraceReplayEngine(committed: [rootA, rootB, compEvent]).snapshot()
        
        let diff = SnapshotDiffEngine<MockEvent>().diff(base: baseSnapshot, comparison: compSnapshot)
        
        XCTAssertEqual(diff.spanChanges.count, 1)
        if case .reparented(let spanID, let fromParent, let toParent) = diff.spanChanges.first! {
            XCTAssertEqual(spanID, spanC)
            XCTAssertEqual(fromParent, spanA)
            XCTAssertEqual(toParent, spanB)
        } else {
            XCTFail("Expected reparented span")
        }
    }
    
    func testContaminationChanges() {
        let runID = UUID()
        let spanA = "spanA"
        
        let e1 = createEvent(runID: runID, seq: 1, spanID: spanA, parentSpanID: nil, payload: .start)
        let e2 = createEvent(runID: runID, seq: 2, spanID: spanA, parentSpanID: nil, payload: .end)
        
        let baseSnapshot = TraceReplayEngine(committed: [e1, e2]).snapshot()
        let compSnapshot = TraceReplayEngine(committed: [e1], quarantined: [e2]).snapshot()
        
        let diff = SnapshotDiffEngine<MockEvent>().diff(base: baseSnapshot, comparison: compSnapshot)
        
        print("BASE ROOTS: \(baseSnapshot.roots.map { $0.spanID })")
        print("BASE CONTAM: \(baseSnapshot.roots.first?.containsQuarantinedEvents)")
        print("COMP ROOTS: \(compSnapshot.roots.map { $0.spanID })")
        print("COMP CONTAM: \(compSnapshot.roots.first?.containsQuarantinedEvents)")
        print("SPAN CHANGES: \(diff.spanChanges)")
        
        XCTAssertEqual(diff.summary.contaminatedSpans, 1)
        XCTAssertEqual(diff.summary.modifiedEvents, 1) // e2 source changed from committed to quarantined
    }
    
    func testStructuralDivergence() {
        let runID = UUID()
        let spanA = "spanA"
        
        let e1 = createEvent(runID: runID, seq: 1, spanID: spanA, parentSpanID: nil, payload: .start)
        let e2Base = createEvent(runID: runID, seq: 2, spanID: spanA, parentSpanID: nil, payload: .middle("Branch 1"))
        let e2Comp = createEvent(runID: runID, seq: 2, spanID: spanA, parentSpanID: nil, payload: .middle("Branch 2"))
        
        let baseSnapshot = TraceReplayEngine(committed: [e1, e2Base]).snapshot()
        let compSnapshot = TraceReplayEngine(committed: [e1, e2Comp]).snapshot()
        
        let diff = SnapshotDiffEngine<MockEvent>().diff(base: baseSnapshot, comparison: compSnapshot)
        
        XCTAssertEqual(diff.summary.divergencePoints, 1)
        if let divergence = diff.divergences.first {
            XCTAssertEqual(divergence.spanID, spanA)
            XCTAssertEqual(divergence.commonPrefixLength, 1)
            XCTAssertEqual(divergence.divergenceSequence, 2)
            XCTAssertEqual(divergence.leftEvent?.event.payload, .middle("Branch 1"))
            XCTAssertEqual(divergence.rightEvent?.event.payload, .middle("Branch 2"))
        } else {
            XCTFail("Expected divergence")
        }
    }
    
    func testDiffSymmetry() {
        let runID = UUID()
        let spanA = "spanA"
        
        let e2Added = createEvent(runID: runID, seq: 2, spanID: spanA, parentSpanID: nil, payload: .middle("added"))
        
        let e1ModID = UUID()
        let e1Before = createEvent(id: e1ModID, runID: runID, seq: 1, spanID: spanA, parentSpanID: nil, payload: .middle("before"))
        let e1After = createEvent(id: e1ModID, runID: runID, seq: 1, spanID: spanA, parentSpanID: nil, payload: .middle("after"))
        
        let baseSnapshot = TraceReplayEngine(committed: [e1Before]).snapshot()
        let compSnapshot = TraceReplayEngine(committed: [e1After, e2Added]).snapshot()
        
        let engine = SnapshotDiffEngine<MockEvent>()
        let diffAB = engine.diff(base: baseSnapshot, comparison: compSnapshot)
        let diffBA = engine.diff(base: compSnapshot, comparison: baseSnapshot)
        
        // A -> B: 1 added event, 1 modified event
        XCTAssertEqual(diffAB.summary.addedEvents, 1)
        XCTAssertEqual(diffAB.summary.modifiedEvents, 1)
        XCTAssertEqual(diffAB.summary.removedEvents, 0)
        
        // B -> A: 1 removed event, 1 modified event
        XCTAssertEqual(diffBA.summary.addedEvents, 0)
        XCTAssertEqual(diffBA.summary.modifiedEvents, 1)
        XCTAssertEqual(diffBA.summary.removedEvents, 1)
        
        // Divergence points should mirror left/right
        XCTAssertEqual(diffAB.summary.divergencePoints, diffBA.summary.divergencePoints)
        if let divAB = diffAB.divergences.first, let divBA = diffBA.divergences.first {
            XCTAssertEqual(divAB.leftEvent?.event.id, divBA.rightEvent?.event.id)
            XCTAssertEqual(divAB.rightEvent?.event.id, divBA.leftEvent?.event.id)
        }
    }
}
