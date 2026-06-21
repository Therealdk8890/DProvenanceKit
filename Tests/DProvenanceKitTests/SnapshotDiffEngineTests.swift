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

    func testDiffComparesPayloadValueNotEncodedHash() throws {
        // Regression guard for the lossy-signature bug: the diff must reflect the
        // payload *value*, not a hash of its JSON encoding. These two payloads differ
        // only in a field that Codable drops, so they encode to identical bytes — a
        // hash-of-encoding signature would call them equal and silently miss the change.
        let runID = UUID()
        let eventID = UUID()
        let spanA = "spanA"

        func event(_ payload: MaskedPayload) -> TraceEvent<MaskedPayload> {
            TraceEvent(
                id: eventID, runID: runID, contextID: "ctx", engineName: "engine",
                schemaVersion: 1, sequence: 1, spanID: spanA, parentSpanID: nil, payload: payload
            )
        }

        let a = MaskedPayload(label: "x", hiddenState: 1)
        let b = MaskedPayload(label: "x", hiddenState: 2)

        // Precondition: the two payloads really do encode to identical bytes...
        let encoder = JSONEncoder()
        XCTAssertEqual(try encoder.encode(a), try encoder.encode(b),
                       "precondition: the excluded field must make the encodings identical")
        // ...but they are not equal, so the diff must report a modification.
        XCTAssertNotEqual(a, b)

        let base = TraceReplayEngine(committed: [event(a)]).snapshot()
        let comp = TraceReplayEngine(committed: [event(b)]).snapshot()
        let diff = SnapshotDiffEngine<MaskedPayload>().diff(base: base, comparison: comp)

        XCTAssertEqual(diff.summary.modifiedEvents, 1,
                       "Equatable-distinct payloads must diff as modified even when their encodings collide")
        XCTAssertEqual(diff.summary.divergencePoints, 1)
    }
}

/// A payload whose Equatable identity includes a field that Codable drops. Two values
/// differing only in `hiddenState` encode to identical JSON but are not `==` — the exact
/// case a hash-of-encoding signature would silently miss.
private struct MaskedPayload: TraceableEvent {
    let label: String
    let hiddenState: Int

    var typeIdentifier: String { "masked" }
    var priority: TracePriority { .structural }

    enum CodingKeys: String, CodingKey { case label }

    init(label: String, hiddenState: Int) {
        self.label = label
        self.hiddenState = hiddenState
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(label, forKey: .label)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.label = try c.decode(String.self, forKey: .label)
        self.hiddenState = 0
    }
}
