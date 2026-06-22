import Foundation

public struct FormalizationMap: Sendable {
    public let bindings: [BindingDecision]
    public let decisions: [EquivalenceDecisionRecord]
    public let interpretations: [InterpretationStep]
    
    public init(bindings: [BindingDecision], decisions: [EquivalenceDecisionRecord], interpretations: [InterpretationStep]) {
        self.bindings = bindings
        self.decisions = decisions
        self.interpretations = interpretations
    }
}
