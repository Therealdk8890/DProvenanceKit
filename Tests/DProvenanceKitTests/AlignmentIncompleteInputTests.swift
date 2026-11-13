import XCTest
@testable import DProvenanceKit

final class AlignmentIncompleteInputTests: XCTestCase {
    private struct Step: TraceableEvent {
        let typeIdentifier: String
        var priority: TracePriority { .critical }
    }

    func testIncompleteTypedViewsNeverReceiveACleanVerdict() {
        let configuration = AlignmentConfiguration<Step>(profile: .strictAuditV1,
            equivalenceEvaluator: AnyEquivalenceEvaluator(identifier: "equality") { $0 == $1 ? 1 : 0 })
        let engine = TraceAlignmentEngine(configuration: configuration)
        for counts in [(1, 0), (0, 1), (2, 3)] {
            let base = TraceRun<Step>(runID: UUID(), contextID: "case", events: [],
                                      undecodedEventCount: counts.0)
            let candidate = TraceRun<Step>(runID: UUID(), contextID: "case", events: [],
                                           undecodedEventCount: counts.1)
            let result = engine.align(base: base, comparison: candidate)
            XCTAssertFalse(result.isReliable)
            XCTAssertEqual(result.inputCompleteness,
                .incomplete(baseUndecodedEvents: counts.0, comparisonUndecodedEvents: counts.1))
            XCTAssertEqual(result.regressionRisk.level, .high)
            XCTAssertTrue(result.regressionRisk.reasoning.contains("indeterminate"))
        }
    }

    func testCompleteInputsPreserveLegacyVerdict() {
        let configuration = AlignmentConfiguration<Step>(profile: .strictAuditV1,
            equivalenceEvaluator: AnyEquivalenceEvaluator(identifier: "equality") { $0 == $1 ? 1 : 0 })
        let run = TraceRun<Step>(runID: UUID(), contextID: "case", events: [])
        let result = TraceAlignmentEngine(configuration: configuration).align(base: run, comparison: run)
        XCTAssertTrue(result.isReliable)
        XCTAssertEqual(result.inputCompleteness, .complete)
        XCTAssertEqual(result.regressionRisk.level, .none)
    }
}
