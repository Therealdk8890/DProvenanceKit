import SwiftUI
import DProvenanceKit

public struct AlignmentReplayView: View {
    @ObservedObject var viewModel: AlignmentReplayViewModel
    
    public init(viewModel: AlignmentReplayViewModel) {
        self.viewModel = viewModel
    }
    
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Alignment Decision Timeline")
                    .font(.largeTitle.bold())
                    .padding(.bottom, 8)
                
                if viewModel.timeline.isEmpty {
                    Text("No events recorded yet. Run an alignment to populate the timeline.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(viewModel.timeline) { entry in
                        TimelineEntryView(entry: entry)
                    }
                }
            }
            .padding()
        }
    }
}

struct TimelineEntryView: View {
    let entry: DecisionTimelineEntry
    
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            // Timeline line & dot
            VStack {
                Circle()
                    .fill(colorForCategory(entry.strengthCategory))
                    .frame(width: 12, height: 12)
                
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 2)
            }
            
            // Content
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(entry.title)
                        .font(.headline)
                    Spacer()
                    Text(formatter.string(from: entry.timestamp))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                Text(entry.detail)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                if let category = entry.strengthCategory {
                    Text("Strength: \(category.rawValue.capitalized)")
                        .font(.caption.bold())
                        .foregroundColor(colorForCategory(category))
                        .padding(.top, 2)
                }
            }
            .padding(.bottom, 16)
        }
    }
    
    private func colorForCategory(_ category: AlignmentStrengthCategory?) -> Color {
        guard let category = category else { return .blue }
        switch category {
        case .strong: return .green
        case .moderate: return .orange
        case .weak: return .red
        case .rejected: return .secondary
        }
    }
    
    private var formatter: DateFormatter {
        let fmt = DateFormatter()
        fmt.timeStyle = .medium
        return fmt
    }
}
