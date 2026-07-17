import Foundation

/// A self-consistency audit of the engine's OWN evidence chain — not independent
/// verification of alignment correctness.
///
/// Each invariant checks that the matcher → semantics → interpretation pipeline told a
/// coherent story about itself: every reported match is backed by a recorded binding
/// (coverage), an equivalence evaluation (completeness), a supporting verdict
/// (no-hallucinations), and consistent ordering evidence. The evidence being audited is
/// co-produced by the same engine run, so on the shipped default pipeline coverage and
/// completeness are 1.0 by construction — a lower score means a corrupted or
/// hand-assembled `FormalizationMap`, or a pipeline bug, not a semantically wrong
/// alignment. A wrong-but-internally-consistent alignment (e.g. a binding whose
/// similarity is genuinely misleading) scores 1.0 across the board.
///
/// The scores are diagnostic: nothing in the engine gates, rejects, or downgrades a
/// result based on them. Treat a low score as "the evidence chain is broken — do not
/// trust this map's explanations", never a high score as "the alignment is correct".
public final class ExplainabilityAuditor: Sendable {
    private let coverage: FidelityInvariant
    private let completeness: FidelityInvariant
    private let ordering: FidelityInvariant
    private let hallucination: FidelityInvariant
    
    public init(
        coverage: FidelityInvariant = CoverageInvariant(),
        completeness: FidelityInvariant = CompletenessInvariant(),
        ordering: FidelityInvariant = CausalOrderingInvariant(),
        hallucination: FidelityInvariant = NoHallucinationInvariant()
    ) {
        self.coverage = coverage
        self.completeness = completeness
        self.ordering = ordering
        self.hallucination = hallucination
    }
    
    public func audit(_ map: FormalizationMap) -> FidelityVector {
        return FidelityVector(
            coverage: coverage.evaluate(map),
            completeness: completeness.evaluate(map),
            causalOrdering: ordering.evaluate(map),
            noHallucinations: hallucination.evaluate(map)
        )
    }
}
