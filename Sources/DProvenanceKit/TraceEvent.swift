import Foundation

public struct TraceEvent<T: TraceableEvent>: Sendable, Codable, Equatable {
    public let runID: UUID
    public let contextID: String
    public let engineName: String
    public let schemaVersion: Int
    public let sequence: UInt64
    public let spanID: String?
    public let parentSpanID: String?
    public let payload: T
    public let timestamp: Date
    
    public init(runID: UUID, contextID: String, engineName: String, schemaVersion: Int, sequence: UInt64, spanID: String?, parentSpanID: String?, payload: T, timestamp: Date = Date()) {
        self.runID = runID
        self.contextID = contextID
        self.engineName = engineName
        self.schemaVersion = schemaVersion
        self.sequence = sequence
        self.spanID = spanID
        self.parentSpanID = parentSpanID
        self.payload = payload
        self.timestamp = timestamp
    }
}
