import Foundation

public enum VerificationCaptureMode: Sendable {
    case disabled
    case evidenceOnly
}

public struct TraceAlignmentEngine<T: TraceableEvent>: Sendable {
    
    public let configuration: AlignmentConfiguration<T>
    public let metaTraceCallback: (@Sendable (TraceEvent<AlignmentMetaEvent>) -> Void)?
    public let captureMode: VerificationCaptureMode
    
    private let matcher: TraceMatcher
    private let semantics: EquivalenceModel
    private let interpreter: AlignmentInterpreter
    
    public init(
        configuration: AlignmentConfiguration<T>,
        captureMode: VerificationCaptureMode = .disabled,
        metaTraceCallback: (@Sendable (TraceEvent<AlignmentMetaEvent>) -> Void)? = nil
    ) {
        self.configuration = configuration
        self.captureMode = captureMode
        self.metaTraceCallback = metaTraceCallback
        self.matcher = DefaultTraceMatcher(configuration: configuration)
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
        
        let bindings = matcher.match(base: baseEvents, comparison: compEvents, evidenceCollector: collector)
        
        let alignments = interpreter.interpret(
            base: baseEvents,
            comparison: compEvents,
            bindings: bindings,
            equivalence: { a, b in semantics.evaluate(a, b, evidenceCollector: collector) },
            evidenceCollector: collector
        )
        
        // Pass 4: Regression Risk Analysis (carried over from legacy for now until it's also separated).
        // Two failure modes degrade a critical reasoning step: removing it, or reordering it.
        // Reordering critical steps can invert a dependency (e.g. GenerateInvoice before
        // CreateCustomer). The engine has no dependency graph, so this is critical-*order*
        // sensitivity, not true dependency inference; it fires only on .critical steps so that
        // reordering of structural/diagnostic steps (the common, benign case) stays .none.
        let removedCritical = alignments.filter { $0.state.isRemoved && $0.baseEvent?.payload.priority == .critical }
        let reorderedCritical = alignments.filter { $0.state.isReordered && $0.baseEvent?.payload.priority == .critical }
        let risk: RegressionRisk
        if !removedCritical.isEmpty {
            let criticalTypes = removedCritical.compactMap { $0.baseEvent?.payload.typeIdentifier }.joined(separator: ", ")
            risk = RegressionRisk(level: .high, strength: 0.95, reasoning: "Critical reasoning steps removed: \(criticalTypes)")
        } else if !reorderedCritical.isEmpty {
            let reorderedTypes = reorderedCritical.compactMap { $0.baseEvent?.payload.typeIdentifier }.joined(separator: ", ")
            risk = RegressionRisk(level: .high, strength: 1.0, reasoning: "Critical reasoning steps reordered: \(reorderedTypes)")
        } else {
            risk = RegressionRisk(level: .none, strength: 1.0, reasoning: "No critical steps removed or reordered.")
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
