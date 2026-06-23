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
        let matched = map.interpretations.filter { $0.baseID != nil && $0.comparisonID != nil }
        guard !matched.isEmpty else { return 1.0 }

        var equivalentByPair: [String: Bool] = [:]
        for d in map.decisions { equivalentByPair["\(d.lhs)\u{1}\(d.rhs)"] = d.equivalent }

        let supported = matched.filter { step in
            if step.outputState.hasPrefix("ambiguous") { return true } // honest "unsure" verdict
            return equivalentByPair["\(step.baseID!)\u{1}\(step.comparisonID!)"] == true
        }.count
        return Double(supported) / Double(matched.count)
    }
}
