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
            print("=== STANDARD DATASET ===")
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
            
            print("\n=== ADVERSARIAL DATASET ===")
            let advDataset = DProvenanceCorpus.adversarialDataset
            let advReport = await runner.run(dataset: advDataset) { cb in 
                // Explicitly harsher configuration for adversarial evaluation
                let advProfile = AlignmentProfile(
                    strategy: .developerDebug,
                    version: 2,
                    typeWeight: 0.4,
                    payloadWeight: 0.4,
                    structuralWeight: 0.15,
                    temporalWeight: 0.05,
                    semanticThreshold: 0.85, // Stricter equivalence bound
                    maxAmbiguousCandidates: 1, // Restrictive bipartite matching
                    ambiguityDeltaThreshold: 0.15,
                    alignmentMode: .spanAware
                )
                let config = AlignmentConfiguration<DProvenanceCorpus.AgentEvent>(
                    profile: advProfile,
                    equivalenceEvaluator: DProvenanceCorpus.standardEvaluator
                )
                return TraceAlignmentEngine(configuration: config, captureMode: .evidenceOnly, metaTraceCallback: cb)
            }
            print(String(format: "Dataset: %@  (%d cases, %d passed)", advReport.datasetName, advReport.totalCases, advReport.passedCases))
            print(String(format: "Precision: %.3f  Recall: %.3f  F1: %.3f", advReport.globalMetrics.precision, advReport.globalMetrics.recall, advReport.globalMetrics.f1Score))
            print(String(format: "Avg fidelity: %.3f  Avg runtime: %.2fms  p95: %.2fms", advReport.averageFidelityScore, advReport.averageRunTimeMs, advReport.p95RunTimeMs))
            for c in advReport.caseResults {
                print(String(format: "  [%@] %@  TP=%d FP=%d FN=%d  fidelity=%.2f",
                             c.passed ? "PASS" : "FAIL", c.benchmarkCase.name,
                             c.truePositives.count, c.falsePositives.count, c.falseNegatives.count,
                             c.fidelityScore.overallScore))
            }

            print("\n=== SUMMARY ===")
            let totalCases = report.totalCases + advReport.totalCases
            let totalPassed = report.passedCases + advReport.passedCases
            print(String(format: "Total Cases: %d", totalCases))
            print(String(format: "Total Passed: %d (%.1f%%)", totalPassed, Double(totalPassed) / Double(totalCases) * 100))

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
            // (1) Under the deterministic boundary the engine is reproducible: variance is 0.
            let isolated = DeterministicBoundary(cacheIsolated: true, seedControl: "cli_seed")
            let stable = await runner.runRepeatedEvaluation(dataset: dataset, iterations: 3, boundary: isolated) { _, cb in
                makeEngine(cb)
            }
            print(String(format: "Isolated   (cacheIsolated: true ): mean F1 %.3f  variance %.5f  — %@",
                         stable.meanF1, stable.f1Variance, stable.driftFingerprint))

            // (2) Control: an engine whose match threshold deterministically varies per iteration
            // produces findings that change across runs. This confirms the stability report is
            // load-bearing — it detects real variance rather than always reporting "stable".
            let unstable = await runner.runRepeatedEvaluation(dataset: dataset, iterations: 4, boundary: DeterministicBoundary(cacheIsolated: false)) { ctx, cb in
                let toolScore = (ctx.iteration % 2 == 0) ? 0.95 : 0.30
                let evaluator = AnyEquivalenceEvaluator<DProvenanceCorpus.AgentEvent>(identifier: "drift", evaluator: { b, c in
                    if b == c { return 1.0 }
                    guard b.typeIdentifier == c.typeIdentifier else { return 0.0 }
                    return b.typeIdentifier == "tool" ? toolScore : 0.8
                })
                let config = AlignmentConfiguration<DProvenanceCorpus.AgentEvent>(profile: .developerDebugV1, equivalenceEvaluator: evaluator)
                return TraceAlignmentEngine(configuration: config, captureMode: .evidenceOnly, metaTraceCallback: cb)
            }
            print(String(format: "Perturbed  (cacheIsolated: false): mean F1 %.3f  variance %.5f  — %@",
                         unstable.meanF1, unstable.f1Variance, unstable.driftFingerprint))

        default:
            break
        }
    }
}
