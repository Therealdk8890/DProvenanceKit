import Foundation

extension AlignmentFinding {
    public var categoryName: String {
        switch self {
        case .criticalStepRemoved: return "CriticalStepRemoved"
        case .criticalStepAdded: return "CriticalStepAdded"
        case .semanticEvolution: return "SemanticMatch"
        case .reorderedExecution: return "ReorderedExecution"
        case .ambiguityDetected: return "AmbiguityDetected"
        case .regressionRisk: return "RegressionRisk"
        }
    }
}
