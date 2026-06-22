import Foundation

public struct AlignmentFindingsExtractor<T: TraceableEvent>: Sendable {
    
    public init() {}
    
    public func extract(from result: TraceAlignmentResult<T>) -> [AlignmentFinding] {
        var findings: [AlignmentFinding] = []

        // 1. Regression Risk
        if result.regressionRisk.level != .none {
            findings.append(.regressionRisk(result.regressionRisk))
        }

        // 2. Iterate alignments for specific findings.
        //    Findings are identified by the event's semantic `typeIdentifier`. This is the
        //    stable, human-authorable identity that benchmark ground truth is written against
        //    (e.g. "tool", "decision"). The raw execution `sequence` is NOT used as the finding
        //    identity because it is positional and brittle (any reordering changes it); sequence
        //    is instead carried through the meta-event trace for diagnosis/fidelity joins.
        for alignment in result.alignments {
            switch alignment.state {
            case .removed:
                if let base = alignment.baseEvent {
                    if base.payload.priority == .critical {
                        findings.append(.criticalStepRemoved(baseEventIdentifier: base.payload.typeIdentifier))
                    }
                }
            case .added:
                if let comp = alignment.comparisonEvent {
                    if comp.payload.priority == .critical {
                        findings.append(.criticalStepAdded(compEventIdentifier: comp.payload.typeIdentifier))
                    }
                }
            case .reordered(let orig, let new):
                if let base = alignment.baseEvent {
                    findings.append(.reorderedExecution(eventIdentifier: base.payload.typeIdentifier, originalSequence: orig, newSequence: new))
                }
            case .semanticMatch:
                if let base = alignment.baseEvent, let comp = alignment.comparisonEvent {
                    findings.append(.semanticEvolution(baseIdentifier: base.payload.typeIdentifier, compIdentifier: comp.payload.typeIdentifier))
                }
            case .exactMatch:
                break // Normal, no finding needed
            case .ambiguous(let count):
                if let base = alignment.baseEvent {
                    findings.append(.ambiguityDetected(eventIdentifier: base.payload.typeIdentifier, optionsCount: count))
                }
            }
        }

        return findings
    }
}
