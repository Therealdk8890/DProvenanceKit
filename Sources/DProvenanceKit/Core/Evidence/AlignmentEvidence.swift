import Foundation

public struct AlignmentEvidence: Sendable {
    public let bindings: [BindingDecision]
    public let equivalenceDecisions: [EquivalenceDecisionRecord]
    public let interpretationSteps: [InterpretationStep]
    
    public init(bindings: [BindingDecision], equivalenceDecisions: [EquivalenceDecisionRecord], interpretationSteps: [InterpretationStep]) {
        self.bindings = bindings
        self.equivalenceDecisions = equivalenceDecisions
        self.interpretationSteps = interpretationSteps
    }
}
