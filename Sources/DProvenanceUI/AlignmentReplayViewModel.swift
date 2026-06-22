import Foundation
import DProvenanceKit

@MainActor
public class AlignmentReplayViewModel: ObservableObject {
    @Published public var timeline: [DecisionTimelineEntry] = []
    
    public init() {}
    
    public func ingest(_ event: TraceEvent<AlignmentMetaEvent>) {
        let entry = mapToTimeline(event: event)
        self.timeline.append(entry)
    }
    
    public func clear() {
        self.timeline.removeAll()
    }
    
    private func mapToTimeline(event: TraceEvent<AlignmentMetaEvent>) -> DecisionTimelineEntry {
        let title: String
        let detail: String
        var category: AlignmentStrengthCategory? = nil
        
        switch event.payload {
        case .evaluatedPair(_, _, let baseSeq, let compSeq, let score):
            title = "Evaluated Base:\(baseSeq) → Comp:\(compSeq)"
            detail = "Calculated heuristic alignment score."
            category = AlignmentStrengthCategory(strength: score)
            
        case .ambiguityThresholdMet(_, _, let compSeq, let score):
            title = "Ambiguity Threshold Exceeded"
            detail = "Comparison event \(compSeq) hit ambiguity threshold."
            category = AlignmentStrengthCategory(strength: score)
            
        case .candidateEvicted(_, _, let compSeq, let reason):
            title = "Rejected Comp:\(compSeq)"
            detail = "Reason: \(reason)"
            category = .rejected
            
        case .regressionDetected(_, _, let level, let reasoning):
            title = "Regression Risk: \(level.capitalized)"
            detail = reasoning
        }
        
        return DecisionTimelineEntry(
            id: event.id,
            timestamp: event.timestamp,
            title: title,
            detail: detail,
            strengthCategory: category
        )
    }
}
