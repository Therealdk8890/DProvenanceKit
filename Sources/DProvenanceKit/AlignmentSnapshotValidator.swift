import Foundation
import CryptoKit

public struct AlignmentSnapshot: Codable, Sendable, Equatable {
    public let profileHash: String
    public let engineVersion: String
    public let outputAlignmentsHash: String
    
    public init(profileHash: String, engineVersion: String, outputAlignmentsHash: String) {
        self.profileHash = profileHash
        self.engineVersion = engineVersion
        self.outputAlignmentsHash = outputAlignmentsHash
    }
}

public enum DriftToleranceMode: Sendable, Equatable {
    /// Fails immediately if the hashes do not match perfectly
    case strict
    /// Logs a warning or returns a soft failure result if they diverge
    case reportOnly
}

public enum SnapshotValidationError: Error {
    case hashMismatch(expected: String, actual: String)
}

public struct AlignmentSnapshotValidator: Sendable {
    public let toleranceMode: DriftToleranceMode
    
    public init(toleranceMode: DriftToleranceMode = .strict) {
        self.toleranceMode = toleranceMode
    }
    
    /// Computes the canonical Merkle-style hash of the final render model.
    public static func computeAlignmentsHash(from renderNodes: [AlignmentRenderNode]) -> String {
        // Canonical serialization list joined by newlines
        let fullSerialization = renderNodes.map { $0.canonicalSerialization }.joined(separator: "\n")
        let hash = SHA256.hash(data: Data(fullSerialization.utf8))
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
    
    /// Creates a snapshot from an alignment result.
    public static func createSnapshot(from result: TraceAlignmentResult<some TraceableEvent>) -> AlignmentSnapshot {
        let renderNodes = result.renderModels()
        let alignmentsHash = computeAlignmentsHash(from: renderNodes)
        return AlignmentSnapshot(
            profileHash: result.profileHash,
            engineVersion: result.engineVersion,
            outputAlignmentsHash: alignmentsHash
        )
    }
    
    /// Asserts that an alignment result matches the exact output defined in the snapshot.
    public func validate(result: TraceAlignmentResult<some TraceableEvent>, against snapshot: AlignmentSnapshot) throws -> Bool {
        let renderNodes = result.renderModels()
        let actualHash = AlignmentSnapshotValidator.computeAlignmentsHash(from: renderNodes)
        
        if actualHash != snapshot.outputAlignmentsHash {
            switch toleranceMode {
            case .strict:
                throw SnapshotValidationError.hashMismatch(expected: snapshot.outputAlignmentsHash, actual: actualHash)
            case .reportOnly:
                // Would log to standard out or metrics
                print("⚠️ [AlignmentSnapshotValidator] Drift detected. Expected \(snapshot.outputAlignmentsHash), got \(actualHash)")
                return false
            }
        }
        return true
    }
}
