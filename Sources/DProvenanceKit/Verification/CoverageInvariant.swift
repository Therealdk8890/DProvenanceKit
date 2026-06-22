import Foundation

public struct CoverageInvariant: FidelityInvariant {
    public init() {}
    
    public func evaluate(_ map: FormalizationMap) -> Double {
        // Example implementation: fraction of base items that have a binding or interpretation
        let totalBaseItems = Set(map.interpretations.compactMap { $0.baseID }).count
        guard totalBaseItems > 0 else { return 1.0 }
        
        let mappedBaseItems = Set(map.interpretations.filter { $0.comparisonID != nil }.compactMap { $0.baseID }).count
        return Double(mappedBaseItems) / Double(totalBaseItems)
    }
}
