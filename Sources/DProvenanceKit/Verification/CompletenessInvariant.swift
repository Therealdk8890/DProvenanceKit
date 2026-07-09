import Foundation

/// Completeness: was every reported alignment actually evaluated by the semantics layer?
///
/// For each interpretation step that claims a match, there must be an `EquivalenceDecisionRecord`
/// for that exact (base, comparison) pair. This audits the matcher -> semantics -> interpretation
/// chain: a reported match with no recorded equivalence evaluation means the causal chain behind
/// the claim is incomplete (the engine asserted a pairing it never evaluated).
public struct CompletenessInvariant: FidelityInvariant {
    public init() {}

    public func evaluate(_ map: FormalizationMap) -> Double {
        let matchedPairs = map.interpretations.compactMap(\.formalizationPair)
        guard !matchedPairs.isEmpty else { return 1.0 }

        let decisionPairs = Set(map.decisions.map(\.formalizationPair))
        let evaluated = matchedPairs.filter { decisionPairs.contains($0) }.count
        return Double(evaluated) / Double(matchedPairs.count)
    }
}
