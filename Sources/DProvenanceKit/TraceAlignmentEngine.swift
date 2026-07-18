import Foundation

public enum VerificationCaptureMode: Sendable {
    case disabled
    case evidenceOnly
}

public struct TraceAlignmentEngine<T: TraceableEvent>: Sendable {
    
    public let configuration: AlignmentConfiguration<T>
    public let metaTraceCallback: (@Sendable (TraceEvent<AlignmentMetaEvent>) -> Void)?
    public let captureMode: VerificationCaptureMode
    
    private let semantics: DefaultEquivalenceModel<T>
    private let interpreter: DefaultAlignmentInterpreter<T>

    public init(
        configuration: AlignmentConfiguration<T>,
        captureMode: VerificationCaptureMode = .disabled,
        metaTraceCallback: (@Sendable (TraceEvent<AlignmentMetaEvent>) -> Void)? = nil
    ) {
        self.configuration = configuration
        self.captureMode = captureMode
        self.metaTraceCallback = metaTraceCallback
        self.semantics = DefaultEquivalenceModel(configuration: configuration)
        self.interpreter = DefaultAlignmentInterpreter(configuration: configuration, metaTraceCallback: metaTraceCallback)
    }
    
    public func align(
        base: TraceRun<T>,
        comparison: TraceRun<T>,
        minimumPriority: TracePriority = .structural
    ) -> TraceAlignmentResult<T> {
        let baseEvents = base.events.filter { $0.payload.priority >= minimumPriority }
        let compEvents = comparison.events.filter { $0.payload.priority >= minimumPriority }
        
        let collector: EvidenceCollector = (captureMode == .evidenceOnly) ? AlignmentEvidenceCollector() : NullEvidenceCollector()

        let (bindings, candidateIndex) = DefaultTraceMatcher<T>.matchAndIndex(
            config: configuration,
            base: baseEvents,
            comparison: compEvents,
            evidenceCollector: collector
        )

        let alignments: [EventAlignment<T>]
        if collector is NullEvidenceCollector {
            // No evidence artifact is being built, so there are no collector side effects to
            // preserve and the interpreter can reuse the matcher's candidate table instead of
            // re-scoring every base × comparison pair. Identical output by construction — see
            // `interpretWithCandidates` and AlignmentFastPathParityTests.
            alignments = interpreter.interpretWithCandidates(
                base: baseEvents,
                comparison: compEvents,
                bindings: bindings,
                candidates: candidateIndex
            )
        } else {
            alignments = interpreter.interpret(
                base: baseEvents,
                comparison: compEvents,
                bindings: bindings,
                equivalence: { a, b in semantics.evaluate(a, b, evidenceCollector: collector) },
                evidenceCollector: collector
            )
        }
        
        // Pass 4: Regression Risk Analysis.
        //
        // SEMANTICS.md Def 5 / Invariant A/E: a critical reference step is a regression when it
        // is NOT mapped to an equivalent counterpart in causal order. Three ways that happens:
        //   1. removed — no counterpart at all;
        //   2. reordered — its causal order versus another CRITICAL step inverted;
        //   3. changed — bound to a counterpart the equivalence model rejected (score below the
        //      profile's semanticThreshold and payloads differ).
        //
        // This is derived HERE, from the equivalence outcome and critical-only order, rather
        // than only from the interpreter's coarse display states. Earlier this pass read only
        // `.removed`/`.reordered`; but a materially changed critical binds to a same-type event
        // (type match alone clears the matcher's threshold) and is filed `.ambiguous`, which
        // never surfaced — so a tampered/skipped critical step escaped the risk verdict entirely.
        // Reorder is computed over critical pairs only, so a benign structural/diagnostic step
        // moving past a stationary critical no longer fires a false HIGH.
        let threshold = configuration.profile.semanticThreshold
        var removedCriticalTypes: [String] = []
        var changedCriticalTypes: [String] = []
        // (baseIdx, compIdx) of each matched CRITICAL pair, using the SAME array-index basis
        // the interpreter uses to assign `.reordered` (see DefaultAlignmentInterpreter's
        // matchedPairs). Deriving the verdict from the same positions the emitted
        // `.reorderedExecution` findings use guarantees the two can never disagree about
        // whether — or where — a reorder happened. `TraceRun` normalizes its events to
        // ascending `sequence` at construction, so for engine inputs this index basis and
        // the authoritative sequence order coincide.
        var criticalPairs: [(baseIdx: Int, compIdx: Int, type: String)] = []
        var baseIndexByID = [UUID: Int](minimumCapacity: baseEvents.count)
        for (i, event) in baseEvents.enumerated() where baseIndexByID[event.id] == nil {
            baseIndexByID[event.id] = i
        }
        var compIndexByID = [UUID: Int](minimumCapacity: compEvents.count)
        for (j, event) in compEvents.enumerated() where compIndexByID[event.id] == nil {
            compIndexByID[event.id] = j
        }
        for alignment in alignments {
            guard let b = alignment.baseEvent, b.payload.priority == .critical else { continue }
            guard let c = alignment.comparisonEvent else {
                removedCriticalTypes.append(b.payload.typeIdentifier)
                continue
            }
            // Identical payloads are equivalent by construction; otherwise consult the same
            // score the matcher/equivalence model used. Below the threshold ⇒ not equivalent.
            if b.payload != c.payload {
                let (score, _) = configuration.scoreMatch(base: b, comp: c)
                if score < threshold { changedCriticalTypes.append(b.payload.typeIdentifier) }
            }
            if let baseIdx = baseIndexByID[b.id], let compIdx = compIndexByID[c.id] {
                criticalPairs.append((baseIdx, compIdx, b.payload.typeIdentifier))
            }
        }
        // Causal-order inversion between two CRITICAL steps: x precedes y in the base but
        // follows it in the comparison. Restricting to critical pairs means a benign
        // structural/diagnostic step moving past a stationary critical is not a regression
        // (that produced a false HIGH); non-critical reorders still surface as `.reordered`
        // findings for display, they just don't drive the risk verdict.
        //
        // Linear-scan form of the original all-pairs check, flagging exactly the same pairs:
        // x is flagged iff some pair with a strictly greater base index has a strictly
        // smaller comparison index, i.e. the suffix minimum of comparison indices over
        // strictly-greater base indices undercuts x's comparison index. Flagged types are
        // emitted in the original `criticalPairs` order so the verdict string is unchanged.
        var reorderedCriticalTypes: [String] = []
        if !criticalPairs.isEmpty {
            let byBaseIdx = criticalPairs.indices.sorted { criticalPairs[$0].baseIdx < criticalPairs[$1].baseIdx }
            var flagged = [Bool](repeating: false, count: criticalPairs.count)
            var suffixMin = Int.max
            var upper = byBaseIdx.count - 1
            while upper >= 0 {
                // Pairs tied on baseIdx form one group: "strictly greater" excludes the group
                // itself, so the group is flagged against the suffix minimum beyond it before
                // its own comparison indices join that minimum.
                var lower = upper
                let groupBaseIdx = criticalPairs[byBaseIdx[upper]].baseIdx
                while lower > 0 && criticalPairs[byBaseIdx[lower - 1]].baseIdx == groupBaseIdx {
                    lower -= 1
                }
                for g in lower...upper where suffixMin < criticalPairs[byBaseIdx[g]].compIdx {
                    flagged[byBaseIdx[g]] = true
                }
                for g in lower...upper {
                    suffixMin = Swift.min(suffixMin, criticalPairs[byBaseIdx[g]].compIdx)
                }
                upper = lower - 1
            }
            for (idx, pair) in criticalPairs.enumerated() where flagged[idx] {
                reorderedCriticalTypes.append(pair.type)
            }
        }

        let risk: RegressionRisk
        if !removedCriticalTypes.isEmpty {
            risk = RegressionRisk(level: .high, strength: 0.95, reasoning: "Critical reasoning steps removed: \(removedCriticalTypes.joined(separator: ", "))")
        } else if !reorderedCriticalTypes.isEmpty {
            risk = RegressionRisk(level: .high, strength: 1.0, reasoning: "Critical reasoning steps reordered: \(reorderedCriticalTypes.joined(separator: ", "))")
        } else if !changedCriticalTypes.isEmpty {
            risk = RegressionRisk(level: .high, strength: 0.9, reasoning: "Critical reasoning steps changed beyond equivalence: \(changedCriticalTypes.joined(separator: ", "))")
        } else {
            risk = RegressionRisk(level: .none, strength: 1.0, reasoning: "No critical steps removed, reordered, or materially changed.")
        }
        
        var vArtifacts: VerificationArtifacts? = nil
        if let alignmentCollector = collector as? AlignmentEvidenceCollector {
            vArtifacts = VerificationArtifacts(evidence: alignmentCollector.exportEvidence())
        }
        
        return TraceAlignmentResult(
            baseRunID: base.runID,
            comparisonRunID: comparison.runID,
            profileHash: configuration.profileHash,
            engineVersion: "v2-causal-strict",
            alignments: alignments,
            regressionRisk: risk,
            verificationArtifacts: vArtifacts
        )
    }
    
    public func evaluateScore(base: TraceEvent<T>, comparison: TraceEvent<T>) -> (Double, AlignmentExplanation) {
        return configuration.scoreMatch(base: base, comp: comparison)
    }
}

extension AlignmentConfiguration {
    /// Allocation-free twin of `scoreMatch` for the matcher's O(base × comparison) candidate
    /// scan, where only the score participates in any decision. Delegates to
    /// `AlignmentProfile.combinedScore` — the single specialized home of the scan arithmetic.
    /// AlignmentFastPathParityTests holds this bit-identical to `scoreMatch`.
    internal func scoreOnly(base: TraceEvent<T>, comp: TraceEvent<T>) -> Double {
        profile.combinedScore(
            typesEqual: base.payload.typeIdentifier == comp.payload.typeIdentifier,
            payloadSim: equivalenceEvaluator.evaluateSimilarity(base: base.payload, comparison: comp.payload),
            baseParentSpanID: base.parentSpanID,
            compParentSpanID: comp.parentSpanID,
            baseSequence: base.sequence,
            compSequence: comp.sequence
        )
    }

    /// Scoring arithmetic is mirrored by `AlignmentProfile.combinedScore` (the matcher scan's
    /// allocation-free form) — any change here must be made there too, with the contributions
    /// accumulated in the same order so the two stay bit-identical.
    internal func scoreMatch(base: TraceEvent<T>, comp: TraceEvent<T>) -> (Double, AlignmentExplanation) {
        var score = 0.0
        var evidence: [HeuristicEvidence] = []
        var primaryReasonStr = ""
        
        // 1. Type Match
        let typeSim = (base.payload.typeIdentifier == comp.payload.typeIdentifier) ? 1.0 : 0.0
        let typeContribution = typeSim * profile.typeWeight
        score += typeContribution
        if typeContribution > 0 {
            evidence.append(HeuristicEvidence(category: .typeMatch, scoreContribution: typeContribution, description: "Type match (\(base.payload.typeIdentifier))"))
            primaryReasonStr = "Exact Type Match"
        }
        
        // 2. Payload Similarity
        let payloadSim = equivalenceEvaluator.evaluateSimilarity(base: base.payload, comparison: comp.payload)
        let payloadContribution = payloadSim * profile.payloadWeight
        score += payloadContribution
        if payloadContribution > 0 {
            evidence.append(HeuristicEvidence(category: .payloadSimilarity, scoreContribution: payloadContribution, description: "Semantic equivalence score: \(String(format: "%.2f", payloadSim))"))
            if primaryReasonStr.isEmpty {
                primaryReasonStr = "Semantic Payload Match"
            }
        }
        
        // 3. Structural Context (Span Awareness)
        var structuralSim = 0.0
        if profile.alignmentMode != .linear {
            if base.parentSpanID == comp.parentSpanID && base.parentSpanID != nil {
                structuralSim = 1.0
            } else if base.parentSpanID == nil && comp.parentSpanID == nil {
                structuralSim = 1.0
            }
        }
        let structuralContribution = structuralSim * profile.structuralWeight
        score += structuralContribution
        if structuralContribution > 0 {
            evidence.append(HeuristicEvidence(category: .structuralContext, scoreContribution: structuralContribution, description: "Parent span matched"))
        }
        
        // 4. Temporal Locality (rough heuristic based on sequence index distance)
        let seqDiff = abs(Int(base.sequence) - Int(comp.sequence))
        let tempSim = max(0.0, 1.0 - (Double(seqDiff) / 10.0))
        let tempContribution = tempSim * profile.temporalWeight
        score += tempContribution
        if tempContribution > 0 {
            evidence.append(HeuristicEvidence(category: .temporalLocality, scoreContribution: tempContribution, description: "Temporal locality (+/-\(seqDiff) events)"))
        }
        
        if primaryReasonStr.isEmpty { primaryReasonStr = "Low Confidence Match" }
        
        let explanation = AlignmentExplanation(primaryReason: primaryReasonStr, finalScore: score, rankedEvidence: evidence)
        return (score, explanation)
    }
}
