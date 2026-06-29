#if os(macOS)
import SwiftUI
import DProvenanceKit

public struct MatrixCellData<T: TraceableEvent>: Identifiable {
    public let id = UUID()
    public let baseIndex: Int
    public let compIndex: Int
    public let baseEvent: TraceEvent<T>
    public let compEvent: TraceEvent<T>
    public let score: Double
    public let explanation: AlignmentExplanation
    public let isFinalMatch: Bool
}

@MainActor
public class AlignmentMatrixViewModel<T: TraceableEvent>: ObservableObject {
    @Published public var cells: [MatrixCellData<T>] = []
    @Published public var baseEvents: [TraceEvent<T>] = []
    @Published public var compEvents: [TraceEvent<T>] = []
    @Published public var result: TraceAlignmentResult<T>?
    
    @Published public var selectedCell: MatrixCellData<T>?
    
    @Published public var findings: [AlignmentFinding] = []
    @Published public var narrative: String = ""
    
    public init() {}
    
    public func load(
        engine: TraceAlignmentEngine<T>,
        base: TraceRun<T>,
        comparison: TraceRun<T>,
        minimumPriority: TracePriority = .structural
    ) {
        let bEvents = base.events.filter { $0.payload.priority >= minimumPriority }
        let cEvents = comparison.events.filter { $0.payload.priority >= minimumPriority }
        
        self.baseEvents = bEvents
        self.compEvents = cEvents
        
        // Calculate the actual result
        let alignmentResult = engine.align(base: base, comparison: comparison, minimumPriority: minimumPriority)
        self.result = alignmentResult
        
        let extractor = AlignmentFindingsExtractor<T>()
        let compiler = AlignmentNarrativeCompiler()
        let extractedFindings = extractor.extract(from: alignmentResult)
        
        self.findings = extractedFindings
        self.narrative = compiler.compile(from: extractedFindings)
        
        var newCells: [MatrixCellData<T>] = []
        
        for (i, b) in bEvents.enumerated() {
            for (j, c) in cEvents.enumerated() {
                let (score, explanation) = engine.evaluateScore(base: b, comparison: c)
                
                // Check if this was the final match
                var isMatch = false
                if let match = alignmentResult.alignments.first(where: {
                    $0.baseEvent?.sequence == b.sequence && $0.comparisonEvent?.sequence == c.sequence
                }) {
                    isMatch = !match.state.isRemoved
                }
                
                let cell = MatrixCellData(
                    baseIndex: i,
                    compIndex: j,
                    baseEvent: b,
                    compEvent: c,
                    score: score,
                    explanation: explanation,
                    isFinalMatch: isMatch
                )
                newCells.append(cell)
            }
        }
        
        self.cells = newCells
    }
}
#endif
