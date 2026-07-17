import Foundation

/// Per-dimension self-consistency scores from `ExplainabilityAuditor` (see its doc for
/// what these do and do not verify).
///
/// Each score is a proportional ratio over matched pairs, so a single unsupported claim
/// in a map of N faithful matches scores ~1 − 1/N: dilution is inherent to the shape.
/// Read the scores as "fraction of the evidence chain that is coherent", not as a
/// confidence that the alignment is right — and compare against 1.0 exactly (any value
/// below 1.0 means at least one broken link), not against a threshold.
public struct FidelityVector: Sendable, Equatable {
    public let coverage: Double
    public let completeness: Double
    public let causalOrdering: Double
    public let noHallucinations: Double

    public init(coverage: Double, completeness: Double, causalOrdering: Double, noHallucinations: Double) {
        self.coverage = coverage
        self.completeness = completeness
        self.causalOrdering = causalOrdering
        self.noHallucinations = noHallucinations
    }

    /// Diagnostic average of the four dimensions. Nothing in the engine gates on this
    /// value; a benchmark or CLI displays it for trend-watching. Because it averages
    /// proportional ratios, it dilutes exactly like its components — a map with one
    /// hallucinated claim among many faithful ones still averages near 1.0.
    public var overallScore: Double {
        return (coverage + completeness + causalOrdering + noHallucinations) / 4.0
    }
}
