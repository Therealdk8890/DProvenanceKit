import Foundation

public struct InterpretationStep: Sendable {
    public let sourceBinding: AlignmentBinding?
    public let baseID: String?
    public let comparisonID: String?
    public let outputState: String // Or AlignmentState if it is easily serializable
    public let rationale: String

    /// Execution-order anchors for the base and comparison events this step interprets.
    /// These let the causal-ordering invariant verify that aligned pairs preserve the
    /// relative execution order of the two traces, rather than inspecting a state label.
    public let baseSequence: UInt64?
    public let comparisonSequence: UInt64?

    public init(
        sourceBinding: AlignmentBinding?,
        baseID: String?,
        comparisonID: String?,
        outputState: String,
        rationale: String,
        baseSequence: UInt64? = nil,
        comparisonSequence: UInt64? = nil
    ) {
        self.sourceBinding = sourceBinding
        self.baseID = baseID
        self.comparisonID = comparisonID
        self.outputState = outputState
        self.rationale = rationale
        self.baseSequence = baseSequence
        self.comparisonSequence = comparisonSequence
    }
}
