import Foundation

/// NoHallucinations: does each definitive match claim agree with its own evidence?
///
/// A step that claims a definitive match (exact / semantic / reordered) must be backed by an
/// equivalence decision that actually found the pair equivalent. If the recorded decision says
/// `equivalent == false` (or there is no decision at all), the interpreter asserted a match its
/// semantics layer did not support — a hallucinated conclusion.
///
/// Ambiguous verdicts are exempt: ambiguity is an honest "not confident" outcome, not a claim of
/// equivalence, so a sub-threshold equivalence decision under an ambiguous step is expected.
public struct NoHallucinationInvariant: FidelityInvariant {
    public init() {}

    public func evaluate(_ map: FormalizationMap) -> Double {
        let matched = map.interpretations.compactMap { step -> (pair: FormalizationPair, outputState: String)? in
            guard let pair = step.formalizationPair else { return nil }
            return (pair, step.outputState)
        }
        guard !matched.isEmpty else { return 1.0 }

        var equivalentByPair: [FormalizationPair: Bool] = [:]
        for decision in map.decisions {
            equivalentByPair[decision.formalizationPair] = decision.equivalent
        }

        let supported = matched.filter { step in
            if step.outputState.hasPrefix("ambiguous") { return true } // honest "unsure" verdict
            return equivalentByPair[step.pair] == true
        }.count
        return Double(supported) / Double(matched.count)
    }
}
