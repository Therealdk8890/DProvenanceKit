import Foundation
import CryptoKit

/// Defines the canonical sorting, normalization, and evaluation rules for all alignment components.
/// This acts as a frozen execution spec, stripping out non-deterministic UI/audit flicker.
public enum AlignmentExecutionContract: Sendable {
    public static let contractVersion = "1.0.0"
    
    /// Global canonical ordering for evidence arrays.
    public static func canonicalSort(evidence: [HeuristicEvidence]) -> [HeuristicEvidence] {
        return evidence.sorted { a, b in
            if a.scoreContribution != b.scoreContribution {
                return a.scoreContribution > b.scoreContribution
            }
            return a.category.rawValue < b.category.rawValue
        }
    }
    
    /// Global canonical ordering for ambiguous matches.
    public static func canonicalSort<T>(ambiguity: [AmbiguousMatch<T>]) -> [AmbiguousMatch<T>] {
        return ambiguity.sorted { a, b in
            if a.strength != b.strength {
                return a.strength > b.strength
            }
            return a.event.sequence < b.event.sequence
        }
    }
    
    /// Global canonical ordering for final alignments.
    public static func canonicalSort<T>(alignments: [EventAlignment<T>]) -> [EventAlignment<T>] {
        return alignments.sorted { a, b in
            // Every well-formed alignment has at least one of base/comparison; fall back to
            // stable defaults rather than force-unwrapping so a malformed (both-nil) alignment
            // sorts deterministically instead of crashing the sort.
            let seqA = a.baseEvent?.sequence ?? a.comparisonEvent?.sequence ?? 0
            let seqB = b.baseEvent?.sequence ?? b.comparisonEvent?.sequence ?? 0
            if seqA != seqB { return seqA < seqB }

            let idA = (a.baseEvent?.id ?? a.comparisonEvent?.id)?.uuidString ?? ""
            let idB = (b.baseEvent?.id ?? b.comparisonEvent?.id)?.uuidString ?? ""
            return idA < idB
        }
    }
    
    /// Generates the canonical profile hash representing the full runtime execution graph.
    public static func computeProfileHash(
        profile: AlignmentProfile,
        evaluatorIdentifier: String,
        engineVersion: String
    ) -> String {
        let payload = """
        contractVersion:\(contractVersion)
        engineVersion:\(engineVersion)
        strategy:\(profile.strategy.rawValue)
        profileVersion:\(profile.version)
        typeWeight:\(profile.typeWeight)
        payloadWeight:\(profile.payloadWeight)
        structuralWeight:\(profile.structuralWeight)
        temporalWeight:\(profile.temporalWeight)
        semanticThreshold:\(profile.semanticThreshold)
        maxAmbiguousCandidates:\(profile.maxAmbiguousCandidates)
        ambiguityDeltaThreshold:\(profile.ambiguityDeltaThreshold)
        alignmentMode:\(profile.alignmentMode.rawValue)
        evaluatorIdentifier:\(evaluatorIdentifier)
        """
        let hash = SHA256.hash(data: Data(payload.utf8))
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}
