import Foundation

public protocol TraceMatcher: Sendable {
    func match<T: TraceableEvent>(
        base: [TraceEvent<T>],
        comparison: [TraceEvent<T>],
        evidenceCollector: EvidenceCollector
    ) -> [AlignmentBinding]
}
