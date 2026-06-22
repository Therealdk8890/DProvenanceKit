import Foundation

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
