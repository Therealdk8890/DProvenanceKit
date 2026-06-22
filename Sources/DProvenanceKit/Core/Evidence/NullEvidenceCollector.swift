import Foundation

public struct NullEvidenceCollector: EvidenceCollector {
    public init() {}
    
    public func recordBinding(_ decision: BindingDecision) {}
    public func recordEquivalence(_ record: EquivalenceDecisionRecord) {}
    public func recordInterpretation(_ step: InterpretationStep) {}
}
