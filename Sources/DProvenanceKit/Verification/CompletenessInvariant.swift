import Foundation

public struct CompletenessInvariant: FidelityInvariant {
    public init() {}
    
    public func evaluate(_ map: FormalizationMap) -> Double {
        // Example implementation: fraction of comparison items that were mapped
        let totalComparisonItems = Set(map.interpretations.compactMap { $0.comparisonID }).count
        guard totalComparisonItems > 0 else { return 1.0 }
        
        let mappedComparisonItems = Set(map.interpretations.filter { $0.baseID != nil }.compactMap { $0.comparisonID }).count
        return Double(mappedComparisonItems) / Double(totalComparisonItems)
    }
}
