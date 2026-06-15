import Foundation

/// A protocol that defines the requirements for an event payload that can be recorded by DProvenanceKit.
/// Consumers should make their event enums or structs conform to this protocol.
public protocol TraceableEvent: Sendable, Codable, Equatable {
    /// A unique string identifier for the type of this event, used by the Trace Query DSL for filtering and sequences.
    var typeIdentifier: String { get }
}
