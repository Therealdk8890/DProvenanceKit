import XCTest
@testable import DProvenanceKit

final class TraceDiffEngineTests: XCTestCase {
    
    // Test event matching our mock definition
    enum TestEvent: TraceableEvent {
        case stepA
        case stepB
        case stepC
        case stepD
        case noise(Int)
        
        var typeIdentifier: String {
            switch self {
            case .stepA: return "stepA"
            case .stepB: return "stepB"
            case .stepC: return "stepC"
            case .stepD: return "stepD"
            case .noise(let val): return "noise_\(val)"
            }
        }
        
        var priority: TracePriority {
            switch self {
            case .stepA, .stepB, .stepC, .stepD: return .structural
            case .noise: return .telemetry
            }
        }
    }
    
    func createMockRun(id: UUID, seqEvents: [(UInt64, String, TestEvent)]) -> TraceRun<TestEvent> {
        let events = seqEvents.map { (seq, engine, payload) in
            TraceEvent(
                runID: id,
                contextID: "test_ctx",
                engineName: engine,
                schemaVersion: 1,
                sequence: seq,
                spanID: nil,
                parentSpanID: nil,
                payload: payload,
                timestamp: Date()
            )
        }
        return TraceRun(runID: id, contextID: "test_ctx", events: events)
    }

    func testCausalDiffIgnoresTelemetry() {
        let runA = UUID()
        let runB = UUID()
        
        let baseRun = createMockRun(id: runA, seqEvents: [
            (0, "engine1", .stepA),
            (1, "engine1", .noise(1)),
            (2, "engine1", .stepB),
            (3, "engine1", .noise(2)),
            (4, "engine1", .stepC)
        ])
        
        let compRun = createMockRun(id: runB, seqEvents: [
            (0, "engine1", .stepA),
            (1, "engine1", .noise(3)),
            (2, "engine1", .stepB),
            (3, "engine1", .stepC),
            (4, "engine1", .noise(4))
        ])
        
        let engine = TraceDiffEngine<TestEvent>()
        let diff = engine.diff(base: baseRun, comparison: compRun, minimumPriority: .structural)
        
        XCTAssertTrue(diff.isIdentical, "Diff should be identical when telemetry is ignored.")
        XCTAssertEqual(diff.changes.count, 0)
    }
    
    func testCausalDiffDetectsRemovalAndAddition() {
        let runA = UUID()
        let runB = UUID()
        
        // Base: A -> B -> C
        let baseRun = createMockRun(id: runA, seqEvents: [
            (0, "engine1", .stepA),
            (1, "engine1", .stepB),
            (2, "engine1", .stepC)
        ])
        
        // Comp: A -> C -> D (Removed B, Added D)
        let compRun = createMockRun(id: runB, seqEvents: [
            (0, "engine1", .stepA),
            (1, "engine1", .stepC),
            (2, "engine1", .stepD) // Note originalSequence = 2
        ])
        
        let engine = TraceDiffEngine<TestEvent>()
        let diff = engine.diff(base: baseRun, comparison: compRun, minimumPriority: .structural)
        
        XCTAssertFalse(diff.isIdentical)
        XCTAssertEqual(diff.changes.count, 2)
        
        let removal = diff.changes.first { $0.kind == .removed }!
        XCTAssertEqual(removal.typeIdentifier, "stepB")
        XCTAssertEqual(removal.originalSequence, 1)
        
        let addition = diff.changes.first { $0.kind == .added }!
        XCTAssertEqual(addition.typeIdentifier, "stepD")
        XCTAssertEqual(addition.originalSequence, 2)
    }
    
    func testEngineNameCausesDivergence() {
        let runA = UUID()
        let runB = UUID()
        
        // Base: A (engine1) -> B (engine1)
        let baseRun = createMockRun(id: runA, seqEvents: [
            (0, "engine1", .stepA),
            (1, "engine1", .stepB)
        ])
        
        // Comp: A (engine1) -> B (engine2)
        let compRun = createMockRun(id: runB, seqEvents: [
            (0, "engine1", .stepA),
            (1, "engine2", .stepB)
        ])
        
        let engine = TraceDiffEngine<TestEvent>()
        let diff = engine.diff(base: baseRun, comparison: compRun, minimumPriority: .structural)
        
        XCTAssertFalse(diff.isIdentical)
        // Should detect engine1.stepB removed, engine2.stepB added
        XCTAssertEqual(diff.changes.count, 2)
        
        let removal = diff.changes.first { $0.kind == .removed }!
        XCTAssertEqual(removal.engineName, "engine1")
        XCTAssertEqual(removal.typeIdentifier, "stepB")
        
        let addition = diff.changes.first { $0.kind == .added }!
        XCTAssertEqual(addition.engineName, "engine2")
        XCTAssertEqual(addition.typeIdentifier, "stepB")
    }
}
