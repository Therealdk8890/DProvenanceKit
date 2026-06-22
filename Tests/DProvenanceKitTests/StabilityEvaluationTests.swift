import XCTest
@testable import DProvenanceKit

final class StabilityEvaluationTests: XCTestCase {

    typealias Event = DProvenanceCorpus.AgentEvent

    private func tool(_ name: String, seq: UInt64) -> TraceEvent<Event> {
        TraceEvent(runID: UUID(), contextID: "t", engineName: "Agent", schemaVersion: 1, sequence: seq, spanID: "s", parentSpanID: nil, payload: .toolExecution(toolName: name, params: ""), timestamp: Date())
    }

    private func singleCaseDataset() -> BenchmarkDataset<Event> {
        let bCase = BenchmarkCase(
            name: "tool-substitution",
            description: "",
            baseRun: TraceRun(runID: UUID(), contextID: "t", events: [tool("Search", seq: 0)]),
            comparisonRun: TraceRun(runID: UUID(), contextID: "t", events: [tool("Lookup", seq: 0)]),
            expectedFindings: [ExpectedFinding(finding: .semanticEvolution(baseIdentifier: "tool", compIdentifier: "tool"))]
        )
        return BenchmarkDataset(name: "stability", description: "", cases: [bCase])
    }

    // A deterministic engine, repeated, must show exactly zero F1 variance and report "Stable".
    func testDeterministicEngineHasZeroVariance() async {
        let runner = BenchmarkRunner<Event>()
        let boundary = DeterministicBoundary(cacheIsolated: true, seedControl: "fixed")
        let stability = await runner.runRepeatedEvaluation(dataset: singleCaseDataset(), iterations: 3, boundary: boundary) { _, cb in
            let evaluator = AnyEquivalenceEvaluator<Event>(identifier: "det", evaluator: { b, c in
                (b.typeIdentifier == "tool" && c.typeIdentifier == "tool") ? 0.95 : 0.0
            })
            let config = AlignmentConfiguration<Event>(profile: .developerDebugV1, equivalenceEvaluator: evaluator)
            return TraceAlignmentEngine(configuration: config, captureMode: .evidenceOnly, metaTraceCallback: cb)
        }
        XCTAssertEqual(stability.f1Variance, 0.0, accuracy: 1e-12)
        XCTAssertEqual(stability.driftFingerprint, "Stable: No significant drift")
    }

    // A non-deterministic engine (its match score flips by iteration) must produce F1 variance
    // that the stability report actually detects — i.e. the boundary/stability machinery is
    // load-bearing, not cosmetic.
    func testNonDeterministicEngineProducesDetectableVariance() async {
        let runner = BenchmarkRunner<Event>()
        let boundary = DeterministicBoundary(cacheIsolated: false, seedControl: nil)
        let stability = await runner.runRepeatedEvaluation(dataset: singleCaseDataset(), iterations: 3, boundary: boundary) { ctx, cb in
            // Even iterations: tool pairs match (finding emitted). Odd iterations: below threshold
            // (no finding). So findings — and F1 — differ across iterations.
            let matchScore = (ctx.iteration % 2 == 0) ? 0.95 : 0.30
            let evaluator = AnyEquivalenceEvaluator<Event>(identifier: "drifty", evaluator: { b, c in
                (b.typeIdentifier == "tool" && c.typeIdentifier == "tool") ? matchScore : 0.0
            })
            let config = AlignmentConfiguration<Event>(profile: .developerDebugV1, equivalenceEvaluator: evaluator)
            return TraceAlignmentEngine(configuration: config, captureMode: .evidenceOnly, metaTraceCallback: cb)
        }
        XCTAssertGreaterThan(stability.f1Variance, 0.0, "Stability report failed to detect real engine variance.")
        XCTAssertNotEqual(stability.driftFingerprint, "Stable: No significant drift")
    }

    // The perturbation layer is gated by the deterministic boundary: isolated => unchanged
    // (deterministic) evaluator; isolation lifted => a noise-wrapped evaluator.
    func testPerturbationIsGatedByBoundary() {
        let base = AnyEquivalenceEvaluator<Event>(identifier: "base", evaluator: { _, _ in 0.9 })
        let layer = EvaluationPerturbationLayer(mode: .scoreNoise(amplitude: 0.2))

        let isolated = layer.evaluator(wrapping: base, boundary: DeterministicBoundary(cacheIsolated: true))
        XCTAssertEqual(isolated.evaluatorIdentifier, "base", "Isolated boundary must pass the evaluator through unchanged.")

        let leaky = layer.evaluator(wrapping: base, boundary: DeterministicBoundary(cacheIsolated: false))
        XCTAssertEqual(leaky.evaluatorIdentifier, "base+noise", "Lifting isolation must wrap the evaluator with noise.")
    }
}
