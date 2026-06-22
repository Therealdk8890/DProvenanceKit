import SwiftUI
import DProvenanceKit

public struct BenchmarkExplorerView<T: TraceableEvent>: View {
    public let report: BenchmarkReport<T>
    public let deltaReport: BenchmarkDeltaReport<T>?
    public let stabilityReport: BenchmarkStabilityReport<T>?
    
    // Using an environment or injected factory to render the detailed investigation view
    public let investigationViewFactory: (TraceRun<T>, TraceRun<T>) -> AnyView
    
    @State private var selectedCaseID: String?
    
    public init(report: BenchmarkReport<T>, deltaReport: BenchmarkDeltaReport<T>? = nil, stabilityReport: BenchmarkStabilityReport<T>? = nil, investigationViewFactory: @escaping (TraceRun<T>, TraceRun<T>) -> AnyView) {
        self.report = report
        self.deltaReport = deltaReport
        self.stabilityReport = stabilityReport
        self.investigationViewFactory = investigationViewFactory
        // Auto-select first failed case, or first case
        _selectedCaseID = State(initialValue: report.caseResults.first(where: { !$0.passed })?.benchmarkCase.id ?? report.caseResults.first?.benchmarkCase.id)
    }
    
    private func metricBadge(delta: Double) -> some View {
        Group {
            if delta > 0 {
                Text(String(format: "(+%.1f%%)", delta * 100))
                    .foregroundColor(.green)
            } else if delta < 0 {
                Text(String(format: "(%.1f%%)", delta * 100))
                    .foregroundColor(.red)
            }
        }
    }
    
    public var body: some View {
        NavigationSplitView {
            List(selection: $selectedCaseID) {
                Section("Metrics") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Precision: \(String(format: "%.1f", report.globalMetrics.precision * 100))%")
                            if let dr = deltaReport { metricBadge(delta: dr.globalDelta.precisionDelta) }
                        }
                        HStack {
                            Text("Recall: \(String(format: "%.1f", report.globalMetrics.recall * 100))%")
                            if let dr = deltaReport { metricBadge(delta: dr.globalDelta.recallDelta) }
                        }
                        HStack {
                            Text("F1 Score: \(String(format: "%.2f", report.globalMetrics.f1Score))")
                            if let dr = deltaReport { metricBadge(delta: dr.globalDelta.f1Delta) }
                        }
                        HStack {
                            Text("Avg Runtime: \(String(format: "%.1f", report.averageRunTimeMs))ms")
                        }
                        
                        Divider()
                        
                        Text("Explainability Fidelity: \(String(format: "%.1f", report.averageFidelityScore * 100))%")
                            .fontWeight(.bold)
                            
                        if let sr = stabilityReport {
                            Divider()
                            Text("Stability Score (\(sr.iterations) runs)")
                                .fontWeight(.bold)
                            Text("Variance: \(String(format: "%.5f", sr.f1Variance))")
                            Text("Drift: \(sr.driftFingerprint)")
                                .foregroundColor(sr.f1Variance < 0.0001 ? .green : .orange)
                            HStack {
                                Text("Cache Isolated: \(sr.boundary.cacheIsolated ? "Yes" : "No")")
                                Text("Seed: \(sr.boundary.seedControl ?? "None")")
                            }
                            .foregroundColor(.gray)
                        }
                    }
                    .font(.caption)
                    .padding(.vertical, 4)
                }
                
                Section("Causal Ranking") {
                    ForEach(report.causalRanking, id: \.cause.label) { rank in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rank.cause == .undiagnosed ? "Unknown / Unclassified" : rank.cause.label)
                                .font(.caption.bold())
                                .foregroundColor(rank.cause == .undiagnosed ? .gray : .primary)
                            HStack {
                                Text("Freq: \(rank.frequency)")
                                Text("Impact: \(String(format: "%.1f", rank.fractionalImpact * 100))%")
                                Text("Z-Score: \(String(format: "%.2f", rank.zScoreImpact))")
                            }
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
                
                Section("Cases (\(report.passedCases)/\(report.totalCases) Passed)") {
                    ForEach(report.caseResults, id: \.benchmarkCase.id) { result in
                        HStack {
                            Image(systemName: result.passed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundColor(result.passed ? .green : .red)
                            Text(result.benchmarkCase.name)
                        }
                        .tag(result.benchmarkCase.id)
                    }
                }
            }
            .navigationTitle("Benchmark Run")
        } detail: {
            if let selectedCaseID = selectedCaseID,
               let result = report.caseResults.first(where: { $0.benchmarkCase.id == selectedCaseID }) {
                BenchmarkCaseDetailView(result: result, investigationViewFactory: investigationViewFactory)
            } else {
                Text("Select a benchmark case.")
            }
        }
    }
}

struct BenchmarkCaseDetailView<T: TraceableEvent>: View {
    let result: BenchmarkCaseResult<T>
    let investigationViewFactory: (TraceRun<T>, TraceRun<T>) -> AnyView
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    Text(result.benchmarkCase.name)
                        .font(.largeTitle.bold())
                    Text(result.benchmarkCase.description)
                        .font(.title3)
                        .foregroundColor(.secondary)
                    
                    HStack {
                        Label("\(String(format: "%.2f", result.runTimeMs))ms", systemImage: "clock")
                        if result.passed {
                            Label("Passed", systemImage: "checkmark.circle.fill").foregroundColor(.green)
                        } else {
                            Label("Failed", systemImage: "xmark.octagon.fill").foregroundColor(.red)
                        }
                    }
                    .font(.headline)
                    .padding(.top, 4)
                }
                .padding(.horizontal)
                
                Divider()
                
                // Explainability Auditor
                    VStack(alignment: .leading, spacing: 4) {
                    Text("Explanation Fidelity")
                        .font(.headline)
                    HStack(spacing: 16) {
                        Text("Trace Coverage: \(String(format: "%.1f", result.fidelityScore.coverage * 100))%")
                        Text("Causal Completeness: \(String(format: "%.1f", result.fidelityScore.completeness * 100))%")
                        Text("Causal Ordering: \(String(format: "%.1f", result.fidelityScore.causalOrdering * 100))%")
                        Text("No Hallucinations: \(String(format: "%.1f", result.fidelityScore.noHallucinations * 100))%")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                .padding(.horizontal)
                
                Divider()
                
                // Delta Lens V2
                DeltaLensView(result: result)
                    .padding(.horizontal)
                
                Divider()
                
                // Investigation View (Matrix, Summary, Timeline)
                Text("Investigation Workspace")
                    .font(.headline)
                    .padding(.horizontal)
                
                investigationViewFactory(result.benchmarkCase.baseRun, result.benchmarkCase.comparisonRun)
            }
            .padding(.vertical)
        }
    }
}

struct DeltaLensView<T: TraceableEvent>: View {
    let result: BenchmarkCaseResult<T>
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Delta Lens: Engine Disagreements")
                .font(.headline)
            
            if result.passed {
                HStack {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundColor(.green)
                    Text("The engine's output perfectly matched expected findings.")
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color.green.opacity(0.1))
                .cornerRadius(8)
            } else {
                ForEach(Array(result.diagnoses.enumerated()), id: \.offset) { index, diagnosis in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            if diagnosis.isFalsePositive {
                                Label("False Positive", systemImage: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                            } else {
                                Label("False Negative", systemImage: "xmark.circle.fill")
                                    .foregroundColor(.red)
                            }
                            
                            Spacer()
                            
                            if diagnosis.isEngineError {
                                Text("Engine Error")
                                    .font(.caption2.bold())
                                    .padding(4)
                                    .background(Color.red.opacity(0.2))
                                    .cornerRadius(4)
                            } else {
                                Text("Dataset Ambiguity")
                                    .font(.caption2.bold())
                                    .padding(4)
                                    .background(Color.orange.opacity(0.2))
                                    .cornerRadius(4)
                            }
                        }
                        .font(.subheadline.bold())
                        
                        Text("Finding: \(String(describing: diagnosis.finding))")
                            .font(.caption)
                        
                        Divider()
                        
                        HStack {
                            Text("Hypothesis: \(diagnosis.hypothesizedCause.label)")
                                .fontWeight(.medium)
                            Spacer()
                            if diagnosis.hypothesizedCause != .undiagnosed {
                                Text("Conf: \(String(format: "%.2f", diagnosis.diagnosisConfidence))")
                                    .foregroundColor(.secondary)
                            }
                        }
                        .font(.caption)
                        
                        Text(diagnosis.reason)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding()
                    .background(Color(NSColor.windowBackgroundColor))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(diagnosis.isFalsePositive ? Color.orange : Color.red, lineWidth: 1)
                    )
                }
            }
        }
    }
}
