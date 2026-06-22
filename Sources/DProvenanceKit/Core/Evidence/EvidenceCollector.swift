import Foundation

public protocol EvidenceCollector: Sendable {
    func recordBinding(_ decision: BindingDecision)
    func recordEquivalence(_ record: EquivalenceDecisionRecord)
    func recordInterpretation(_ step: InterpretationStep)
}
