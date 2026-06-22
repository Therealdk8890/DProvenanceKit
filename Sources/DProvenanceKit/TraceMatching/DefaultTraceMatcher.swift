import Foundation

public struct DefaultTraceMatcher<T: TraceableEvent>: TraceMatcher {
    public let configuration: AlignmentConfiguration<T>
    
    public init(configuration: AlignmentConfiguration<T>) {
        self.configuration = configuration
    }
    
    public func match<U: TraceableEvent>(
        base: [TraceEvent<U>],
        comparison: [TraceEvent<U>],
        evidenceCollector: EvidenceCollector
    ) -> [AlignmentBinding] {
        guard let config = configuration as? AlignmentConfiguration<U> else { return [] }

        // Score every candidate pair that clears the (per-base) ambiguity threshold, then assign
        // greedily HIGHEST SCORE FIRST. A purely base-order greedy match mis-pairs distinct
        // same-type events: e.g. it would bind an earlier base decision to the only comparison
        // decision and orphan its true identical counterpart. Global score-ordered assignment
        // ensures an exact/strong match always wins the binding over a weaker incidental one.
        var candidates: [(baseIdx: Int, compIdx: Int, score: Double)] = []
        for (i, bEvent) in base.enumerated() {
            let threshold = config.equivalenceEvaluator.ambiguityThreshold(for: bEvent.payload)
            for (j, cEvent) in comparison.enumerated() {
                let (score, _) = config.scoreMatch(base: bEvent, comp: cEvent)
                if score >= threshold {
                    candidates.append((baseIdx: i, compIdx: j, score: score))
                }
            }
        }

        // Deterministic ordering: by score desc, then base index, then comparison index.
        candidates.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.baseIdx != b.baseIdx { return a.baseIdx < b.baseIdx }
            return a.compIdx < b.compIdx
        }

        var bindings: [AlignmentBinding] = []
        var usedBaseIndices = Set<Int>()
        var usedComparisonIndices = Set<Int>()
        for cand in candidates {
            if usedBaseIndices.contains(cand.baseIdx) || usedComparisonIndices.contains(cand.compIdx) { continue }
            usedBaseIndices.insert(cand.baseIdx)
            usedComparisonIndices.insert(cand.compIdx)

            let bEvent = base[cand.baseIdx]
            let cEvent = comparison[cand.compIdx]
            bindings.append(AlignmentBinding(baseEventID: bEvent.id, comparisonEventID: cEvent.id, similarityScore: cand.score))
            evidenceCollector.recordBinding(BindingDecision(
                baseID: bEvent.id.uuidString,
                comparisonID: cEvent.id.uuidString,
                similarityScore: cand.score
            ))
        }

        return bindings
    }
}
