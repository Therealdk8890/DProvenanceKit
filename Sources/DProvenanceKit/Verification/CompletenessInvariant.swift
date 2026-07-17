import Foundation

/// Completeness: was every reported alignment actually evaluated by the semantics layer?
///
/// For each interpretation step that claims a match, there must be an `EquivalenceDecisionRecord`
/// for that exact (base, comparison) pair. This audits the matcher -> semantics -> interpretation
/// chain: a reported match with no recorded equivalence evaluation means the causal chain behind
/// the claim is incomplete (the engine asserted a pairing it never evaluated).
///
/// On the shipped default pipeline this is 1.0 by construction: the interpreter records an
/// equivalence decision for every pairing it emits. A lower score indicates a corrupted or
/// hand-assembled map, or a pipeline bug — the decision's *content* (was the evaluation
/// right?) is outside this check's reach. Empty maps score 1.0 vacuously.
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
