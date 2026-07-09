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

struct FormalizationPair: Hashable, Sendable {
    let baseID: String
    let comparisonID: String
}

struct SequencedInterpretation: Sendable {
    let baseSequence: UInt64
    let comparisonSequence: UInt64
    let outputState: String
}

extension BindingDecision {
    var formalizationPair: FormalizationPair {
        FormalizationPair(baseID: baseID, comparisonID: comparisonID)
    }
}

extension EquivalenceDecisionRecord {
    var formalizationPair: FormalizationPair {
        FormalizationPair(baseID: lhs, comparisonID: rhs)
    }
}

extension InterpretationStep {
    var formalizationPair: FormalizationPair? {
        guard let baseID, let comparisonID else { return nil }
        return FormalizationPair(baseID: baseID, comparisonID: comparisonID)
    }

    var sequencedInterpretation: SequencedInterpretation? {
        guard let baseSequence, let comparisonSequence else { return nil }
        return SequencedInterpretation(
            baseSequence: baseSequence,
            comparisonSequence: comparisonSequence,
            outputState: outputState
        )
    }
}
