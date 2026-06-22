import Foundation

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
    
    public var overallScore: Double {
        return (coverage + completeness + causalOrdering + noHallucinations) / 4.0
    }
}
