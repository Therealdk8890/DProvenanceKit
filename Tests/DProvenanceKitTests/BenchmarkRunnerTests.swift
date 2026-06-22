import XCTest
@testable import DProvenanceKit

final class BenchmarkRunnerTests: XCTestCase {

    typealias Event = DProvenanceCorpus.AgentEvent

    /// Tuned evaluator, mirroring the standard demo configuration. `capture` controls whether
    /// the engine records verification evidence (required for fidelity scoring).
    private func makeFactory(capture: VerificationCaptureMode = .evidenceOnly) -> BenchmarkRunner<Event>.EngineFactory {
        return { @Sendable callback in
            let config = AlignmentConfiguration<Event>(
                profile: .developerDebugV1,
                equivalenceEvaluator: DProvenanceCorpus.standardEvaluator
            )
            return TraceAlignmentEngine(configuration: config, captureMode: capture, metaTraceCallback: callback)
        }
    }

    private func run(_ events: [TraceEvent<Event>], vs comp: [TraceEvent<Event>], expect: [ExpectedFinding], capture: VerificationCaptureMode = .evidenceOnly) async -> BenchmarkCaseResult<Event> {
        let runID = UUID()
        let bCase = BenchmarkCase(
            name: "adhoc",
            description: "",
            baseRun: TraceRun(runID: runID, contextID: "t", events: events),
            comparisonRun: TraceRun(runID: UUID(), contextID: "t", events: comp),
            expectedFindings: expect
        )
        let dataset = BenchmarkDataset(name: "t", description: "", cases: [bCase])
        let report = await BenchmarkRunner<Event>().run(dataset: dataset, engineFactory: makeFactory(capture: capture))
        return report.caseResults[0]
    }

    private func decision(_ action: String, seq: UInt64) -> TraceEvent<Event> {
        TraceEvent(runID: UUID(), contextID: "t", engineName: "Agent", schemaVersion: 1, sequence: seq, spanID: "s", parentSpanID: nil, payload: .decision(action: action), timestamp: Date())
    }
    private func file(_ name: String, seq: UInt64) -> TraceEvent<Event> {
        TraceEvent(runID: UUID(), contextID: "t", engineName: "Agent", schemaVersion: 1, sequence: seq, spanID: "s", parentSpanID: nil, payload: .fileIO(action: "read", file: name), timestamp: Date())
    }
    private func tool(_ name: String, seq: UInt64) -> TraceEvent<Event> {
        TraceEvent(runID: UUID(), contextID: "t", engineName: "Agent", schemaVersion: 1, sequence: seq, spanID: "s", parentSpanID: nil, payload: .toolExecution(toolName: name, params: ""), timestamp: Date())
    }

    // MARK: - Regression guard: the protocol must compute real, non-degenerate metrics.
    // This is the test that would have caught the "0% precision/recall" regression where
    // the extractor and corpus disagreed on the finding identifier scheme.
    func testStandardCorpusIsScoredAndNonDegenerate() async {
        let report = await BenchmarkRunner<Event>().run(dataset: DProvenanceCorpus.dataset, engineFactory: makeFactory())

        XCTAssertEqual(report.totalCases, 8)
        XCTAssertGreaterThan(report.globalMetrics.truePositives, 0, "Protocol produced zero true positives — finding identity is broken.")
        // The standard corpus is fully consistent with the engine's semantics: every case passes.
        XCTAssertEqual(report.passedCases, report.totalCases, "Every standard-corpus case should pass.")
        XCTAssertEqual(report.globalMetrics.precision, 1.0, accuracy: 1e-9)
        XCTAssertEqual(report.globalMetrics.recall, 1.0, accuracy: 1e-9)
        XCTAssertGreaterThan(report.averageFidelityScore, 0.0)
    }

    // The diagnoser must classify every false-positive type, not just semanticEvolution. Running
    // the reordering traces with NO expected findings forces the genuine reorders to register as
    // false positives, which the diagnoser should attribute (with evidence) rather than shrug off.
    func testDiagnoserClassifiesReorderFalsePositives() async {
        let bCase = BenchmarkCase(
            name: "reorder-fp",
            description: "",
            baseRun: DProvenanceCorpus.reordering.base,
            comparisonRun: DProvenanceCorpus.reordering.comparison,
            expectedFindings: []
        )
        let report = await BenchmarkRunner<Event>().run(dataset: BenchmarkDataset(name: "t", description: "", cases: [bCase]), engineFactory: makeFactory())
        let result = report.caseResults[0]
        XCTAssertFalse(result.falsePositives.isEmpty)
        let reorderDiag = result.diagnoses.first { if case .reorderedExecution = $0.finding { return true }; return false }
        XCTAssertNotNil(reorderDiag, "Expected a diagnosis for the reordered false positive.")
        XCTAssertNotEqual(reorderDiag?.hypothesizedCause, .undiagnosed, "Reorder FP should be attributed to a cause, with evidence.")
    }

    // The unambiguously-correct cases must pass: a tool->tool substitution and a
    // decision->decision drift are semantic matches; empty-vs-empty is a clean true negative.
    func testWellDefinedCasesPass() async {
        let report = await BenchmarkRunner<Event>().run(dataset: DProvenanceCorpus.dataset, engineFactory: makeFactory())
        let byName = Dictionary(uniqueKeysWithValues: report.caseResults.map { ($0.benchmarkCase.name, $0) })
        XCTAssertEqual(byName["Semantic Evolution"]?.passed, true)
        XCTAssertEqual(byName["Semantic Drift"]?.passed, true)
        XCTAssertEqual(byName["Degenerate Traces"]?.passed, true)
    }

    // MARK: - Fidelity must be wired to evidence capture.
    func testFidelityRequiresEvidenceCapture() async {
        // A tool->tool substitution produces a semanticEvolution finding (non-empty output).
        let base = [tool("Search", seq: 0)]
        let comp = [tool("Lookup", seq: 0)]

        let evid = await run(base, vs: comp, expect: [], capture: .evidenceOnly)
        let noEvid = await run(base, vs: comp, expect: [], capture: .disabled)

        XCTAssertFalse(evid.actualFindings.isEmpty, "Expected the substitution to yield a finding.")
        XCTAssertGreaterThan(evid.fidelityScore.overallScore, 0.0, "Evidence captured => fidelity computed.")
        XCTAssertEqual(noEvid.fidelityScore.overallScore, 0.0, "No evidence capture => fidelity unverifiable (0).")
    }

    // MARK: - Multiset matching consumes duplicates (no double-credit, no double-blame).
    func testMultisetMatchingConsumesDuplicates() async {
        // Two critical decisions removed -> engine emits two criticalStepRemoved("decision").
        let base = [decision("ValidateA", seq: 0), decision("ValidateB", seq: 1)]
        let comp: [TraceEvent<Event>] = []

        // Expecting both: both matched as TP, none left as FP for that finding.
        let two = await run(base, vs: comp, expect: [
            ExpectedFinding(finding: .criticalStepRemoved(baseEventIdentifier: "decision")),
            ExpectedFinding(finding: .criticalStepRemoved(baseEventIdentifier: "decision"))
        ])
        XCTAssertEqual(two.truePositives.filter { if case .criticalStepRemoved = $0 { return true }; return false }.count, 2)

        // Expecting only one: exactly one matched, the duplicate becomes a false positive.
        let one = await run(base, vs: comp, expect: [
            ExpectedFinding(finding: .criticalStepRemoved(baseEventIdentifier: "decision"))
        ])
        XCTAssertEqual(one.truePositives.filter { if case .criticalStepRemoved = $0 { return true }; return false }.count, 1)
        XCTAssertTrue(one.falsePositives.contains { if case .criticalStepRemoved = $0 { return true }; return false })
    }

    // MARK: - Empty output with a missed expectation must NOT score perfect fidelity.
    func testEmptyFindingsWithMissedExpectationScoresZero() async {
        // Empty traces -> engine produces no findings, but we expected one => false negative.
        let result = await run([], vs: [], expect: [
            ExpectedFinding(finding: .criticalStepRemoved(baseEventIdentifier: "decision"))
        ])
        XCTAssertTrue(result.actualFindings.isEmpty)
        XCTAssertFalse(result.falseNegatives.isEmpty)
        XCTAssertEqual(result.fidelityScore.overallScore, 0.0, "Empty explanation that missed an expected finding is not faithful.")
    }
}
