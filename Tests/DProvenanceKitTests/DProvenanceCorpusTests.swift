import XCTest
@testable import DProvenanceKit

final class DProvenanceCorpusTests: XCTestCase {
    
    // A simple evaluator for corpus events
    var engine: TraceAlignmentEngine<DProvenanceCorpus.AgentEvent>!
    
    override func setUp() {
        super.setUp()
        
        let evaluator = AnyEquivalenceEvaluator<DProvenanceCorpus.AgentEvent>(
            identifier: "corpus_evaluator",
            evaluator: { base, comparison in
                switch (base, comparison) {
                case (.fileIO(let aAct, let aFile), .fileIO(let bAct, let bFile)):
                    return (aAct == bAct && aFile == bFile) ? 1.0 : 0.0
                case (.toolExecution(let aName, let aParams), .toolExecution(let bName, let bParams)):
                    if aName == bName && aParams == bParams { return 1.0 }
                    // Semantic Evolution Check
                    if (aName == "SearchDocumentation" && bName == "LookupAPIDocs") ||
                       (aName == "LookupAPIDocs" && bName == "SearchDocumentation") {
                        if aParams == bParams { return 0.95 }
                    }
                    return 0.0
                case (.planning(let aHypo), .planning(let bHypo)):
                    return aHypo == bHypo ? 1.0 : 0.0
                case (.decision(let aAct), .decision(let bAct)):
                    return aAct == bAct ? 1.0 : 0.0
                default:
                    return 0.0
                }
            },
            ambiguityThresholdFn: { _ in 0.8 }
        )
        
        let config = AlignmentConfiguration(profile: .developerDebugV1, equivalenceEvaluator: evaluator)
        self.engine = TraceAlignmentEngine(configuration: config)
    }
    
    func testCodingAgentRegression() {
        let (base, comp) = DProvenanceCorpus.codingAgentRegression
        let result = engine.align(base: base, comparison: comp)
        
        // Baseline has 5 events, Comp has 2 events.
        // Matched: fileIO "read App.swift" and the decision "GenerateFix" (both present in comp).
        // Removed: SearchDocs and VerifyFix (tools, structural) and ValidateAPI (a critical
        // decision). Removing the critical decision raises regression risk to high.
        XCTAssertEqual(result.alignments.count, 5) // 2 matches, 3 removed.
        let removed = result.alignments.filter { $0.state.isRemoved }
        XCTAssertEqual(removed.count, 3)
        XCTAssertEqual(result.regressionRisk.level, .high, "Removing the critical ValidateAPI decision should raise regression risk.")
    }
    
    func testSemanticEvolution() {
        let (base, comp) = DProvenanceCorpus.semanticEvolution
        let result = engine.align(base: base, comparison: comp)
        
        // Baseline: SearchDocumentation -> Comp: LookupAPIDocs
        // They should match semantically at 0.95, giving a high score.
        let match = result.alignments.first
        XCTAssertNotNil(match)
        if case .semanticMatch(let strength) = match?.state {
            XCTAssertGreaterThan(strength, 0.9)
        } else {
            XCTFail("Expected semantic match, got: \(String(describing: match?.state))")
        }
    }
    
    func testReordering() {
        let (base, comp) = DProvenanceCorpus.reordering
        let result = engine.align(base: base, comparison: comp)
        
        // Reordering
        let reordered = result.alignments.filter {
            if case .reordered = $0.state { return true }
            return false
        }
        
        // Because they swapped places, both should technically be marked as reordered.
        XCTAssertEqual(reordered.count, 2)
    }
    
    func testBranchCollapse() {
        let (base, comp) = DProvenanceCorpus.branchCollapse
        let result = engine.align(base: base, comparison: comp, minimumPriority: .diagnostic)
        
        // Investigated A, B, C. Comp did A, C.
        // So B is removed. A and C match.
        let removed = result.alignments.filter { $0.state.isRemoved }
        XCTAssertEqual(removed.count, 1)
        XCTAssertEqual(removed.first?.baseEvent?.payload.typeIdentifier, "planning")
    }
}
