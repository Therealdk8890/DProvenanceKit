import Foundation

public protocol FormalizationMapBuilder: Sendable {
    func build(from evidence: AlignmentEvidence) -> FormalizationMap
}

public struct DefaultFormalizationMapBuilder: FormalizationMapBuilder {
    public init() {}
    
    public func build(from evidence: AlignmentEvidence) -> FormalizationMap {
        return FormalizationMap(
            bindings: evidence.bindings,
            decisions: evidence.equivalenceDecisions,
            interpretations: evidence.interpretationSteps
        )
    }
}
