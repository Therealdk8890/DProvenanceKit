import SwiftUI
import DProvenanceKit

public struct DiffOverlayView<T: TraceableEvent>: View {
    let diffResult: SnapshotDiffResult<T>
    
    public init(diffResult: SnapshotDiffResult<T>) {
        self.diffResult = diffResult
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Diff Summary")
                .font(.headline)
            
            HStack(spacing: 16) {
                summaryItem(title: "Added", count: diffResult.summary.addedEvents, color: .green)
                summaryItem(title: "Removed", count: diffResult.summary.removedEvents, color: .red)
                summaryItem(title: "Modified", count: diffResult.summary.modifiedEvents, color: .yellow)
                summaryItem(title: "Diverged", count: diffResult.summary.divergencePoints, color: .red)
            }
            
            HStack(spacing: 16) {
                summaryItem(title: "Spans Added", count: diffResult.summary.addedSpans, color: .green)
                summaryItem(title: "Spans Removed", count: diffResult.summary.removedSpans, color: .red)
                summaryItem(title: "Spans Contaminated", count: diffResult.summary.contaminatedSpans, color: .blue)
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
        )
    }
    
    @ViewBuilder
    private func summaryItem(title: String, count: Int, color: Color) -> some View {
        HStack {
            Circle()
                .fill(count > 0 ? color : Color.gray.opacity(0.3))
                .frame(width: 8, height: 8)
            Text("\(title): \(count)")
                .font(.caption)
                .foregroundColor(count > 0 ? .primary : .secondary)
        }
    }
}
