import XCTest
@testable import DProvenanceKit

final class ExplainabilityAuditorTests: XCTestCase {
    
    func testEmptyMapReturnsPerfectScore() {
        let auditor = ExplainabilityAuditor()
        let map = FormalizationMap(bindings: [], decisions: [], interpretations: [])
        let score = auditor.audit(map)
        XCTAssertEqual(score.coverage, 1.0)
        XCTAssertEqual(score.completeness, 1.0)
        XCTAssertEqual(score.causalOrdering, 1.0)
        XCTAssertEqual(score.noHallucinations, 1.0)
    }
    
    func testValidInterpretation() {
        let auditor = ExplainabilityAuditor()
        let step = InterpretationStep(sourceBinding: nil, baseID: "10", comparisonID: "20", outputState: "semanticMatch", rationale: "")
        let map = FormalizationMap(bindings: [], decisions: [], interpretations: [step])
        
        let score = auditor.audit(map)
        
        XCTAssertEqual(score.coverage, 1.0)
        XCTAssertEqual(score.completeness, 1.0)
        XCTAssertEqual(score.causalOrdering, 1.0)
        XCTAssertEqual(score.noHallucinations, 1.0)
    }
    
    func testHallucination() {
        let auditor = ExplainabilityAuditor()
        let step = InterpretationStep(sourceBinding: nil, baseID: nil, comparisonID: "20", outputState: "added", rationale: "")
        let map = FormalizationMap(bindings: [], decisions: [], interpretations: [step])

        let score = auditor.audit(map)

        XCTAssertEqual(score.coverage, 1.0)
        XCTAssertEqual(score.completeness, 0.0)
        XCTAssertEqual(score.causalOrdering, 1.0)
        XCTAssertEqual(score.noHallucinations, 0.0) // Hallucination present
    }

    // Two aligned pairs that preserve execution order score a perfect causal-ordering invariant.
    func testCausalOrderingRewardsOrderPreservingAlignment() {
        let auditor = ExplainabilityAuditor()
        let steps = [
            InterpretationStep(sourceBinding: nil, baseID: "a", comparisonID: "x", outputState: "semanticMatch", rationale: "", baseSequence: 0, comparisonSequence: 0),
            InterpretationStep(sourceBinding: nil, baseID: "b", comparisonID: "y", outputState: "semanticMatch", rationale: "", baseSequence: 1, comparisonSequence: 1)
        ]
        let map = FormalizationMap(bindings: [], decisions: [], interpretations: steps)
        XCTAssertEqual(auditor.audit(map).causalOrdering, 1.0)
    }

    // Two aligned pairs whose comparison order is inverted relative to the base score 0.0.
    func testCausalOrderingPenalizesInvertedAlignment() {
        let auditor = ExplainabilityAuditor()
        let steps = [
            InterpretationStep(sourceBinding: nil, baseID: "a", comparisonID: "y", outputState: "semanticMatch", rationale: "", baseSequence: 0, comparisonSequence: 1),
            InterpretationStep(sourceBinding: nil, baseID: "b", comparisonID: "x", outputState: "semanticMatch", rationale: "", baseSequence: 1, comparisonSequence: 0)
        ]
        let map = FormalizationMap(bindings: [], decisions: [], interpretations: steps)
        XCTAssertEqual(auditor.audit(map).causalOrdering, 0.0)
    }
}
