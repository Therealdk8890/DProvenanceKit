import Foundation
import DProvenanceKit

/// Headless evaluator: runs the standard DProvenance corpus through the real BenchmarkRunner
/// and prints actual metrics. This is the CI-runnable entry point.
@main
struct DProvenanceKitCLI {

    /// Tuned evaluator + evidence capture, matching the demo/benchmark configuration.
    static func makeEngine(
        _ callback: @escaping @Sendable (TraceEvent<AlignmentMetaEvent>) -> Void
    ) -> TraceAlignmentEngine<DProvenanceCorpus.AgentEvent> {
        let config = AlignmentConfiguration<DProvenanceCorpus.AgentEvent>(
            profile: .developerDebugV1,
            equivalenceEvaluator: DProvenanceCorpus.standardEvaluator
        )
        return TraceAlignmentEngine(configuration: config, captureMode: .evidenceOnly, metaTraceCallback: callback)
    }

    static func main() async {
        print("DProvenanceKit CLI Evaluator")
        print("============================")

        let args = CommandLine.arguments
        let mode = args.count >= 2 ? args[1] : "evaluate"
        guard ["evaluate", "diagnose", "stability"].contains(mode) else {
            print("Usage: DProvenanceKitCLI <evaluate|diagnose|stability>")
            return
        }

        let runner = BenchmarkRunner<DProvenanceCorpus.AgentEvent>()
        let dataset = DProvenanceCorpus.dataset

        switch mode {
        case "evaluate":
            let report = await runner.run(dataset: dataset) { cb in makeEngine(cb) }
            print(String(format: "Dataset: %@  (%d cases, %d passed)", report.datasetName, report.totalCases, report.passedCases))
            print(String(format: "Precision: %.3f  Recall: %.3f  F1: %.3f", report.globalMetrics.precision, report.globalMetrics.recall, report.globalMetrics.f1Score))
            print(String(format: "Avg fidelity: %.3f  Avg runtime: %.2fms  p95: %.2fms", report.averageFidelityScore, report.averageRunTimeMs, report.p95RunTimeMs))
            for c in report.caseResults {
                print(String(format: "  [%@] %@  TP=%d FP=%d FN=%d  fidelity=%.2f",
                             c.passed ? "PASS" : "FAIL", c.benchmarkCase.name,
                             c.truePositives.count, c.falsePositives.count, c.falseNegatives.count,
                             c.fidelityScore.overallScore))
            }

        case "diagnose":
            let report = await runner.run(dataset: dataset) { cb in makeEngine(cb) }
            print("Causal ranking (most systemically impactful failure modes first):")
            let ranking = report.causalRanking
            if ranking.isEmpty {
                print("  (no diagnosed failures)")
            }
            for rank in ranking {
                print(String(format: "  %@  freq=%d  impact=%.1f%%  z=%.2f  conf=%.2f",
                             rank.cause.label, rank.frequency,
                             rank.fractionalImpact * 100, rank.zScoreImpact, rank.averageConfidence))
            }

        case "stability":
            let boundary = DeterministicBoundary(cacheIsolated: true, seedControl: "cli_seed")
            let stability = await runner.runRepeatedEvaluation(dataset: dataset, iterations: 3, boundary: boundary) { _, cb in
                makeEngine(cb)
            }
            print(String(format: "Iterations: %d  cacheIsolated: %@  seed: %@",
                         stability.iterations, boundary.cacheIsolated ? "yes" : "no", boundary.seedControl ?? "none"))
            print(String(format: "Mean F1: %.3f  F1 variance: %.5f", stability.meanF1, stability.f1Variance))
            print("Drift: \(stability.driftFingerprint)")

        default:
            break
        }
    }
}
