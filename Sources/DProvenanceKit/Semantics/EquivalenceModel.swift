import Foundation

public protocol EquivalenceModel: Sendable {
    func evaluate<T: TraceableEvent>(
        _ a: TraceEvent<T>,
        _ b: TraceEvent<T>,
        evidenceCollector: EvidenceCollector
    ) -> EquivalenceDecision
}
