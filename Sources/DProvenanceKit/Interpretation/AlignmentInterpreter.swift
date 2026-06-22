import Foundation

public protocol AlignmentInterpreter: Sendable {
    func interpret<T: TraceableEvent>(
        base: [TraceEvent<T>],
        comparison: [TraceEvent<T>],
        bindings: [AlignmentBinding],
        equivalence: (TraceEvent<T>, TraceEvent<T>) -> EquivalenceDecision,
        evidenceCollector: EvidenceCollector
    ) -> [EventAlignment<T>]
}
