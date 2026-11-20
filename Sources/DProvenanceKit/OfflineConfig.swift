import Foundation

public struct BufferCapacity: Sendable {
    public let maxItems: Int
    public let maxBytes: Int
    public let maxEventSizeBytes: Int
    /// Lineage edges waiting for the writer. Edges are queued apart from events, so
    /// without this bound a `link()` storm while the writer is stalled (offline cloud,
    /// a blocked disk) grew memory without limit. An edge refused at the cap is
    /// counted as a structural drop, so `dropStats.preservedIntegrity` turns false.
    public let maxPendingEdges: Int
    
    public init(
        maxItems: Int = 50_000,
        maxBytes: Int = 50 * 1024 * 1024,
        maxEventSizeBytes: Int = 1 * 1024 * 1024,
        maxPendingEdges: Int = 100_000
    ) {
        self.maxItems = maxItems
        self.maxBytes = maxBytes
        self.maxEventSizeBytes = maxEventSizeBytes
        self.maxPendingEdges = maxPendingEdges
    }
}

public enum EvictionPolicy: Sendable {
    case dropOldest
    case rejectNew
}

public struct OfflineConfig: Sendable {
    public let capacity: BufferCapacity
    public let eviction: EvictionPolicy
    
    public init(capacity: BufferCapacity = BufferCapacity(), eviction: EvictionPolicy = .dropOldest) {
        self.capacity = capacity
        self.eviction = eviction
    }
}
