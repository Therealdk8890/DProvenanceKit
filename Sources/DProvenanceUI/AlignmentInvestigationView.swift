import SwiftUI
import DProvenanceKit

@MainActor
public struct AlignmentInvestigationView<T: TraceableEvent>: View {
    @StateObject private var viewModel = AlignmentMatrixViewModel<T>()
    
    let engine: TraceAlignmentEngine<T>
    let baseRun: TraceRun<T>
    let compRun: TraceRun<T>
    let minimumPriority: TracePriority
    
    public init(engine: TraceAlignmentEngine<T>, baseRun: TraceRun<T>, comparisonRun: TraceRun<T>, minimumPriority: TracePriority = .structural) {
        self.engine = engine
        self.baseRun = baseRun
        self.compRun = comparisonRun
        self.minimumPriority = minimumPriority
    }
    
    public var body: some View {
        HStack(spacing: 0) {
            // Main investigation scroll view
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    
                    // 1. Trace Narrative & Critical Findings
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Run Comparison Summary")
                            .font(.largeTitle.bold())
                        
                        Text(viewModel.narrative)
                            .font(.body)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(12)
                    }
                    .padding(.horizontal)
                    
                    // 2. Aggregate Stats
                    if let result = viewModel.result {
                        let totalAlignments = result.alignments.count
                        let semanticMatches = result.alignments.filter { $0.state.isSemanticMatch }.count
                        let removed = result.alignments.filter { $0.state.isRemoved }.count
                        let added = result.alignments.filter { $0.state == .added }.count
                        let exact = result.alignments.filter { $0.state == .exactMatch }.count
                        
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Execution Breakdown").font(.headline)
                            HStack(spacing: 24) {
                                StatBox(title: "Exact", count: exact, color: .green)
                                StatBox(title: "Semantic", count: semanticMatches, color: .orange)
                                StatBox(title: "Added", count: added, color: .blue)
                                StatBox(title: "Removed", count: removed, color: .red)
                            }
                            
                            HStack {
                                Text("Regression Risk:")
                                    .bold()
                                Text(result.regressionRisk.level.rawValue.capitalized)
                                    .foregroundColor(colorForRisk(result.regressionRisk.level))
                            }
                            .padding(.top, 8)
                        }
                        .padding(.horizontal)
                    }
                    
                    Divider()
                    
                    // 3. Matrix Debugger
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Alignment Matrix Heatmap")
                            .font(.title2.bold())
                            .padding(.horizontal)
                        
                        Text("Select a cell to view exact matching evidence and scores.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding(.horizontal)
                        
                        // We extract the core Matrix Grid view from the old debugger
                        MatrixGridView(viewModel: viewModel)
                            .padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
            
            // 4. Matrix Detail Drill-Down
            if let selected = viewModel.selectedCell {
                Divider()
                MatrixDetailPanelView(cell: selected)
                    .frame(width: 350)
                    .background(Color(NSColor.windowBackgroundColor))
            }
        }
        .onAppear {
            viewModel.load(engine: engine, base: baseRun, comparison: compRun, minimumPriority: minimumPriority)
        }
    }
    
    private func colorForRisk(_ level: RegressionRisk.Level) -> Color {
        switch level {
        case .none: return .green
        case .low: return .yellow
        case .medium: return .orange
        case .high: return .red
        }
    }
}

struct StatBox: View {
    let title: String
    let count: Int
    let color: Color
    
    var body: some View {
        VStack {
            Text("\(count)")
                .font(.title.bold())
                .foregroundColor(color)
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(minWidth: 80)
        .background(color.opacity(0.1))
        .cornerRadius(8)
    }
}

// Extracted from AlignmentMatrixDebuggerView
struct MatrixGridView<T: TraceableEvent>: View {
    @ObservedObject var viewModel: AlignmentMatrixViewModel<T>
    
    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 4) {
                // Header Row (Comparison Events)
                HStack(spacing: 4) {
                    Spacer().frame(width: 120) // Top-left empty corner
                    ForEach(viewModel.compEvents, id: \.sequence) { cEvent in
                        Text(cEvent.payload.typeIdentifier)
                            .font(.caption2)
                            .frame(width: 80, height: 40)
                            .rotationEffect(.degrees(-45))
                            .offset(x: 10, y: -10)
                    }
                }
                .padding(.bottom, 20)
                
                // Grid Rows
                ForEach(viewModel.baseEvents.indices, id: \.self) { i in
                    let bEvent = viewModel.baseEvents[i]
                    HStack(spacing: 4) {
                        // Row Header
                        Text(bEvent.payload.typeIdentifier)
                            .font(.caption2)
                            .frame(width: 120, alignment: .trailing)
                        
                        // Cells
                        ForEach(viewModel.compEvents.indices, id: \.self) { j in
                            if let cell = viewModel.cells.first(where: { $0.baseIndex == i && $0.compIndex == j }) {
                                MatrixCellView(
                                    cell: cell,
                                    isSelected: viewModel.selectedCell?.id == cell.id
                                )
                                .onTapGesture {
                                    withAnimation {
                                        viewModel.selectedCell = cell
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding()
        }
    }
}
