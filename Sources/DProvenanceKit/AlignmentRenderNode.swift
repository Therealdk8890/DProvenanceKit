import Foundation

public enum RenderHint: String, Sendable, Equatable {
    case success
    case warning
    case danger
    case info
    case neutral
}

public struct AlignmentRenderNode: Sendable, Identifiable {
    public let id: String
    public let baseSequence: UInt64?
    public let comparisonSequence: UInt64?
    public let typeIdentifier: String
    public let renderHint: RenderHint
    public let primaryExplanation: String
    public let hasDetailedEvidence: Bool
    public let ambiguousAlternatives: Int
    
    public init(id: String, baseSequence: UInt64?, comparisonSequence: UInt64?, typeIdentifier: String, renderHint: RenderHint, primaryExplanation: String, hasDetailedEvidence: Bool, ambiguousAlternatives: Int) {
        self.id = id
        self.baseSequence = baseSequence
        self.comparisonSequence = comparisonSequence
        self.typeIdentifier = typeIdentifier
        self.renderHint = renderHint
        self.primaryExplanation = primaryExplanation
        self.hasDetailedEvidence = hasDetailedEvidence
        self.ambiguousAlternatives = ambiguousAlternatives
    }
    
    /// Deterministic string serialization for snapshot hashing.
    /// Format ensures strict stable ordering and no floating point instability.
    public var canonicalSerialization: String {
        return "[\(baseSequence.map { String($0) } ?? "nil")->\(comparisonSequence.map { String($0) } ?? "nil")]|\(typeIdentifier)|\(renderHint.rawValue)|\(ambiguousAlternatives)|\(hasDetailedEvidence)|\(primaryExplanation)"
    }
}

public extension TraceAlignmentResult {
    /// Compiles the complex alignment graph into a flat, UI-ready list.
    /// This is a pure function that is deterministic and cacheable.
    func renderModels() -> [AlignmentRenderNode] {
        return alignments.map { alignment in
            let id = UUID().uuidString // Since we want stable UI, we ideally use underlying UUIDs
            let baseSeq = alignment.baseEvent?.sequence
            let compSeq = alignment.comparisonEvent?.sequence
            let typeId = alignment.baseEvent?.payload.typeIdentifier ?? alignment.comparisonEvent?.payload.typeIdentifier ?? "unknown"
            
            let hint: RenderHint
            let explanationStr: String
            
            switch alignment.state {
            case .exactMatch:
                hint = .success
                explanationStr = "Exact match"
            case .semanticMatch(let conf):
                hint = .info
                explanationStr = "Semantic match (\(Int(conf * 100))%) - \(alignment.explanation.primaryReason)"
            case .reordered(_, _):
                hint = .warning
                explanationStr = "Reordered"
            case .ambiguous(let count):
                hint = .warning
                explanationStr = "Ambiguous match (\(count) possibilities)"
            case .added:
                hint = .success
                explanationStr = "Added in new version"
            case .removed:
                hint = .danger
                explanationStr = "Removed in new version"
            }
            
            let nodeID = alignment.baseEvent?.id.uuidString ?? alignment.comparisonEvent?.id.uuidString ?? id
            
            return AlignmentRenderNode(
                id: nodeID,
                baseSequence: baseSeq,
                comparisonSequence: compSeq,
                typeIdentifier: typeId,
                renderHint: hint,
                primaryExplanation: explanationStr,
                hasDetailedEvidence: !alignment.explanation.rankedEvidence.isEmpty,
                ambiguousAlternatives: alignment.ambiguousCandidates.count
            )
        }
    }
}
