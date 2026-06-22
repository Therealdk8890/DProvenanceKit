import Foundation

public struct VerificationArtifacts: Sendable {
    public let evidence: AlignmentEvidence
    
    public init(evidence: AlignmentEvidence) {
        self.evidence = evidence
    }
}
