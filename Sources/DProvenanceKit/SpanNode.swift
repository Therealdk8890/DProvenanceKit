import Foundation

public struct SpanNode<T: TraceableEvent>: Sendable, Equatable {
    public let spanID: String?
    public let startSequence: UInt64
    public let endSequence: UInt64
    public let events: [ReplayEvent<T>]
    public let children: [SpanNode<T>]
    public let containsQuarantinedEvents: Bool
    
    public init(
        spanID: String?,
        startSequence: UInt64,
        endSequence: UInt64,
        events: [ReplayEvent<T>],
        children: [SpanNode<T>],
        containsQuarantinedEvents: Bool
    ) {
        self.spanID = spanID
        self.startSequence = startSequence
        self.endSequence = endSequence
        self.events = events
        self.children = children
        self.containsQuarantinedEvents = containsQuarantinedEvents
    }
}
