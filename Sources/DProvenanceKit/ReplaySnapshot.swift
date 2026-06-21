import Foundation

public struct ReplaySnapshotMetadata: Sendable, Equatable {
    public let generatedAt: Date
    public let maxSequenceIncluded: UInt64?
    public let sourceCounts: [ReplaySource: Int]
    
    public init(generatedAt: Date, maxSequenceIncluded: UInt64?, sourceCounts: [ReplaySource: Int]) {
        self.generatedAt = generatedAt
        self.maxSequenceIncluded = maxSequenceIncluded
        self.sourceCounts = sourceCounts
    }
}

public struct ReplaySnapshot<T: TraceableEvent>: Sendable {
    public let roots: [SpanNode<T>]
    public let orphanedEvents: [ReplayEvent<T>]
    public let manifest: ReplayManifest
    public let metadata: ReplaySnapshotMetadata
    
    public init(
        roots: [SpanNode<T>],
        orphanedEvents: [ReplayEvent<T>],
        manifest: ReplayManifest,
        metadata: ReplaySnapshotMetadata
    ) {
        self.roots = roots
        self.orphanedEvents = orphanedEvents
        self.manifest = manifest
        self.metadata = metadata
    }
}
