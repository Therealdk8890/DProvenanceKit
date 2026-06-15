import Foundation

/// A normalized representation of a trace event suitable for database storage.
public struct TraceEventRow: Sendable {
    public let id: String
    public let runID: String
    public let contextID: String
    public let priority: Int
    public let engine: String?
    public let type: String
    public let payload: Data
    public let timestamp: Int64
    
    public init(id: String, runID: String, contextID: String, priority: Int, engine: String?, type: String, payload: Data, timestamp: Int64) {
        self.id = id
        self.runID = runID
        self.contextID = contextID
        self.priority = priority
        self.engine = engine
        self.type = type
        self.payload = payload
        self.timestamp = timestamp
    }
}

/// A normalized representation of a trace run's metadata.
public struct RunRow: Sendable {
    public let runID: String
    public let contextID: String
    public let startTime: Int64
    public var endTime: Int64
    public var eventCount: Int
    public var fingerprint: String
    
    public init(runID: String, contextID: String, startTime: Int64, endTime: Int64, eventCount: Int, fingerprint: String) {
        self.runID = runID
        self.contextID = contextID
        self.startTime = startTime
        self.endTime = endTime
        self.eventCount = eventCount
        self.fingerprint = fingerprint
    }
}
