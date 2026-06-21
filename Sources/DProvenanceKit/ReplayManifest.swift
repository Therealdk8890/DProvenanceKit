import Foundation

public struct SequenceGap: Sendable, Equatable {
    public let lowerBound: UInt64
    public let upperBound: UInt64
    
    public init(lowerBound: UInt64, upperBound: UInt64) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }
}

public struct ReplayManifest: Sendable, Equatable {
    public let totalEvents: Int
    public let committedEvents: Int
    public let quarantinedEvents: Int
    public let orphanedEvents: Int
    public let duplicateEventIDs: Int
    public let reconstructedSpans: Int
    public let contaminatedSpans: Int
    public let sequenceGaps: [SequenceGap]
    
    public init(
        totalEvents: Int,
        committedEvents: Int,
        quarantinedEvents: Int,
        orphanedEvents: Int,
        duplicateEventIDs: Int,
        reconstructedSpans: Int,
        contaminatedSpans: Int,
        sequenceGaps: [SequenceGap]
    ) {
        self.totalEvents = totalEvents
        self.committedEvents = committedEvents
        self.quarantinedEvents = quarantinedEvents
        self.orphanedEvents = orphanedEvents
        self.duplicateEventIDs = duplicateEventIDs
        self.reconstructedSpans = reconstructedSpans
        self.contaminatedSpans = contaminatedSpans
        self.sequenceGaps = sequenceGaps
    }
}
