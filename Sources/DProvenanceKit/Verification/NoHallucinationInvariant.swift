import Foundation

public struct NoHallucinationInvariant: FidelityInvariant {
    public init() {}
    
    public func evaluate(_ map: FormalizationMap) -> Double {
        // Hallucination invariant penalizes "added" events (events in comparison that do not exist in base).
        let totalComparisonItems = map.interpretations.filter { $0.comparisonID != nil }.count
        guard totalComparisonItems > 0 else { return 1.0 }
        
        let hallucinatedItems = map.interpretations.filter { $0.baseID == nil && $0.comparisonID != nil }.count
        return 1.0 - (Double(hallucinatedItems) / Double(totalComparisonItems))
    }
}
