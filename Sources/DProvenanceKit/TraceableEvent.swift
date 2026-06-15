import Foundation

/// A protocol that defines the requirements for an event payload that can be recorded by DProvenanceKit.
/// Consumers should make their event enums or structs conform to this protocol.
public protocol TraceableEvent: Codable, Sendable, Equatable {
    /// A unique string identifying the event type (e.g. "tool_call", "llm_response").
    /// MUST be stable across schema versions to guarantee diffing and query integrity.
    var typeIdentifier: String { get }
    
    /// The priority tier for this event, determining its survival during extreme congestion
    var priority: TracePriority { get }
}
