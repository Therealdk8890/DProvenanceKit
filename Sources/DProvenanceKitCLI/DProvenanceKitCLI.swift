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
        let args = Array(CommandLine.arguments.dropFirst())

        if args.contains("--help") || args.contains("-h") {
            // Help must not silently swallow a requested action: a stray --help in a
            // CI line like `evaluate --gate --help` would otherwise exit 0 without
            // ever running the gate. Standalone help (optionally with a mode) is fine.
            let others = args.filter { $0.hasPrefix("-") && $0 != "--help" && $0 != "-h" }
            guard others.isEmpty else {
                printErr("Error: --help cannot be combined with other flags (\(others.joined(separator: " "))).")
                exit(2)
            }
            printUsage()
            return
        }

        // Fail-closed argument handling: anything unknown, malformed, duplicated, or
        // out of range exits 2 before any work runs. Silently ignoring a broken
        // `--trusted-key` or `--min-f1` would downgrade a security check while still
        // reporting success — the exact failure mode this CLI exists to catch.
        let invocation: CLIInvocation
        do {
            invocation = try CLIArguments.parse(args)
        } catch let error as CLIArgumentError {
            printErr("Error: \(error.description)")
            printErr("Run with --help for usage.")
            exit(2)
        } catch {
            printErr("Error: \(error)")
            exit(2)
        }

        // web-export emits pure JSON to stdout (pipeable) — keep the human header off it.
        if invocation.mode == .webExport {
            runWebExport(caseName: invocation.caseName, outPath: invocation.outPath)
            return
        }
        if invocation.mode == .attestDemo {
            runAttestDemo(outPath: invocation.outPath)
            return
        }
        if invocation.mode == .verify {
            runVerify(inPath: invocation.inPath!, trustedKeyIDs: invocation.trustedKeyIDs)
            return
        }

        print("DProvenanceKit CLI Evaluator")
        print("============================")

        let gate = invocation.gate
        let minF1 = invocation.minF1

        let runner = BenchmarkRunner<DProvenanceCorpus.AgentEvent>()
        let dataset = DProvenanceCorpus.dataset

        switch invocation.mode {
        case .evaluate:
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

            if gate {
                enforceGate(totalPassed: totalPassed, totalCases: totalCases,
                            f1: report.globalMetrics.f1Score,
                            adversarialF1: advReport.globalMetrics.f1Score,
                            minF1: minF1)
            }

        case .diagnose:
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

        case .stability:
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

    // MARK: - CI gating & help

    /// Exits non-zero when the corpus regresses, so `evaluate --gate` can fail a CI
    /// job. Without this the evaluator always exited 0, so a dropped reasoning step
    /// could never break the build — the exact use case DPK is pitched for.
    static func enforceGate(totalPassed: Int, totalCases: Int, f1: Double, adversarialF1: Double, minF1: Double?) {
        var failures: [String] = []
        if totalPassed < totalCases {
            failures.append("\(totalCases - totalPassed) of \(totalCases) case(s) failed")
        }
        if let minF1 {
            if f1 < minF1 { failures.append(String(format: "standard F1 %.3f < baseline %.3f", f1, minF1)) }
            if adversarialF1 < minF1 { failures.append(String(format: "adversarial F1 %.3f < baseline %.3f", adversarialF1, minF1)) }
        }
        if failures.isEmpty {
            print("\n✅ Gate passed.")
        } else {
            printErr("\n❌ Gate failed: " + failures.joined(separator: "; "))
            exit(1)
        }
    }

    // MARK: - web-export

    /// Emits a `WebDiffExport` JSON for one corpus case — the exact shape the bundled
    /// WebVisualizer consumes (`WebVisualizer/SCHEMA.md`). Pure JSON to stdout so it can be
    /// redirected straight into the viewer; `--out=<path>` writes a file instead.
    static func runWebExport(caseName: String?, outPath: String?) {
        let cases = DProvenanceCorpus.dataset.cases
        guard let bench = caseName.flatMap({ name in cases.first { $0.name == name } }) ?? cases.first else {
            printErr("No corpus cases available to export.")
            exit(2)
        }
        if let caseName, bench.name != caseName {
            // Exporting a different case than the one asked for would be a silent
            // substitution; a pipeline consuming this JSON must not get the wrong run.
            printErr("Case '\(caseName)' not found; available: \(cases.map(\.name).joined(separator: ", ")).")
            exit(2)
        }

        let config = AlignmentConfiguration<DProvenanceCorpus.AgentEvent>(
            profile: .developerDebugV1,
            equivalenceEvaluator: DProvenanceCorpus.standardEvaluator
        )
        let export = WebDiffExport.make(
            base: bench.baseRun,
            comparison: bench.comparisonRun,
            configuration: config,
            baseLabel: "Baseline",
            comparisonLabel: "Candidate",
            rootLabel: bench.name
        )

        do {
            let data = try export.jsonData()
            if let outPath {
                try data.write(to: URL(fileURLWithPath: outPath))
                printErr("Wrote \(data.count) bytes to \(outPath)  (case: \(bench.name))")
            } else {
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            }
        } catch {
            printErr("web-export failed: \(error)")
            exit(1)
        }
    }

    // MARK: - attestation

    /// Produces a self-contained signed trace using the bundled corpus. This keeps private key
    /// material out of the artifact and gives users a safe document to exercise with `verify`.
    static func runAttestDemo(outPath: String?) {
        let run = DProvenanceCorpus.codingAgentRegression.base
        let key = SoftwareTraceAttestationKey()

        do {
            let document = try TraceAttestationDocument.signed(run: run, using: key)
            let data = try document.jsonData()
            if let out = outPath {
                try data.write(to: URL(fileURLWithPath: out), options: .atomic)
                printErr("Wrote signed trace to \(out)")
            } else {
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            }
            printErr("Signer key ID: \(document.attestation.keyID)")
            printErr("Pin that key ID during verification when signer identity matters.")
        } catch {
            printErr("attest-demo failed: \(error)")
            exit(1)
        }
    }

    /// Verifies the trace digest and P-256 signature in an attestation document. Without at
    /// least one `--trusted-key`, this proves integrity only; it does not establish who signed.
    /// Key IDs arrive pre-validated by `CLIArguments` — an empty or malformed key has already
    /// exited 2, so an empty set here can only mean the flag was never passed.
    static func runVerify(inPath: String, trustedKeyIDs: Set<String>) {
        let trustSet: Set<String>? = trustedKeyIDs.isEmpty ? nil : trustedKeyIDs

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: inPath))
            let document = try TraceAttestationDocument.decodeJSON(data)
            let result = document.verify(trustedKeyIDs: trustSet)
            guard result.isValid else {
                printErr("INVALID: \(result.failure?.rawValue ?? "unknown failure")")
                printErr("Key ID: \(result.keyID)")
                exit(1)
            }

            print("VALID")
            print("Run ID: \(document.trace.runID.uuidString.lowercased())")
            print("Events: \(document.trace.events.count)  Edges: \(document.trace.edges.count)")
            print("Digest: \(document.attestation.traceDigest)")
            print("Key ID: \(result.keyID)")
            switch result.trust {
            case .embeddedKeyOnly:
                print("Trust: signature valid; signer identity not pinned")
            case .trustedKey:
                print("Trust: signature valid; signer key pinned")
            }
        } catch {
            printErr("verify failed: \(error)")
            exit(1)
        }
    }

    static func printUsage() {
        print("""
        DProvenanceKit CLI Evaluator

        Usage: DProvenanceKitCLI <mode> [flags]

        Modes:
          evaluate    Run the standard + adversarial corpus and print metrics (default)
          diagnose    Rank the most systemically impactful failure modes
          stability   Report evaluation variance across repeated runs
          web-export  Emit WebVisualizer JSON for one corpus case (pure JSON to stdout)
          attest-demo Write a signed trace document from the bundled corpus
          verify      Verify a signed trace document offline

        Flags:
          --gate            Exit non-zero if any case fails — for CI regression gating
          --min-f1=<value>  With --gate, also require F1 >= <value> on both datasets
          --case=<name>     web-export: which corpus case to export (default: first)
          --out=<path>      web-export: write JSON to a file instead of stdout
          --in=<path>       verify: attestation document to verify
          --trusted-key=<id> verify: require this signer key ID (64 hex chars, repeatable)
          -h, --help        Show this help

        Unknown, malformed, duplicated, or out-of-range arguments exit 2 — they are
        never ignored, so a typo cannot silently weaken a verification or a CI gate.
        """)
    }

    static func printErr(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
