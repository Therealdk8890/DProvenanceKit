import Foundation

public struct TraceEvent<T: TraceableEvent>: Sendable, Codable, Equatable {
    public let runID: UUID
    public let contextID: String
    public let engineName: String
    public let schemaVersion: Int
    public let payload: T
    public let timestamp: Date
    
    public init(runID: UUID, contextID: String, engineName: String, schemaVersion: Int, payload: T, timestamp: Date = Date()) {
        self.runID = runID
        self.contextID = contextID
        self.engineName = engineName
        self.schemaVersion = schemaVersion
        self.payload = payload
        self.timestamp = timestamp
    }
}
