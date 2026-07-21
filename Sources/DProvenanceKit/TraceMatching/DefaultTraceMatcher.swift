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
        return DefaultTraceMatcher<U>.matchAndIndex(
            config: config,
            base: base,
            comparison: comparison,
            evidenceCollector: evidenceCollector
        ).bindings
    }

    /// One scan worker's output: candidate columns/scores for a contiguous run of base rows,
    /// plus per-row candidate counts so the rows stitch back together in order.
    private struct ScanChunk {
        var compIndices: [Int] = []
        var scores: [Double] = []
        var rowCounts: [Int] = []
    }

    /// Indexed result slots for the concurrent scan. Each worker writes its own slot, so the
    /// lock is contended `chunkCount` times in total — noise next to the scan itself.
    private final class ScanChunkSlots: @unchecked Sendable {
        private let lock = NSLock()
        private var slots: [ScanChunk?]
        init(count: Int) { slots = [ScanChunk?](repeating: nil, count: count) }
        func set(_ index: Int, _ chunk: ScanChunk) {
            lock.lock(); defer { lock.unlock() }
            slots[index] = chunk
        }
        func all() -> [ScanChunk?] {
            lock.lock(); defer { lock.unlock() }
            return slots
        }
    }

    /// The full matcher pass, additionally returning the candidate table so downstream passes
    /// (the interpreter's ambiguity rebuild) can reuse the scores instead of repeating the
    /// O(base × comparison) scan.
    ///
    /// `scanChunkCount` exists for tests (forcing the concurrent stitch path on small traces);
    /// production callers leave it nil and get one chunk per active core once the pair count
    /// is large enough to pay for the fan-out.
    internal static func matchAndIndex(
        config: AlignmentConfiguration<T>,
        base: [TraceEvent<T>],
        comparison: [TraceEvent<T>],
        evidenceCollector: EvidenceCollector,
        scanChunkCount: Int? = nil
    ) -> (bindings: [AlignmentBinding], candidates: AlignmentCandidateIndex) {
        // Score every candidate pair that clears the (per-base) ambiguity threshold, then assign
        // greedily HIGHEST SCORE FIRST. A purely base-order greedy match mis-pairs distinct
        // same-type events: e.g. it would bind an earlier base decision to the only comparison
        // decision and orphan its true identical counterpart. Global score-ordered assignment
        // ensures an exact/strong match always wins the binding over a weaker incidental one.
        //
        // The scan visits every base × comparison pair and dominates large-trace alignment, so
        // it runs with three exactness-preserving reductions:
        //  - `scoreOnly`, the allocation-free twin of `scoreMatch`;
        //  - type identifiers interned once per event (base + comparison calls instead of one
        //    per pair) and compared as integers — the same equivalence as string equality,
        //    given `TraceableEvent`'s stability requirement on `typeIdentifier`;
        //  - base rows partitioned into contiguous chunks scanned concurrently. Rows are
        //    independent (the evaluator is `@Sendable`, scoring is pure) and chunks stitch
        //    back in row order, so the candidate table is identical to a serial scan's.
        var internTable: [String: Int] = [:]
        func intern(_ identifier: String) -> Int {
            if let existing = internTable[identifier] { return existing }
            let next = internTable.count
            internTable[identifier] = next
            return next
        }
        let baseTypeIDs = base.map { intern($0.payload.typeIdentifier) }
        let compTypeIDs = comparison.map { intern($0.payload.typeIdentifier) }

        // Hoist every field the scoring touches into flat arrays: the inner loop then reads
        // arrays and calls the evaluator, instead of copying a whole generic `TraceEvent<T>`
        // per pair. In unspecialized generic code that per-pair copy costs metadata-driven
        // field extraction plus retain/release on the event's strings — and those atomic
        // refcounts are shared across scan threads, which serializes the fan-out.
        let basePayloads = base.map { $0.payload }
        let compPayloads = comparison.map { $0.payload }
        let baseSequences = base.map { $0.sequence }
        let compSequences = comparison.map { $0.sequence }
        let baseParentSpanIDs = base.map { $0.parentSpanID }
        let compParentSpanIDs = comparison.map { $0.parentSpanID }
        let profile = config.profile
        let evaluator = config.equivalenceEvaluator
        let comparisonCount = comparison.count

        @Sendable func scanRows(_ rows: Range<Int>) -> ScanChunk {
            var chunk = ScanChunk()
            chunk.rowCounts.reserveCapacity(rows.count)
            for i in rows {
                let bPayload = basePayloads[i]
                let bTypeID = baseTypeIDs[i]
                let bSequence = baseSequences[i]
                let bParentSpanID = baseParentSpanIDs[i]
                let threshold = evaluator.ambiguityThreshold(for: bPayload)
                let countBefore = chunk.compIndices.count
                for j in 0..<comparisonCount {
                    let payloadSim = evaluator.evaluateSimilarity(base: bPayload, comparison: compPayloads[j])
                    let score = profile.combinedScore(
                        typesEqual: bTypeID == compTypeIDs[j],
                        payloadSim: payloadSim,
                        baseParentSpanID: bParentSpanID,
                        compParentSpanID: compParentSpanIDs[j],
                        baseSequence: bSequence,
                        compSequence: compSequences[j]
                    )
                    if score >= threshold {
                        chunk.compIndices.append(j)
                        chunk.scores.append(score)
                    }
                }
                chunk.rowCounts.append(chunk.compIndices.count - countBefore)
            }
            return chunk
        }

        // Fan out only when the pair count is large enough to pay for it; below the cutoff a
        // single chunk keeps the scan on the calling thread. The output is the same either way.
        let pairCount = base.count.multipliedReportingOverflow(by: comparison.count)
        let scanIsLarge = pairCount.overflow || pairCount.partialValue >= 250_000
        let chunkCount = scanChunkCount.map { max(1, min($0, max(base.count, 1))) }
            ?? (scanIsLarge ? max(1, min(ProcessInfo.processInfo.activeProcessorCount, base.count)) : 1)

        let chunks: [ScanChunk]
        if chunkCount <= 1 {
            chunks = [scanRows(0..<base.count)]
        } else {
            let slots = ScanChunkSlots(count: chunkCount)
            DispatchQueue.concurrentPerform(iterations: chunkCount) { c in
                let lower = base.count * c / chunkCount
                let upper = base.count * (c + 1) / chunkCount
                slots.set(c, scanRows(lower..<upper))
            }
            // Every iteration filled its slot; a nil here is a logic error, and force-unwrapping
            // fails loudly rather than silently misaligning rowStart downstream.
            chunks = slots.all().map { $0! }
        }

        var index = AlignmentCandidateIndex()
        let totalCandidates = chunks.reduce(0) { $0 + $1.compIndices.count }
        index.compIndices.reserveCapacity(totalCandidates)
        index.scores.reserveCapacity(totalCandidates)
        index.rowStart.reserveCapacity(base.count + 1)
        index.rowStart.append(0)
        var runningTotal = 0
        for chunk in chunks {
            index.compIndices.append(contentsOf: chunk.compIndices)
            index.scores.append(contentsOf: chunk.scores)
            for rowCount in chunk.rowCounts {
                runningTotal += rowCount
                index.rowStart.append(runningTotal)
            }
        }

        var candidates: [(baseIdx: Int, compIdx: Int, score: Double)] = []
        candidates.reserveCapacity(index.compIndices.count)
        for i in 0..<base.count {
            for k in index.rowStart[i]..<index.rowStart[i + 1] {
                candidates.append((baseIdx: i, compIdx: index.compIndices[k], score: index.scores[k]))
            }
        }

        // Deterministic ordering: by score desc, then base index, then comparison index.
        candidates.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.baseIdx != b.baseIdx { return a.baseIdx < b.baseIdx }
            return a.compIdx < b.compIdx
        }

        var bindings: [AlignmentBinding] = []
        var usedBaseIndices = [Bool](repeating: false, count: base.count)
        var usedComparisonIndices = [Bool](repeating: false, count: comparison.count)
        for cand in candidates {
            if usedBaseIndices[cand.baseIdx] || usedComparisonIndices[cand.compIdx] { continue }
            usedBaseIndices[cand.baseIdx] = true
            usedComparisonIndices[cand.compIdx] = true

            let bEvent = base[cand.baseIdx]
            let cEvent = comparison[cand.compIdx]
            bindings.append(AlignmentBinding(baseEventID: bEvent.id, comparisonEventID: cEvent.id, similarityScore: cand.score))
            evidenceCollector.recordBinding(BindingDecision(
                baseID: bEvent.id.uuidString,
                comparisonID: cEvent.id.uuidString,
                similarityScore: cand.score
            ))
        }

        return (bindings, index)
    }
}
