#if os(macOS)
import SwiftUI
import DProvenanceKit

public struct AlignmentMatrixDebuggerView<T: TraceableEvent>: View {
    @StateObject private var viewModel = AlignmentMatrixViewModel<T>()
    
    public let engine: TraceAlignmentEngine<T>
    public let baseRun: TraceRun<T>
    public let compRun: TraceRun<T>
    public let minimumPriority: TracePriority
    
    public init(engine: TraceAlignmentEngine<T>, base: TraceRun<T>, comparison: TraceRun<T>, minimumPriority: TracePriority = .structural) {
        self.engine = engine
        self.baseRun = base
        self.compRun = comparison
        self.minimumPriority = minimumPriority
    }
    
    public var body: some View {
        HStack(spacing: 0) {
            // Matrix Grid
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 2) {
                    // Header Row (Comp Events)
                    HStack(spacing: 2) {
                        Text("Base \\ Comp")
                            .frame(width: 120, height: 40)
                            .background(Color.secondary.opacity(0.1))
                        
                        ForEach(viewModel.compEvents, id: \.id) { cEvent in
                            Text(cEvent.payload.typeIdentifier)
                                .font(.caption)
                                .frame(width: 80, height: 40)
                                .background(Color.secondary.opacity(0.1))
                        }
                    }
                    
                    // Grid Rows
                    ForEach(viewModel.baseEvents, id: \.id) { bEvent in
                        HStack(spacing: 2) {
                            Text(bEvent.payload.typeIdentifier)
                                .font(.caption)
                                .frame(width: 120, alignment: .trailing)
                                .padding(.trailing, 8)
                            
                            ForEach(viewModel.compEvents, id: \.id) { cEvent in
                                if let cell = viewModel.cells.first(where: { $0.baseEvent.id == bEvent.id && $0.compEvent.id == cEvent.id }) {
                                    MatrixCellView(cell: cell, isSelected: viewModel.selectedCell?.id == cell.id)
                                        .onTapGesture {
                                            viewModel.selectedCell = cell
                                        }
                                } else {
                                    Color.clear.frame(width: 80, height: 80)
                                }
                            }
                        }
                    }
                }
                .padding()
            }
            
            // Detail Panel
            if let selected = viewModel.selectedCell {
                MatrixDetailPanelView(cell: selected)
                    .frame(width: 300)
                    .background(Color(NSColor.windowBackgroundColor))
                    .border(Color.secondary.opacity(0.3), width: 1)
            }
        }
        .onAppear {
            viewModel.load(engine: engine, base: baseRun, comparison: compRun, minimumPriority: minimumPriority)
        }
    }
}

struct MatrixCellView<T: TraceableEvent>: View {
    let cell: MatrixCellData<T>
    let isSelected: Bool
    
    var body: some View {
        ZStack {
            Rectangle()
                .fill(colorForScore(cell.score))
            
            VStack {
                Text(String(format: "%.2f", cell.score))
                    .font(.caption.bold())
                    .foregroundColor(cell.score > 0.4 ? .white : .primary)
            }
        }
        .frame(width: 80, height: 80)
        .overlay(
            Rectangle()
                .stroke(isSelected ? Color.blue : (cell.isFinalMatch ? Color.green : Color.clear), lineWidth: isSelected ? 3 : (cell.isFinalMatch ? 4 : 0))
        )
    }
    
    func colorForScore(_ score: Double) -> Color {
        let category = AlignmentStrengthCategory(strength: score)
        switch category {
        case .strong: return Color(red: 0.1, green: 0.8, blue: 0.2, opacity: 0.8)
        case .moderate: return Color(red: 0.4, green: 0.7, blue: 0.2, opacity: 0.6)
        case .weak: return Color(red: 0.7, green: 0.5, blue: 0.2, opacity: 0.4)
        case .rejected: return Color(red: 0.9, green: 0.2, blue: 0.2, opacity: 0.2)
        }
    }
}

struct MatrixDetailPanelView<T: TraceableEvent>: View {
    let cell: MatrixCellData<T>
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Cell Details")
                    .font(.headline)
                
                HStack {
                    VStack(alignment: .leading) {
                        Text("Base").font(.subheadline.bold())
                        Text(cell.baseEvent.payload.typeIdentifier)
                        Text("Seq: \(cell.baseEvent.sequence)").font(.caption2)
                    }
                    Spacer()
                    VStack(alignment: .leading) {
                        Text("Comp").font(.subheadline.bold())
                        Text(cell.compEvent.payload.typeIdentifier)
                        Text("Seq: \(cell.compEvent.sequence)").font(.caption2)
                    }
                }
                
                Divider()
                
                HStack {
                    Text("Total Strength:").bold()
                    Spacer()
                    let category = AlignmentStrengthCategory(strength: cell.score)
                    Text("\(String(format: "%.2f", cell.score)) (\(category.rawValue.capitalized))")
                        .foregroundColor(colorForCategoryText(category))
                }
                
                if cell.isFinalMatch {
                    Text("✓ Final Engine Match")
                        .foregroundColor(.green)
                        .bold()
                }
                
                Divider()
                
                Text("Evidence Breakdown")
                    .font(.subheadline.bold())
                
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(cell.explanation.rankedEvidence, id: \.category.rawValue) { evidence in
                        ExplanationRow(title: evidence.category.rawValue, score: evidence.scoreContribution)
                        Text(evidence.description)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                
                if cell.explanation.primaryReason != "No match" {
                    Divider()
                    Text("Primary Reason:")
                        .font(.subheadline.bold())
                    Text(cell.explanation.primaryReason)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding()
        }
    }
    
    func colorForCategoryText(_ category: AlignmentStrengthCategory) -> Color {
        switch category {
        case .strong: return .green
        case .moderate: return .orange
        case .weak: return .red
        case .rejected: return .secondary
        }
    }
}

struct ExplanationRow: View {
    let title: String
    let score: Double
    
    var body: some View {
        HStack {
            Text(title)
                .font(.caption)
            Spacer()
            Text(String(format: "%.2f", score))
                .font(.caption.monospacedDigit())
        }
    }
}

#Preview {
    let (base, comp) = DProvenanceCorpus.semanticEvolution
    let configuration = AlignmentConfiguration<DProvenanceCorpus.AgentEvent>(
        profile: .developerDebugV1,
        equivalenceEvaluator: AnyEquivalenceEvaluator(
            identifier: "preview.eval",
            evaluator: { b, c in
                // Semantic evolution evaluator
                if b.typeIdentifier == c.typeIdentifier { return 1.0 }
                if b.typeIdentifier == "tool" && c.typeIdentifier == "tool" {
                    return 0.95 // High semantic similarity
                }
                return 0.0
            },
            ambiguityThresholdFn: { _ in 0.8 }
        )
    )
    let engine = TraceAlignmentEngine(configuration: configuration)
    
    AlignmentMatrixDebuggerView(
        engine: engine,
        base: base,
        comparison: comp,
        minimumPriority: .structural
    )
    .frame(width: 800, height: 600)
}
#endif
