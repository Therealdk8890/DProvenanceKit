import Foundation

public struct AnyTraceableEvent: TraceableEvent, Codable, Equatable, Sendable {
    public let typeIdentifier: String
    public let priorityValue: Int
    public let rawJSON: String
    
    public var priority: TracePriority {
        TracePriority(rawValue: priorityValue) ?? .telemetry
    }
    
    public init(typeIdentifier: String, priorityValue: Int, rawJSON: String) {
        self.typeIdentifier = typeIdentifier
        self.priorityValue = priorityValue
        self.rawJSON = rawJSON
    }
}
