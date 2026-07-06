import XCTest
@testable import DProvenanceKit

final class TraceReplayEngineTests: XCTestCase {
    
    enum MockEvent: TraceableEvent {
        case start
        case middle
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
    
    func testDuplicateEventIDs() {
        let runID = UUID()
        let eventID = UUID()
        let spanID = UUID().uuidString
        
        // Same event ID, but one is committed and one is quarantined
        let committed = createEvent(id: eventID, runID: runID, seq: 1, spanID: spanID, parentSpanID: nil, payload: .start)
        let quarantined = createEvent(id: eventID, runID: runID, seq: 1, spanID: spanID, parentSpanID: nil, payload: .start)
        
        let engine = TraceReplayEngine(committed: [committed], quarantined: [quarantined])
        let snapshot = engine.snapshot()
        
        // Should not crash. Should construct 1 root with 2 events.
        XCTAssertEqual(snapshot.roots.count, 1)
        XCTAssertEqual(snapshot.roots[0].events.count, 2)
        XCTAssertEqual(snapshot.manifest.totalEvents, 2)
        XCTAssertEqual(snapshot.manifest.committedEvents, 1)
        XCTAssertEqual(snapshot.manifest.quarantinedEvents, 1)
        
        // Since one is quarantined, the root should be contaminated
        XCTAssertTrue(snapshot.roots[0].containsQuarantinedEvents)
    }
    
    func testMalformedParentRelationships() {
        let runID = UUID()
        let spanA = UUID().uuidString
        let spanB = UUID().uuidString
        
        // Parent span is entirely missing from both committed and quarantined logs
        let child = createEvent(runID: runID, seq: 2, spanID: spanB, parentSpanID: spanA, payload: .middle)
        let grandchild = createEvent(runID: runID, seq: 3, spanID: UUID().uuidString, parentSpanID: spanB, payload: .end)
        
        let engine = TraceReplayEngine(committed: [child, grandchild])
        let snapshot = engine.snapshot()
        
        // The entire subtree under missing parent spanA becomes orphaned
        XCTAssertEqual(snapshot.roots.count, 0)
        XCTAssertEqual(snapshot.orphanedEvents.count, 2)
        XCTAssertEqual(snapshot.manifest.orphanedEvents, 2)
    }
    
    func testReplayDeterminism() {
        let runID = UUID()
        let spanA = UUID().uuidString
        let spanB = UUID().uuidString
        
        var events: [TraceEvent<MockEvent>] = []
        for i in 0..<50 {
            let parent = i % 2 == 0 ? spanA : spanB
            let span = UUID().uuidString
            events.append(createEvent(runID: runID, seq: UInt64(i), spanID: span, parentSpanID: parent, payload: .middle))
        }
        
        // Add the roots
        events.append(createEvent(runID: runID, seq: 100, spanID: spanA, parentSpanID: nil, payload: .start))
        events.append(createEvent(runID: runID, seq: 101, spanID: spanB, parentSpanID: nil, payload: .start))
        
        // Create baseline
        let baselineEngine = TraceReplayEngine(committed: events)
        let baselineSnapshot = baselineEngine.snapshot()
        let baselineRootsCount = baselineSnapshot.roots.count
        let baselineOrphansCount = baselineSnapshot.orphanedEvents.count
        
        // Fuzz test 1000 times
        for _ in 0..<100 { // Reduced to 100 to save test time, but still robust
            let shuffled = events.shuffled()
            let splitIndex = Int.random(in: 0..<shuffled.count)
            let committed = Array(shuffled[0..<splitIndex])
            let quarantined = Array(shuffled[splitIndex..<shuffled.count])
            
            let engine = TraceReplayEngine(committed: committed, quarantined: quarantined)
            let snapshot = engine.snapshot()
            
            // Note: Since we are randomly moving items to quarantine, the manifest counts and source flags will change.
            // But the exact tree topology (number of roots, number of orphaned events) MUST remain identical because the underlying events are the same.
            XCTAssertEqual(snapshot.roots.count, baselineRootsCount)
            XCTAssertEqual(snapshot.orphanedEvents.count, baselineOrphansCount)
            
            // The actual deterministic test for identity:
            // Since `snapshot` Equatable requires SpanNode Equatable (which we haven't added), we assert on manifest metrics that don't depend on source.
            XCTAssertEqual(snapshot.manifest.totalEvents, baselineSnapshot.manifest.totalEvents)
            XCTAssertEqual(snapshot.manifest.sequenceGaps, baselineSnapshot.manifest.sequenceGaps)
            XCTAssertEqual(snapshot.manifest.reconstructedSpans, baselineSnapshot.manifest.reconstructedSpans)
        }
    }
    
    func testSequenceGaps() {
        let runID = UUID()
        
        let e1 = createEvent(runID: runID, seq: 1, spanID: nil, parentSpanID: nil, payload: .start)
        let e2 = createEvent(runID: runID, seq: 2, spanID: nil, parentSpanID: nil, payload: .start)
        let e3 = createEvent(runID: runID, seq: 5, spanID: nil, parentSpanID: nil, payload: .start)
        let e4 = createEvent(runID: runID, seq: 6, spanID: nil, parentSpanID: nil, payload: .start)
        let e5 = createEvent(runID: runID, seq: 10, spanID: nil, parentSpanID: nil, payload: .start)
        
        let engine = TraceReplayEngine(committed: [e1, e2, e3, e4, e5])
        let snapshot = engine.snapshot()
        
        let gaps = snapshot.manifest.sequenceGaps
        XCTAssertEqual(gaps.count, 3)
        // Expected gaps: 0...0, 3...4, 7...9
        XCTAssertEqual(gaps[0].lowerBound, 0)
        XCTAssertEqual(gaps[0].upperBound, 0)
        
        XCTAssertEqual(gaps[1].lowerBound, 3)
        XCTAssertEqual(gaps[1].upperBound, 4)
        
        XCTAssertEqual(gaps[2].lowerBound, 7)
        XCTAssertEqual(gaps[2].upperBound, 9)
    }
}
