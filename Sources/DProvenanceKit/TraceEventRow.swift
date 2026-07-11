import Foundation

/// A normalized representation of a trace event suitable for database storage.
public struct TraceEventRow: Sendable {
    public let id: String
    public let runID: String
    public let contextID: String
    public let priority: Int
    public let sequence: Int64
    public let engine: String?
    public let spanID: String?
    public let parentSpanID: String?
    public let type: String
    public let payload: Data
    public let timestamp: Int64
    /// `TraceEvent.schemaVersion`, carried so the round-trip through storage cannot
    /// silently rewrite an event's schema metadata (which a signed attestation covers).
    /// Defaults to 1 for rows read from stores created before the column existed.
    public let schemaVersion: Int

    public init(id: String, runID: String, contextID: String, priority: Int, sequence: Int64, engine: String?, spanID: String?, parentSpanID: String?, type: String, payload: Data, timestamp: Int64, schemaVersion: Int = 1) {
        self.id = id
        self.runID = runID
        self.contextID = contextID
        self.priority = priority
        self.sequence = sequence
        self.engine = engine
        self.spanID = spanID
        self.parentSpanID = parentSpanID
        self.type = type
        self.payload = payload
        self.timestamp = timestamp
        self.schemaVersion = schemaVersion
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
