import XCTest
@testable import DProvenanceKit

final class TraceAlignmentEngineTests: XCTestCase {
    
    enum TestEvent: TraceableEvent {
        case stepA
        case stepB
        case stepC
        case stepD
        case noise(Int)
        case custom(String)
        
        var typeIdentifier: String {
            switch self {
            case .stepA: return "stepA"
            case .stepB: return "stepB"
            case .stepC: return "stepC"
            case .stepD: return "stepD"
            case .noise(let val): return "noise_\(val)"
            case .custom(let str): return str
            }
        }
        
        var priority: TracePriority {
            switch self {
            case .stepA, .stepB, .stepC, .stepD, .custom: return .structural
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
    
    func testLevel1StructuralCorrectness() {
        let runA = UUID()
        let runB = UUID()
        
        let baseRun = createMockRun(id: runA, seqEvents: [
            (0, "engine1", .stepA),
            (1, "engine1", .stepB),
            (2, "engine1", .stepC)
        ])
        
        let compRun = createMockRun(id: runB, seqEvents: [
            (0, "engine1", .stepA),
            (1, "engine1", .stepC),
            (2, "engine1", .stepD)
        ])
        
        let evaluator = AnyEquivalenceEvaluator<TestEvent>(identifier: "exact") { a, b in
            return a.typeIdentifier == b.typeIdentifier ? 1.0 : 0.0
        }
        
        let config = AlignmentConfiguration(profile: .strictAuditV1, equivalenceEvaluator: evaluator)
        let engine = TraceAlignmentEngine(configuration: config)
        let result = engine.align(base: baseRun, comparison: compRun)
        
        XCTAssertEqual(result.alignments.count, 4) // A (match), C (match), B (removed), D (added)
        
        let removed = result.alignments.first { $0.state.isRemoved }
        XCTAssertEqual(removed?.baseEvent?.payload.typeIdentifier, "stepB")
        
        let added = result.alignments.first { if case .added = $0.state { return true } else { return false } }
        XCTAssertEqual(added?.comparisonEvent?.payload.typeIdentifier, "stepD")
        
        XCTAssertEqual(result.engineVersion, "v2-causal-strict")
        XCTAssertFalse(result.profileHash.isEmpty)
    }
    
    func testAmbiguityBounding() {
        let runA = UUID()
        let runB = UUID()
        
        let baseRun = createMockRun(id: runA, seqEvents: [
            (0, "engine1", .custom("query"))
        ])
        
        let compRun = createMockRun(id: runB, seqEvents: [
            (0, "engine1", .custom("fetch1")),
            (1, "engine1", .custom("fetch2")),
            (2, "engine1", .custom("fetch3")),
            (3, "engine1", .custom("fetch4"))
        ])
        
        let evaluator = AnyEquivalenceEvaluator<TestEvent>(identifier: "mock_ambiguity", evaluator: { a, b in
            return 0.85 // All are moderately similar
        }, ambiguityThresholdFn: { _ in
            return 0.80
        })
        
        let profile = AlignmentProfile(
            strategy: .semanticExploration,
            version: 1,
            typeWeight: 0.0,
            payloadWeight: 1.0,
            structuralWeight: 0.0,
            temporalWeight: 0.0,
            semanticThreshold: 0.99,
            maxAmbiguousCandidates: 2, // Only allow top 2
            ambiguityDeltaThreshold: 0.05,
            alignmentMode: .linear
        )
        
        let config = AlignmentConfiguration(profile: profile, equivalenceEvaluator: evaluator)
        let engine = TraceAlignmentEngine(configuration: config)
        let result = engine.align(base: baseRun, comparison: compRun)
        
        let ambiguousMatches = result.alignments.filter {
            if case .ambiguous = $0.state { return true }
            return false
        }
        
        XCTAssertEqual(ambiguousMatches.count, 1)
        
        let match = ambiguousMatches[0]
        XCTAssertEqual(match.ambiguousCandidates.count, 2)
    }
    
    func testSnapshotDriftValidation() throws {
        let runA = UUID()
        let runB = UUID()
        
        let baseRun = createMockRun(id: runA, seqEvents: [
            (0, "engine1", .stepA)
        ])
        let compRun = createMockRun(id: runB, seqEvents: [
            (0, "engine1", .stepB)
        ])
        
        let evaluator = AnyEquivalenceEvaluator<TestEvent>(identifier: "exact") { a, b in
            return a.typeIdentifier == b.typeIdentifier ? 1.0 : 0.0
        }
        
        let config = AlignmentConfiguration(profile: .strictAuditV1, equivalenceEvaluator: evaluator)
        let engine = TraceAlignmentEngine(configuration: config)
        let result = engine.align(base: baseRun, comparison: compRun)
        
        let snapshot = AlignmentSnapshotValidator.createSnapshot(from: result)
        let validator = AlignmentSnapshotValidator(toleranceMode: .strict)
        
        XCTAssertNoThrow(try validator.validate(result: result, against: snapshot))
        
        // Mutate snapshot intentionally
        let badSnapshot = AlignmentSnapshot(profileHash: snapshot.profileHash, engineVersion: snapshot.engineVersion, outputAlignmentsHash: "bad_hash")
        XCTAssertThrowsError(try validator.validate(result: result, against: badSnapshot))
        
        let reportValidator = AlignmentSnapshotValidator(toleranceMode: .reportOnly)
        let valid = try reportValidator.validate(result: result, against: badSnapshot)
        XCTAssertFalse(valid)
    }
    
    func testFormalizationMapProducesCorrectCausalGraph() {
        let runA = UUID()
        let runB = UUID()
        
        let baseRun = createMockRun(id: runA, seqEvents: [
            (0, "engine1", .stepA),
            (1, "engine1", .stepB)
        ])
        let compRun = createMockRun(id: runB, seqEvents: [
            (0, "engine1", .stepA),
            (1, "engine1", .stepB)
        ])
        
        let evaluator = AnyEquivalenceEvaluator<TestEvent>(identifier: "exact") { a, b in
            return a.typeIdentifier == b.typeIdentifier ? 1.0 : 0.0
        }
        
        let config = AlignmentConfiguration(profile: .strictAuditV1, equivalenceEvaluator: evaluator)
        let engine = TraceAlignmentEngine(configuration: config, captureMode: .evidenceOnly)
        
        let result = engine.align(base: baseRun, comparison: compRun)
        
        XCTAssertNotNil(result.verificationArtifacts, "Verification artifacts should be produced when captureMode is .evidenceOnly")
        guard let evidence = result.verificationArtifacts?.evidence else { return }
        
        let builder = DefaultFormalizationMapBuilder()
        let map = builder.build(from: evidence)
        
        XCTAssertEqual(map.bindings.count, 2)
        XCTAssertEqual(map.decisions.count, 3)
        XCTAssertEqual(map.interpretations.count, 2)
        
        let auditor = ExplainabilityAuditor()
        let vector = auditor.audit(map)
        
        XCTAssertEqual(vector.coverage, 1.0)
        XCTAssertEqual(vector.completeness, 1.0)
        XCTAssertEqual(vector.causalOrdering, 1.0)
        XCTAssertEqual(vector.noHallucinations, 1.0)
    }
}
