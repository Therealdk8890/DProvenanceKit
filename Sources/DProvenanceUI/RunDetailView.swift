#if os(macOS)
import SwiftUI
import DProvenanceKit

public struct RunDetailView: View {
    let run: TraceRun<AnyTraceableEvent>
    
    @State private var currentSequence: UInt64 = 0
    @State private var comparisonSequence: UInt64 = 0
    @State private var isComparisonMode: Bool = false
    
    // Engine and Snapshots
    private var engine: TraceReplayEngine<AnyTraceableEvent> {
        TraceReplayEngine(committed: run.events, quarantined: [])
    }
    
    private var baseSnapshot: ReplaySnapshot<AnyTraceableEvent> {
        engine.snapshot(at: currentSequence == 0 ? nil : currentSequence)
    }
    
    private var comparisonSnapshot: ReplaySnapshot<AnyTraceableEvent>? {
        guard isComparisonMode else { return nil }
        return engine.snapshot(at: comparisonSequence == 0 ? nil : comparisonSequence)
    }
    
    private var diffResult: SnapshotDiffResult<AnyTraceableEvent>? {
        guard let comp = comparisonSnapshot else { return nil }
        let diffEngine = SnapshotDiffEngine<AnyTraceableEvent>()
        return diffEngine.diff(base: baseSnapshot, comparison: comp)
    }
    
    // Tree Projections
    private var projectedNodes: [FlattenedSpanNode<AnyTraceableEvent>] {
        let hints = RenderHints(diffMode: isComparisonMode ? .comparison : .none)
        
        let targetSnapshot = isComparisonMode ? (comparisonSnapshot ?? baseSnapshot) : baseSnapshot
        
        // Convert SpanNodes to SpanViewModels
        let snapshotID = isComparisonMode ? "diff_\(currentSequence)_\(comparisonSequence)" : "snap_\(currentSequence)"
        let rootModels = targetSnapshot.roots.map { root in
            SpanViewModel(
                node: root,
                snapshotID: snapshotID,
                localPathHash: String("root->\(root.spanID ?? "anon")".hashValue),
                depth: 0,
                hints: hints
            ) 
        }
        
        return flattenSpanTree(roots: rootModels, dynamicCollapsed: [])
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading) {
                    Text(run.contextID)
                        .font(.title)
                        .bold()
                    Text("Run ID: \(run.runID.uuidString)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Text("\(run.events.count) Events")
                        .font(.headline)
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // Timeline Scrubber
            TraceTimelineView(
                engine: engine,
                currentSequence: $currentSequence,
                isComparisonMode: $isComparisonMode,
                comparisonSequence: $comparisonSequence
            )
            
            Divider()
            
            // Optional Diff Overlay
            if let diff = diffResult {
                DiffOverlayView(diffResult: diff)
                    .padding()
            }
            
            // Tree Render
            SpanTreeView(
                nodes: projectedNodes,
                diffResult: diffResult
            )
        }
    }
}
#endif
