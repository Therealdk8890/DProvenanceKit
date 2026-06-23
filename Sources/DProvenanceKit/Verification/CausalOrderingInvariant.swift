import Foundation

/// CausalOrdering: are execution-order changes faithfully *reported*?
///
/// This is NOT a penalty for reordering — a reordered trace is a legitimate finding. It is a
/// faithfulness check: every matched pair whose relative execution order changed (an inversion,
/// measured on the recorded `(baseSequence, comparisonSequence)` anchors) must be reported by the
/// interpreter as `reordered`. An event the engine silently moved while labelling it
/// exact/semantic match is an unfaithful ordering claim. A faithful explanation that labels its
/// reorders scores 1.0 even when the trace is heavily reordered.
public struct CausalOrderingInvariant: FidelityInvariant {
    public init() {}

    public func evaluate(_ map: FormalizationMap) -> Double {
        let matched = map.interpretations
            .filter { $0.baseSequence != nil && $0.comparisonSequence != nil }
            .sorted { ($0.baseSequence ?? 0) < ($1.baseSequence ?? 0) }

        // Fewer than two pairs cannot be out of order.
        guard matched.count >= 2 else { return 1.0 }

        // A step is "out of order" if it forms an inversion (base order ascending, comparison
        // order descending) with any other matched step.
        var outOfOrder = Set<Int>()
        for i in 0..<matched.count {
            for j in (i + 1)..<matched.count
            where (matched[i].comparisonSequence ?? 0) > (matched[j].comparisonSequence ?? 0) {
                outOfOrder.insert(i)
                outOfOrder.insert(j)
            }
        }

        // A faithful explanation reports each out-of-order step as a reorder.
        let unreported = outOfOrder.filter { !matched[$0].outputState.hasPrefix("reordered") }.count
        return 1.0 - (Double(unreported) / Double(matched.count))
    }
}
