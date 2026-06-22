import Foundation

public struct EquivalenceReason: Sendable, Equatable {
    public let description: String
    
    public init(description: String) {
        self.description = description
    }
}
