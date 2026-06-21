import Foundation

public struct BufferCapacity: Sendable {
    public let maxItems: Int
    public let maxBytes: Int
    public let maxEventSizeBytes: Int
    
    public init(maxItems: Int = 50_000, maxBytes: Int = 50 * 1024 * 1024, maxEventSizeBytes: Int = 1 * 1024 * 1024) {
        self.maxItems = maxItems
        self.maxBytes = maxBytes
        self.maxEventSizeBytes = maxEventSizeBytes
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
