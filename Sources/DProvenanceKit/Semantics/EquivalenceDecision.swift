import Foundation

public struct EquivalenceDecision: Sendable, Equatable {
    public let equivalent: Bool
    public let confidence: Double
    public let reason: EquivalenceReason
    
    public init(equivalent: Bool, confidence: Double, reason: EquivalenceReason) {
        self.equivalent = equivalent
        self.confidence = confidence
        self.reason = reason
    }
}
