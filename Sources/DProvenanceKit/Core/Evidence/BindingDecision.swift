import Foundation

public struct BindingDecision: Sendable {
    public let baseID: String
    public let comparisonID: String
    public let similarityScore: Double
    
    public init(baseID: String, comparisonID: String, similarityScore: Double) {
        self.baseID = baseID
        self.comparisonID = comparisonID
        self.similarityScore = similarityScore
    }
}
