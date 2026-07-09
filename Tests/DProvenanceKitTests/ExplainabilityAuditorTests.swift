import XCTest
@testable import DProvenanceKit

final class ExplainabilityAuditorTests: XCTestCase {

    private let auditor = ExplainabilityAuditor()

    // Builders
    private func step(base: String?, comp: String?, state: String, bseq: UInt64? = nil, cseq: UInt64? = nil) -> InterpretationStep {
        InterpretationStep(sourceBinding: nil, baseID: base, comparisonID: comp, outputState: state, rationale: "", baseSequence: bseq, comparisonSequence: cseq)
    }
    private func binding(_ base: String, _ comp: String) -> BindingDecision {
        BindingDecision(baseID: base, comparisonID: comp, similarityScore: 1.0)
    }
    private func decision(_ base: String, _ comp: String, equivalent: Bool) -> EquivalenceDecisionRecord {
        EquivalenceDecisionRecord(lhs: base, rhs: comp, confidence: equivalent ? 0.95 : 0.2, equivalent: equivalent, reason: EquivalenceReason(description: ""))
    }

    func testEmptyMapIsPerfect() {
        let v = auditor.audit(FormalizationMap(bindings: [], decisions: [], interpretations: []))
        XCTAssertEqual(v.coverage, 1.0)
        XCTAssertEqual(v.completeness, 1.0)
        XCTAssertEqual(v.causalOrdering, 1.0)
        XCTAssertEqual(v.noHallucinations, 1.0)
    }

    // A match fully grounded in evidence (binding + equivalent decision) scores perfectly.
    func testFullyGroundedMatchIsPerfect() {
        let map = FormalizationMap(
            bindings: [binding("b", "c")],
            decisions: [decision("b", "c", equivalent: true)],
            interpretations: [step(base: "b", comp: "c", state: "semanticMatch(strength: 0.9)", bseq: 0, cseq: 0)]
        )
        let v = auditor.audit(map)
        XCTAssertEqual(v.coverage, 1.0)
        XCTAssertEqual(v.completeness, 1.0)
        XCTAssertEqual(v.causalOrdering, 1.0)
        XCTAssertEqual(v.noHallucinations, 1.0)
    }

    // A reported match with no backing binding is ungrounded → coverage drops, the rest hold.
    func testUngroundedMatchHurtsCoverageOnly() {
        let map = FormalizationMap(
            bindings: [],
            decisions: [decision("b", "c", equivalent: true)],
            interpretations: [step(base: "b", comp: "c", state: "semanticMatch(strength: 0.9)", bseq: 0, cseq: 0)]
        )
        let v = auditor.audit(map)
        XCTAssertEqual(v.coverage, 0.0)
        XCTAssertEqual(v.completeness, 1.0)
        XCTAssertEqual(v.noHallucinations, 1.0)
    }

    // A reported match the semantics layer never evaluated → completeness drops.
    func testUnevaluatedMatchHurtsCompleteness() {
        let map = FormalizationMap(
            bindings: [binding("b", "c")],
            decisions: [],
            interpretations: [step(base: "b", comp: "c", state: "semanticMatch(strength: 0.9)", bseq: 0, cseq: 0)]
        )
        let v = auditor.audit(map)
        XCTAssertEqual(v.coverage, 1.0)
        XCTAssertEqual(v.completeness, 0.0)
    }

    // A definitive match whose own equivalence decision says NOT equivalent is a hallucination,
    // even though it is covered and complete.
    func testUnsupportedClaimIsHallucination() {
        let map = FormalizationMap(
            bindings: [binding("b", "c")],
            decisions: [decision("b", "c", equivalent: false)],
            interpretations: [step(base: "b", comp: "c", state: "semanticMatch(strength: 0.5)", bseq: 0, cseq: 0)]
        )
        let v = auditor.audit(map)
        XCTAssertEqual(v.coverage, 1.0)
        XCTAssertEqual(v.completeness, 1.0)
        XCTAssertEqual(v.noHallucinations, 0.0)
    }

    // Ambiguity is an honest verdict, not a claim of equivalence → not a hallucination.
    func testAmbiguousVerdictIsNotHallucination() {
        let map = FormalizationMap(
            bindings: [binding("b", "c")],
            decisions: [decision("b", "c", equivalent: false)],
            interpretations: [step(base: "b", comp: "c", state: "ambiguous(optionsCount: 2)", bseq: 0, cseq: 0)]
        )
        XCTAssertEqual(auditor.audit(map).noHallucinations, 1.0)
    }

    func testPairMatchingDoesNotCollideWhenIDsContainSeparator() {
        let separator = "\u{1}"
        let reportedBase = "a\(separator)b"
        let reportedComparison = "c"
        let differentBase = "a"
        let differentComparison = "b\(separator)c"
        let map = FormalizationMap(
            bindings: [binding(differentBase, differentComparison)],
            decisions: [decision(differentBase, differentComparison, equivalent: true)],
            interpretations: [
                step(base: reportedBase, comp: reportedComparison, state: "semanticMatch(strength: 0.9)", bseq: 0, cseq: 0)
            ]
        )

        let v = auditor.audit(map)
        XCTAssertEqual(v.coverage, 0.0)
        XCTAssertEqual(v.completeness, 0.0)
        XCTAssertEqual(v.noHallucinations, 0.0)
    }

    // Order-preserving alignment is faithful.
    func testOrderPreservingAlignmentIsFaithful() {
        let map = FormalizationMap(
            bindings: [binding("a", "x"), binding("b", "y")],
            decisions: [decision("a", "x", equivalent: true), decision("b", "y", equivalent: true)],
            interpretations: [
                step(base: "a", comp: "x", state: "semanticMatch(strength: 0.9)", bseq: 0, cseq: 0),
                step(base: "b", comp: "y", state: "semanticMatch(strength: 0.9)", bseq: 1, cseq: 1)
            ]
        )
        XCTAssertEqual(auditor.audit(map).causalOrdering, 1.0)
    }

    // An inversion the engine silently labels a plain match (not "reordered") is unfaithful.
    func testUnreportedReorderHurtsOrdering() {
        let map = FormalizationMap(
            bindings: [binding("a", "y"), binding("b", "x")],
            decisions: [decision("a", "y", equivalent: true), decision("b", "x", equivalent: true)],
            interpretations: [
                step(base: "a", comp: "y", state: "semanticMatch(strength: 0.9)", bseq: 0, cseq: 1),
                step(base: "b", comp: "x", state: "semanticMatch(strength: 0.9)", bseq: 1, cseq: 0)
            ]
        )
        XCTAssertEqual(auditor.audit(map).causalOrdering, 0.0)
    }

    // The same inversion, correctly reported as "reordered", is faithful (NOT penalized).
    func testReportedReorderIsFaithful() {
        let map = FormalizationMap(
            bindings: [binding("a", "y"), binding("b", "x")],
            decisions: [decision("a", "y", equivalent: true), decision("b", "x", equivalent: true)],
            interpretations: [
                step(base: "a", comp: "y", state: "reordered(originalSequence: 0, newSequence: 1)", bseq: 0, cseq: 1),
                step(base: "b", comp: "x", state: "reordered(originalSequence: 1, newSequence: 0)", bseq: 1, cseq: 0)
            ]
        )
        XCTAssertEqual(auditor.audit(map).causalOrdering, 1.0)
    }
}
