import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
import DProvenanceKit
import DProvenanceUI

@main
struct GenerateSampleApp: App {
    @StateObject private var storeManager = StoreManager()

    init() {
        #if canImport(AppKit)
        // A bare SwiftPM executable otherwise launches as a background accessory. Promote the
        // demo so its window, Dock icon, and menu bar are visible when run from the command line.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            InvestigationDemoView()
                .environmentObject(storeManager)
        }
    }
}

struct InvestigationDemoView: View {
    @State private var selectedTab = 2 // Default to Explorer
    @StateObject private var replayViewModel = AlignmentReplayViewModel()
    @State private var isAnalyzing = false
    
    @State private var benchmarkDeltaReport: BenchmarkDeltaReport<DProvenanceCorpus.AgentEvent>? = nil
    @State private var benchmarkStabilityReport: BenchmarkStabilityReport<DProvenanceCorpus.AgentEvent>? = nil
    
    let baseRun = DProvenanceCorpus.semanticEvolution.base
    let compRun = DProvenanceCorpus.semanticEvolution.comparison
    
    // We create a persistent engine that outputs meta-traces for the demo tabs
    var engine: TraceAlignmentEngine<DProvenanceCorpus.AgentEvent> {
        let callback: @Sendable (TraceEvent<AlignmentMetaEvent>) -> Void = { [weak replayViewModel] event in
            DispatchQueue.main.async {
                replayViewModel?.ingest(event)
            }
        }
        return createEngine(callback: callback)
    }
    
    func createEngine(callback: @escaping @Sendable (TraceEvent<AlignmentMetaEvent>) -> Void) -> TraceAlignmentEngine<DProvenanceCorpus.AgentEvent> {
        let profile = AlignmentProfile.developerDebugV1
        let evaluator = AnyEquivalenceEvaluator<DProvenanceCorpus.AgentEvent>(
            identifier: "tool_semantics",
            evaluator: { b, c in
                if b.typeIdentifier == "tool" && c.typeIdentifier == "tool" {
                    return 0.95
                }
                if b.typeIdentifier == "decision" && c.typeIdentifier == "decision" {
                    return 0.8 // Simulate a semantic equivalence for decision drift
                }
                return 0.0
            }
        )
        let config = AlignmentConfiguration<DProvenanceCorpus.AgentEvent>(
            profile: profile,
            equivalenceEvaluator: evaluator
        )
        return TraceAlignmentEngine(configuration: config, metaTraceCallback: callback)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Mode", selection: $selectedTab) {
                Text("Investigation Workspace").tag(0)
                Text("Replay Viewer").tag(1)
                Text("Benchmark Explorer").tag(2)
            }
            .pickerStyle(SegmentedPickerStyle())
            .padding()
            
            if selectedTab == 0 {
                AlignmentInvestigationView(
                    engine: engine,
                    baseRun: baseRun,
                    comparisonRun: compRun,
                    minimumPriority: .diagnostic
                )
                .onAppear {
                    if replayViewModel.timeline.isEmpty && !isAnalyzing {
                        isAnalyzing = true
                        _ = engine.align(base: baseRun, comparison: compRun, minimumPriority: .diagnostic)
                    }
                }
            } else if selectedTab == 1 {
                AlignmentReplayView(viewModel: replayViewModel)
            } else if selectedTab == 2 {
                if let deltaReport = benchmarkDeltaReport {
                    BenchmarkExplorerView(report: deltaReport.currentReport, deltaReport: deltaReport, stabilityReport: benchmarkStabilityReport) { base, comp in
                        // Factory to render a specific case
                        AnyView(
                            AlignmentInvestigationView(
                                engine: createEngine(callback: { _ in }),
                                baseRun: base,
                                comparisonRun: comp,
                                minimumPriority: .diagnostic
                            )
                        )
                    }
                } else {
                    ProgressView("Running Benchmarks...")
                }
            }
        }
        .frame(minWidth: 1000, minHeight: 800)
        .task {
            // Run benchmarks on load
            let runner = BenchmarkRunner<DProvenanceCorpus.AgentEvent>()
            let dataset = DProvenanceCorpus.dataset
            
            // Baseline Configuration (strict). `.evidenceOnly` makes the engine record the
            // verification evidence the ExplainabilityAuditor needs to compute fidelity.
            let baselineReport = await runner.run(dataset: dataset) { @Sendable callback in
                // Payload-aware but "strict": identical events still exact-match (no spurious
                // findings), tool substitutions match weakly, and decision drift is NOT recognized
                // as equivalent — so the baseline flags dropped/added decisions where the tuned
                // config sees semantic drift. That difference is what the delta report surfaces.
                let evaluator = AnyEquivalenceEvaluator<DProvenanceCorpus.AgentEvent>(
                    identifier: "strict_payload",
                    evaluator: { b, c in
                        if b == c { return 1.0 }
                        guard b.typeIdentifier == c.typeIdentifier else { return 0.0 }
                        if case .toolExecution = b { return 0.8 }
                        return 0.0
                    }
                )
                let config = AlignmentConfiguration<DProvenanceCorpus.AgentEvent>(profile: .developerDebugV1, equivalenceEvaluator: evaluator)
                return TraceAlignmentEngine(configuration: config, captureMode: .evidenceOnly, metaTraceCallback: callback)
            }

            // Tuned Configuration (optimized) - Run 3 times to calculate stability/variance
            let boundary = DeterministicBoundary(cacheIsolated: true, seedControl: "tuned_eval_seed_42")
            let tunedStability = await runner.runRepeatedEvaluation(dataset: dataset, iterations: 3, boundary: boundary) { @Sendable context, callback in
                // The perturbation layer can inject equivalence-score noise to simulate engine
                // non-determinism. It is gated by the boundary: because cacheIsolated is true here,
                // the base (deterministic) evaluator is returned unchanged and F1 variance stays 0.0.
                // Flip cacheIsolated to false and the evaluator gets noise-wrapped, so findings — and
                // the measured F1 — will drift across the 3 iterations.
                let perturbation = EvaluationPerturbationLayer(mode: .scoreNoise(amplitude: 0.15))
                let evaluator = perturbation.evaluator(wrapping: DProvenanceCorpus.standardEvaluator, boundary: context.boundary)
                let config = AlignmentConfiguration<DProvenanceCorpus.AgentEvent>(profile: .developerDebugV1, equivalenceEvaluator: evaluator)
                return TraceAlignmentEngine(configuration: config, captureMode: .evidenceOnly, metaTraceCallback: callback)
            }

            self.benchmarkStabilityReport = tunedStability
            if let lastReport = tunedStability.reports.last {
                self.benchmarkDeltaReport = lastReport.compare(to: baselineReport)
            }
        }
    }
}
