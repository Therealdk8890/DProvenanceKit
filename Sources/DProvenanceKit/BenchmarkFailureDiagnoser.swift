import Foundation

// MARK: - Failure Taxonomy

public enum SignalFailure: String, Sendable, Codable {
    case oversensitiveMatcher = "Oversensitive Matcher"
    case thresholdMiscalibration = "Threshold Miscalibration"
    case scoringInstability = "Scoring Instability"
}

public enum ModelFailure: String, Sendable, Codable {
    case missingEquivalenceRule = "Missing Equivalence Rule"
    case canonicalizationMismatch = "Canonicalization Mismatch"
    case semanticOvercollapse = "Semantic Overcollapse"
}

public enum SearchFailure: String, Sendable, Codable {
    case insufficientCandidates = "Insufficient Candidates"
    case candidateBias = "Candidate Bias"
}

public enum DataFailure: String, Sendable, Codable {
    case noiseMisclassification = "Noise Misclassification"
    case ambiguousGroundTruth = "Ambiguous Ground Truth"
    case mislabeledExpectation = "Mislabeled Expectation"
}

public struct FailureSeverityProfile: Sendable, Equatable {
    public let structuralImpact: Double // 0-1 (Does it break alignment logic?)
    public let propagationPotential: Double // 0-1 (Does it cascade into multiple failures?)
    public let recoverability: Double // 0-1 (Can downstream logic compensate? higher = less severe)
    
    public init(structuralImpact: Double, propagationPotential: Double, recoverability: Double) {
        self.structuralImpact = structuralImpact
        self.propagationPotential = propagationPotential
        self.recoverability = recoverability
    }
    
    public var score: Double {
        let w1 = 0.4
        let w2 = 0.4
        let w3 = 0.2
        return (w1 * structuralImpact) + (w2 * propagationPotential) + (w3 * (1.0 - recoverability))
    }
}

public enum FailureCause: Sendable, Equatable, Hashable {
    case signal(SignalFailure)
    case representation(ModelFailure)
    case search(SearchFailure)
    case data(DataFailure)
    case undiagnosed
    
    public var label: String {
        switch self {
        case .signal(let s): return "Signal: \(s.rawValue)"
        case .representation(let r): return "Representation: \(r.rawValue)"
        case .search(let s): return "Search: \(s.rawValue)"
        case .data(let d): return "Data: \(d.rawValue)"
        case .undiagnosed: return "Undiagnosed"
        }
    }
    
    public var severityProfile: FailureSeverityProfile {
        switch self {
        case .representation(.missingEquivalenceRule),
             .representation(.semanticOvercollapse):
            return FailureSeverityProfile(structuralImpact: 1.0, propagationPotential: 0.8, recoverability: 0.0)
        case .search(.insufficientCandidates):
            return FailureSeverityProfile(structuralImpact: 0.8, propagationPotential: 0.6, recoverability: 0.2)
        case .signal(.scoringInstability):
            return FailureSeverityProfile(structuralImpact: 0.6, propagationPotential: 0.9, recoverability: 0.3)
        case .signal(.thresholdMiscalibration),
             .search(.candidateBias):
            return FailureSeverityProfile(structuralImpact: 0.6, propagationPotential: 0.5, recoverability: 0.4)
        case .signal(.oversensitiveMatcher):
            return FailureSeverityProfile(structuralImpact: 0.5, propagationPotential: 0.4, recoverability: 0.5)
        case .representation(.canonicalizationMismatch):
            return FailureSeverityProfile(structuralImpact: 0.4, propagationPotential: 0.3, recoverability: 0.6)
        case .data(.mislabeledExpectation),
             .data(.ambiguousGroundTruth),
             .data(.noiseMisclassification):
            return FailureSeverityProfile(structuralImpact: 0.0, propagationPotential: 0.0, recoverability: 1.0)
        case .undiagnosed:
            return FailureSeverityProfile(structuralImpact: 0.1, propagationPotential: 0.1, recoverability: 0.5)
        }
    }
    
    public var severity: Double {
        return severityProfile.score
    }
}

// MARK: - Diagnosis Output

public struct DiagnosedFailure: Sendable, Equatable {
    public let finding: AlignmentFinding
    public let isFalsePositive: Bool // True if FP, False if FN
    public let isEngineError: Bool   // True if ground truth confidence was high
    
    public let hypothesizedCause: FailureCause
    public let diagnosisConfidence: Double // 0.0 - 1.0 (Probabilistic hypothesis)
    public let reason: String
    public let evidenceIDs: [UUID] // MetaEvent IDs
    
    public init(finding: AlignmentFinding, isFalsePositive: Bool, isEngineError: Bool, hypothesizedCause: FailureCause, diagnosisConfidence: Double, reason: String, evidenceIDs: [UUID]) {
        self.finding = finding
        self.isFalsePositive = isFalsePositive
        self.isEngineError = isEngineError
        
        // EVIDENCE RESTRICTION: No evidence, no claim.
        if evidenceIDs.isEmpty && hypothesizedCause != .undiagnosed {
            self.hypothesizedCause = .undiagnosed
            self.diagnosisConfidence = 0.0
            self.reason = "Unverifiable hypothesis (no evidence trace). Reverted to undiagnosed."
        } else {
            self.hypothesizedCause = hypothesizedCause
            self.diagnosisConfidence = diagnosisConfidence
            self.reason = reason
        }
        self.evidenceIDs = evidenceIDs
    }
    
    // Resolution boundary
    public func resolvedEvidence(in timeline: [DecisionTimelineEntry]) -> [DecisionTimelineEntry] {
        return timeline.filter { evidenceIDs.contains($0.id) }
    }
}

// MARK: - Diagnoser Heuristics

public struct BenchmarkFailureDiagnoser: Sendable {
    
    public init() {}
    
    public func diagnose<T: TraceableEvent>(
        falsePositives: [AlignmentFinding],
        falseNegatives: [ExpectedFinding],
        timeline: [DecisionTimelineEntry],
        alignmentResult: TraceAlignmentResult<T>
    ) -> [DiagnosedFailure] {
        
        var diagnoses: [DiagnosedFailure] = []

        // Findings are identified by semantic `typeIdentifier` (e.g. "tool"), but the meta-event
        // trace references events by their execution `sequence`. To join a finding back to the
        // trace, resolve every comparison sequence that carried the finding's type.
        func comparisonSequences(forType typeId: String) -> Set<UInt64> {
            var result = Set<UInt64>()
            for a in alignmentResult.alignments {
                if let comp = a.comparisonEvent, comp.payload.typeIdentifier == typeId {
                    result.insert(comp.sequence)
                }
            }
            return result
        }

        // Diagnose False Negatives (Engine missed something expected)
        for expected in falseNegatives {
            let isEngineError = expected.expectedConfidence >= 0.8
            
            var bestCause: FailureCause = .undiagnosed
            var confidence = 0.0
            var reason = "Could not infer cause from execution trace."
            var evidence: [UUID] = []
            
            switch expected.finding {
            case .semanticEvolution(_, let compId):
                // Did we reject a candidate?
                let compSeqs = comparisonSequences(forType: compId)
                let rejections = timeline.compactMap { e -> DecisionTimelineEntry? in
                    guard e.strengthCategory == .rejected, let meta = e.metaEvent else { return nil }
                    switch meta {
                    case .candidateEvicted(_, _, let compSeq, _), .ambiguityThresholdMet(_, _, let compSeq, _), .evaluatedPair(_, _, _, let compSeq, _):
                        return compSeqs.contains(compSeq) ? e : nil
                    default: return nil
                    }
                }
                if let rejection = rejections.first {
                    bestCause = .signal(.thresholdMiscalibration)
                    confidence = 0.85
                    reason = "A semantic candidate was found but evicted, suggesting the threshold is slightly too strict."
                    evidence.append(rejection.id)
                } else {
                    let evaluations = timeline.compactMap { e -> DecisionTimelineEntry? in
                        guard let meta = e.metaEvent else { return nil }
                        switch meta {
                        case .evaluatedPair(_, _, _, let compSeq, _):
                            return compSeqs.contains(compSeq) ? e : nil
                        default: return nil
                        }
                    }
                    if evaluations.isEmpty {
                        bestCause = .search(.insufficientCandidates)
                        confidence = 0.7
                        reason = "No candidates were even evaluated for \(compId). Search space failed to generate pairs."
                    } else {
                        bestCause = .representation(.missingEquivalenceRule)
                        confidence = 0.6
                        reason = "Evaluated candidates for \(compId) scored zero, meaning the evaluator lacked equivalence rules."
                        evidence.append(contentsOf: evaluations.map { $0.id })
                    }
                }
                
            case .criticalStepRemoved(let baseId):
                // If it was supposed to be removed but wasn't found as removed,
                // it implies we matched it when we shouldn't have?
                // Wait, if it's a false negative criticalStepRemoved, it means the dataset says it's removed,
                // but the engine actually aligned it. So the engine hallucinated a match.
                let matches = alignmentResult.alignments.compactMap { a in (a.state.isSemanticMatch || a.state.isExactMatch) ? a : nil }
                if let _ = matches.first(where: { $0.baseEvent?.payload.typeIdentifier == baseId }) {
                    bestCause = .signal(.oversensitiveMatcher)
                    confidence = 0.9
                    reason = "Engine aggressively aligned \(baseId) when it should have been considered removed."
                    // In a real system, we would link the timeline evaluation event here
                } else {
                    bestCause = .representation(.canonicalizationMismatch)
                    confidence = 0.5
                    reason = "Step was removed, but it was not flagged as critical. Priority definition might be mismatched."
                }
                
            default:
                break
            }
            
            diagnoses.append(DiagnosedFailure(
                finding: expected.finding,
                isFalsePositive: false,
                isEngineError: isEngineError,
                hypothesizedCause: bestCause,
                diagnosisConfidence: confidence,
                reason: reason,
                evidenceIDs: evidence
            ))
        }
        
        // Diagnose False Positives (Engine hallucinates a finding)
        for actual in falsePositives {
            // FP's assume the dataset didn't expect it, so expected confidence is effectively 0
            // but the engine generated it anyway. So isEngineError = true (engine hallucinated)
            
            var bestCause: FailureCause = .undiagnosed
            var confidence = 0.0
            var reason = "Unexpected finding with no clear causal misstep."
            var evidence: [UUID] = []
            
            switch actual {
            case .semanticEvolution(_, let compId):
                // We matched something we shouldn't have
                let compSeqs = comparisonSequences(forType: compId)
                let evals = timeline.compactMap { e -> DecisionTimelineEntry? in
                    guard e.strengthCategory != .rejected, let meta = e.metaEvent else { return nil }
                    switch meta {
                    case .evaluatedPair(_, _, _, let compSeq, _), .ambiguityThresholdMet(_, _, let compSeq, _):
                        return compSeqs.contains(compSeq) ? e : nil
                    default: return nil
                    }
                }
                if !evals.isEmpty {
                    bestCause = .signal(.oversensitiveMatcher)
                    confidence = 0.8
                    reason = "Semantic match passed threshold, but ground truth didn't expect it."
                    evidence.append(contentsOf: evals.map { $0.id })
                } else {
                    bestCause = .data(.noiseMisclassification)
                    confidence = 0.6
                    reason = "Unrelated event was coerced into a match."
                }

            case .reorderedExecution(_, _, let newSeq):
                // The reordered event's comparison position is `newSeq`; find the evaluation that
                // produced it. A reorder the ground truth didn't expect points at unstable
                // positional/temporal scoring.
                let evals = timeline.compactMap { e -> DecisionTimelineEntry? in
                    guard let meta = e.metaEvent else { return nil }
                    if case .evaluatedPair(_, _, _, let compSeq, _) = meta, compSeq == newSeq { return e }
                    return nil
                }
                bestCause = .signal(.scoringInstability)
                confidence = evals.isEmpty ? 0.5 : 0.7
                reason = "Engine reported a reordering the ground truth did not expect; positional scoring may be over-firing."
                evidence.append(contentsOf: evals.map { $0.id })

            case .ambiguityDetected:
                // A spurious ambiguity points at an over-permissive ambiguity threshold.
                let ambiguities = timeline.compactMap { e -> DecisionTimelineEntry? in
                    guard let meta = e.metaEvent else { return nil }
                    if case .ambiguityThresholdMet = meta { return e }
                    return nil
                }
                bestCause = .signal(.oversensitiveMatcher)
                confidence = ambiguities.isEmpty ? 0.5 : 0.65
                reason = "Engine flagged ambiguity the ground truth did not expect; the ambiguity threshold may be too permissive."
                evidence.append(contentsOf: ambiguities.map { $0.id })

            default:
                bestCause = .undiagnosed
                confidence = 0.0
                reason = "Not enough heuristics implemented for this FP."
            }
            
            diagnoses.append(DiagnosedFailure(
                finding: actual,
                isFalsePositive: true,
                isEngineError: true, 
                hypothesizedCause: bestCause,
                diagnosisConfidence: confidence,
                reason: reason,
                evidenceIDs: evidence
            ))
        }
        
        return diagnoses
    }
}
