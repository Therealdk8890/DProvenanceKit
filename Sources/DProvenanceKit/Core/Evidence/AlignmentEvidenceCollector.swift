import Foundation

public final class AlignmentEvidenceCollector: EvidenceCollector, @unchecked Sendable {
    private let lock = NSLock()
    
    private var bindings: [BindingDecision] = []
    private var equivalenceDecisions: [EquivalenceDecisionRecord] = []
    private var interpretationSteps: [InterpretationStep] = []
    
    public init() {}
    
    public func recordBinding(_ decision: BindingDecision) {
        lock.lock()
        bindings.append(decision)
        lock.unlock()
    }
    
    public func recordEquivalence(_ record: EquivalenceDecisionRecord) {
        lock.lock()
        equivalenceDecisions.append(record)
        lock.unlock()
    }
    
    public func recordInterpretation(_ step: InterpretationStep) {
        lock.lock()
        interpretationSteps.append(step)
        lock.unlock()
    }
    
    public func exportEvidence() -> AlignmentEvidence {
        lock.lock()
        defer { lock.unlock() }
        return AlignmentEvidence(
            bindings: bindings,
            equivalenceDecisions: equivalenceDecisions,
            interpretationSteps: interpretationSteps
        )
    }
}
