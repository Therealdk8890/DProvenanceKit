import Foundation

public struct EquivalenceDecisionRecord: Sendable {
    public let lhs: String
    public let rhs: String
    public let confidence: Double
    public let equivalent: Bool
    public let reason: EquivalenceReason
    
    public init(lhs: String, rhs: String, confidence: Double, equivalent: Bool, reason: EquivalenceReason) {
        self.lhs = lhs
        self.rhs = rhs
        self.confidence = confidence
        self.equivalent = equivalent
        self.reason = reason
    }
}
