import Foundation

public struct DefaultEquivalenceModel<T: TraceableEvent>: EquivalenceModel {
    public let configuration: AlignmentConfiguration<T>
    
    public init(configuration: AlignmentConfiguration<T>) {
        self.configuration = configuration
    }
    
    public func evaluate<U: TraceableEvent>(
        _ a: TraceEvent<U>,
        _ b: TraceEvent<U>,
        evidenceCollector: EvidenceCollector
    ) -> EquivalenceDecision {
        guard let config = configuration as? AlignmentConfiguration<U> else {
            return EquivalenceDecision(equivalent: false, confidence: 0.0, reason: EquivalenceReason(description: "Type mismatch"))
        }
        
        let (score, explanation) = config.scoreMatch(base: a, comp: b)
        let isEquivalent = score >= config.profile.semanticThreshold
        
        let decision = EquivalenceDecision(
            equivalent: isEquivalent,
            confidence: score,
            reason: EquivalenceReason(description: explanation.primaryReason)
        )
        
        evidenceCollector.recordEquivalence(EquivalenceDecisionRecord(
            lhs: a.id.uuidString,
            rhs: b.id.uuidString,
            confidence: score,
            equivalent: isEquivalent,
            reason: decision.reason
        ))
        
        return decision
    }
}
