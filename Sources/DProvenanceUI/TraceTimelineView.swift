import SwiftUI
import DProvenanceKit

public struct TraceTimelineView<T: TraceableEvent>: View {
    let engine: TraceReplayEngine<T>
    @Binding var currentSequence: UInt64
    @Binding var isComparisonMode: Bool
    @Binding var comparisonSequence: UInt64
    
    public init(
        engine: TraceReplayEngine<T>,
        currentSequence: Binding<UInt64>,
        isComparisonMode: Binding<Bool>,
        comparisonSequence: Binding<UInt64>
    ) {
        self.engine = engine
        self._currentSequence = currentSequence
        self._isComparisonMode = isComparisonMode
        self._comparisonSequence = comparisonSequence
    }
    
    private var maxSequence: UInt64 {
        let maxC = engine.committed.map(\.sequence).max() ?? 0
        let maxQ = engine.quarantined.map(\.sequence).max() ?? 0
        return max(maxC, maxQ)
    }
    
    public var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Replay Timeline")
                    .font(.headline)
                Spacer()
                
                Toggle("Diff Mode", isOn: $isComparisonMode)
                    .toggleStyle(.button)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text("Base Snapshot (Seq: \(currentSequence))")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Slider(
                    value: Binding(
                        get: { Double(currentSequence) },
                        set: { currentSequence = UInt64($0) }
                    ),
                    in: 0...Double(maxSequence),
                    step: 1
                )
            }
            
            if isComparisonMode {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Comparison Snapshot (Seq: \(comparisonSequence))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Slider(
                        value: Binding(
                            get: { Double(comparisonSequence) },
                            set: { comparisonSequence = UInt64($0) }
                        ),
                        in: 0...Double(maxSequence),
                        step: 1
                    )
                }
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
}
