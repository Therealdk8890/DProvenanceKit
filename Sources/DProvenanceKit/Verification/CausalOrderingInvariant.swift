import Foundation

/// Measures how well the engine's aligned pairs preserve the relative execution order
/// of the two traces. We take every matched pair (both base and comparison anchored to a
/// real execution `sequence`), order them by their base sequence, and count order
/// inversions in the corresponding comparison sequence. A fully order-preserving alignment
/// has zero inversions and scores 1.0; a fully reversed alignment scores 0.0.
///
/// This is an execution-anchored, evidence-derived consistency check — it reads the actual
/// `(baseSequence, comparisonSequence)` recorded for each interpretation step rather than
/// inspecting a textual state label.
public struct CausalOrderingInvariant: FidelityInvariant {
    public init() {}

    public func evaluate(_ map: FormalizationMap) -> Double {
        // Only matched pairs carry an ordering relationship worth checking.
        let matched = map.interpretations
            .compactMap { step -> (base: UInt64, comparison: UInt64)? in
                guard let b = step.baseSequence, let c = step.comparisonSequence else { return nil }
                return (b, c)
            }
            .sorted { $0.base < $1.base }

        // Fewer than two pairs cannot be out of order.
        guard matched.count >= 2 else { return 1.0 }

        let comparisonOrder = matched.map { $0.comparison }
        var inversions = 0
        for i in 0..<comparisonOrder.count {
            for j in (i + 1)..<comparisonOrder.count where comparisonOrder[i] > comparisonOrder[j] {
                inversions += 1
            }
        }

        let maxInversions = comparisonOrder.count * (comparisonOrder.count - 1) / 2
        guard maxInversions > 0 else { return 1.0 }
        return 1.0 - (Double(inversions) / Double(maxInversions))
    }
}
