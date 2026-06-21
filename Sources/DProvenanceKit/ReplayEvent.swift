import Foundation

public enum ReplaySource: String, Sendable, Codable, Equatable {
    case committed
    case quarantined
}

public struct ReplayEvent<T: TraceableEvent>: Sendable, Equatable {
    public let source: ReplaySource
    public let event: TraceEvent<T>
    public let replayOrder: UInt64
    
    public init(source: ReplaySource, event: TraceEvent<T>, replayOrder: UInt64) {
        self.source = source
        self.event = event
        self.replayOrder = replayOrder
    }
}
