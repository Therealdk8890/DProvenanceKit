import Foundation

/// Coverage: is every reported alignment grounded in the matching layer?
///
/// For each interpretation step that claims a match (both a base and a comparison event), there
/// must be a corresponding `BindingDecision` recorded by the matcher. A match the interpreter
/// reports without a backing binding is an ungrounded claim — the explanation references a
/// pairing the evidence does not support.
public struct CoverageInvariant: FidelityInvariant {
    public init() {}

    public func evaluate(_ map: FormalizationMap) -> Double {
        let matched = map.interpretations.filter { $0.baseID != nil && $0.comparisonID != nil }
        guard !matched.isEmpty else { return 1.0 }

        let boundPairs = Set(map.bindings.map { "\($0.baseID)\u{1}\($0.comparisonID)" })
        let grounded = matched.filter { boundPairs.contains("\($0.baseID!)\u{1}\($0.comparisonID!)") }.count
        return Double(grounded) / Double(matched.count)
    }
}
