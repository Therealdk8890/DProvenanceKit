import Foundation

public struct AlignmentBinding: Sendable, Equatable {
    public let baseEventID: UUID
    public let comparisonEventID: UUID
    public let similarityScore: Double
    
    public init(baseEventID: UUID, comparisonEventID: UUID, similarityScore: Double) {
        self.baseEventID = baseEventID
        self.comparisonEventID = comparisonEventID
        self.similarityScore = similarityScore
    }
}
