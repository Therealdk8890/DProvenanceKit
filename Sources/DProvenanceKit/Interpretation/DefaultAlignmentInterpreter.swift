import Foundation

public struct DefaultAlignmentInterpreter<T: TraceableEvent>: AlignmentInterpreter {
    public let configuration: AlignmentConfiguration<T>
    public let metaTraceCallback: (@Sendable (TraceEvent<AlignmentMetaEvent>) -> Void)?
    
    public init(configuration: AlignmentConfiguration<T>, metaTraceCallback: (@Sendable (TraceEvent<AlignmentMetaEvent>) -> Void)? = nil) {
        self.configuration = configuration
        self.metaTraceCallback = metaTraceCallback
    }
    
    public func interpret<U: TraceableEvent>(
        base: [TraceEvent<U>],
        comparison: [TraceEvent<U>],
        bindings: [AlignmentBinding],
        equivalence: (TraceEvent<U>, TraceEvent<U>) -> EquivalenceDecision,
        evidenceCollector: EvidenceCollector
    ) -> [EventAlignment<U>] {
        guard let config = configuration as? AlignmentConfiguration<U> else { return [] }
        
        var alignments: [EventAlignment<U>] = []
        var usedComparisonIndices = Set<Int>()
        var usedBaseIndices = Set<Int>()
        
        // Convert bindings to a dictionary for quick lookup by base event ID
        let bindingMap = Dictionary(uniqueKeysWithValues: bindings.map { ($0.baseEventID, $0) })

        // Emit the meta-event decision trace consumed by the timeline / diagnoser. The modular
        // engine records structured evidence (for fidelity) AND this observable meta-trace (for
        // diagnosis), the latter keyed by execution sequence numbers.
        let metaRunID = UUID()
        var metaSequence: UInt64 = 0
        func emitMeta(_ payload: AlignmentMetaEvent) {
            guard let callback = metaTraceCallback else { return }
            let event = TraceEvent(
                runID: metaRunID,
                contextID: "alignmentEngine",
                engineName: "TraceAlignmentEngine",
                schemaVersion: 1,
                sequence: metaSequence,
                spanID: nil,
                parentSpanID: nil,
                payload: payload,
                timestamp: Date()
            )
            metaSequence += 1
            callback(event)
        }

        // Relative-order reorder detection. A matched event is "reordered" only if its position
        // RELATIVE to the other matched events changed — i.e. it forms an inversion in the
        // matched-pair ordering. This avoids falsely flagging events whose absolute index merely
        // shifted because other events were inserted or removed around them.
        var matchedPairs: [(baseIdx: Int, compIdx: Int, baseID: UUID)] = []
        for (i, bEvent) in base.enumerated() {
            if let binding = bindingMap[bEvent.id],
               let compIdx = comparison.firstIndex(where: { $0.id == binding.comparisonEventID }) {
                matchedPairs.append((i, compIdx, bEvent.id))
            }
        }
        var reorderedBaseIDs = Set<UUID>()
        for a in matchedPairs {
            for b in matchedPairs where a.baseID != b.baseID {
                if a.baseIdx < b.baseIdx && a.compIdx > b.compIdx {
                    reorderedBaseIDs.insert(a.baseID)
                    reorderedBaseIDs.insert(b.baseID)
                }
            }
        }

        // Comparison events that the matcher already bound to some base event. These are NOT
        // valid ambiguous alternatives for a different base: a comp that has its own (better)
        // match is not a competing candidate. Excluding them prevents spurious ambiguity findings
        // when two distinct same-type events incidentally score within the ambiguity delta.
        let boundComparisonIndices = Set(matchedPairs.map { $0.compIdx })

        for (i, bEvent) in base.enumerated() {
            var ambiguousOptions: [AmbiguousMatch<U>] = []
            
            if let binding = bindingMap[bEvent.id], let matchIdx = comparison.firstIndex(where: { $0.id == binding.comparisonEventID }) {
                
                let cEvent = comparison[matchIdx]
                let score = binding.similarityScore
                // Re-run equivalence for its side effect — it records match evidence
                // into the injected evidenceCollector. The returned decision is unused
                // here (the score comes from the binding above).
                _ = equivalence(bEvent, cEvent)
                let (_, explanation) = config.scoreMatch(base: bEvent, comp: cEvent)

                // Record the matched pair as an evaluated decision in the meta-trace.
                emitMeta(.evaluatedPair(
                    causalParentID: nil,
                    decisionNodeID: UUID().uuidString,
                    baseSequence: bEvent.sequence,
                    compSequence: cEvent.sequence,
                    score: score
                ))
                
                // For a 100% faithful port of the exact semantic matches, we'd need to re-evaluate ambiguity
                // here or have the matcher provide it. For Phase 3, we just rely on the equivalence evaluator directly
                // to rebuild the ambiguous list just like the legacy engine.
                // Rebuilding exactly:
                let ambiguityThreshold = config.equivalenceEvaluator.ambiguityThreshold(for: bEvent.payload)
                let bestExplanation = explanation
                
                for (j, compEvent) in comparison.enumerated() {
                    if j == matchIdx { continue } // Skip the actual match
                    if usedComparisonIndices.contains(j) { continue }
                    
                    let decisionJ = equivalence(bEvent, compEvent)
                    let jScore = decisionJ.confidence
                    let (_, jExplanation) = config.scoreMatch(base: bEvent, comp: compEvent)
                    if jScore >= ambiguityThreshold && !boundComparisonIndices.contains(j) {
                        let delta = score - jScore
                        if delta <= config.profile.ambiguityDeltaThreshold {
                            ambiguousOptions.append(AmbiguousMatch(event: compEvent, strength: jScore, explanation: jExplanation))
                            emitMeta(.ambiguityThresholdMet(
                                causalParentID: nil,
                                decisionNodeID: UUID().uuidString,
                                compSequence: compEvent.sequence,
                                score: jScore
                            ))
                        }
                    }
                }
                
                ambiguousOptions = AlignmentExecutionContract.canonicalSort(ambiguity: ambiguousOptions)
                
                let state: AlignmentState
                
                if score < config.profile.semanticThreshold || !ambiguousOptions.isEmpty {
                    ambiguousOptions.append(AmbiguousMatch(event: cEvent, strength: score, explanation: bestExplanation))
                    ambiguousOptions = AlignmentExecutionContract.canonicalSort(ambiguity: ambiguousOptions)
                    
                    if ambiguousOptions.count > config.profile.maxAmbiguousCandidates {
                        ambiguousOptions = Array(ambiguousOptions.prefix(config.profile.maxAmbiguousCandidates))
                    }
                    
                    state = .ambiguous(optionsCount: ambiguousOptions.count)
                    usedComparisonIndices.insert(matchIdx)
                    usedBaseIndices.insert(i)
                } else {
                    usedComparisonIndices.insert(matchIdx)
                    usedBaseIndices.insert(i)

                    let isReordered = config.profile.alignmentMode != .linear && reorderedBaseIDs.contains(bEvent.id)
                    if isReordered {
                        // Relative execution order changed — dominant signal regardless of payload.
                        state = .reordered(originalSequence: bEvent.sequence, newSequence: cEvent.sequence)
                    } else if bEvent.payload == cEvent.payload {
                        // Semantically identical and in the same relative position => exact match.
                        // Identity is decided by payload equality, not by the weighted score, so a
                        // structural/temporal penalty can no longer demote an identical event to a
                        // spurious "semantic evolution".
                        state = .exactMatch
                    } else {
                        state = .semanticMatch(strength: score)
                    }
                }
                
                alignments.append(EventAlignment(state: state, baseEvent: bEvent, comparisonEvent: cEvent, explanation: bestExplanation, ambiguousCandidates: ambiguousOptions))
                
                evidenceCollector.recordInterpretation(InterpretationStep(
                    sourceBinding: binding,
                    baseID: bEvent.id.uuidString,
                    comparisonID: cEvent.id.uuidString,
                    outputState: String(describing: state),
                    rationale: bestExplanation.primaryReason,
                    baseSequence: bEvent.sequence,
                    comparisonSequence: cEvent.sequence
                ))
            } else {
                alignments.append(EventAlignment(state: .removed, baseEvent: bEvent, comparisonEvent: nil, explanation: .none))

                evidenceCollector.recordInterpretation(InterpretationStep(
                    sourceBinding: nil,
                    baseID: bEvent.id.uuidString,
                    comparisonID: nil,
                    outputState: "removed",
                    rationale: "No matching candidate found above threshold.",
                    baseSequence: bEvent.sequence,
                    comparisonSequence: nil
                ))
            }
        }
        
        for (j, cEvent) in comparison.enumerated() {
            if !usedComparisonIndices.contains(j) {
                alignments.append(EventAlignment(state: .added, baseEvent: nil, comparisonEvent: cEvent, explanation: .none))
                
                evidenceCollector.recordInterpretation(InterpretationStep(
                    sourceBinding: nil,
                    baseID: nil,
                    comparisonID: cEvent.id.uuidString,
                    outputState: "added",
                    rationale: "Candidate event unassigned to any base event.",
                    baseSequence: nil,
                    comparisonSequence: cEvent.sequence
                ))
            }
        }
        
        return AlignmentExecutionContract.canonicalSort(alignments: alignments)
    }
}
