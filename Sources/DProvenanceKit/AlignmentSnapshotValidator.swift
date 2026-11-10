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
    /// Fails immediately if the snapshot metadata or rendered output differs.
    case strict
    /// Logs a warning and returns a soft failure result if any snapshot field diverges.
    case reportOnly
}

public enum SnapshotValidationError: Error {
    case profileHashMismatch(expected: String, actual: String)
    case engineVersionMismatch(expected: String, actual: String)
    case hashMismatch(expected: String, actual: String)
}

public struct AlignmentSnapshotValidator: Sendable {
    public let toleranceMode: DriftToleranceMode
    
    public init(toleranceMode: DriftToleranceMode = .strict) {
        self.toleranceMode = toleranceMode
    }
    
    /// Computes the canonical hash of the final render model.
    public static func computeAlignmentsHash(from renderNodes: [AlignmentRenderNode]) -> String {
        let fullSerialization = renderNodes.map { $0.canonicalSerialization }.joined(separator: "\n")
        let hash = SHA256.hash(data: Data(fullSerialization.utf8))
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
    
    /// Creates a snapshot from an alignment result.
    public static func createSnapshot(from result: TraceAlignmentResult<some TraceableEvent>) -> AlignmentSnapshot {
        let renderNodes = result.renderModels()
        return AlignmentSnapshot(
            profileHash: result.profileHash,
            engineVersion: result.engineVersion,
            outputAlignmentsHash: computeAlignmentsHash(from: renderNodes)
        )
    }
    
    /// Validates provenance metadata before comparing the canonical rendered output.
    public func validate(result: TraceAlignmentResult<some TraceableEvent>, against snapshot: AlignmentSnapshot) throws -> Bool {
        if result.profileHash != snapshot.profileHash {
            switch toleranceMode {
            case .strict:
                throw SnapshotValidationError.profileHashMismatch(
                    expected: snapshot.profileHash, actual: result.profileHash
                )
            case .reportOnly:
                DPKLog.alignment.warning("Snapshot profile hash mismatch. Expected \(snapshot.profileHash, privacy: .public), got \(result.profileHash, privacy: .public)")
                return false
            }
        }

        if result.engineVersion != snapshot.engineVersion {
            switch toleranceMode {
            case .strict:
                throw SnapshotValidationError.engineVersionMismatch(
                    expected: snapshot.engineVersion, actual: result.engineVersion
                )
            case .reportOnly:
                DPKLog.alignment.warning("Snapshot engine version mismatch. Expected \(snapshot.engineVersion, privacy: .public), got \(result.engineVersion, privacy: .public)")
                return false
            }
        }

        let renderNodes = result.renderModels()
        let actualHash = Self.computeAlignmentsHash(from: renderNodes)
        guard actualHash != snapshot.outputAlignmentsHash else { return true }

        switch toleranceMode {
        case .strict:
            throw SnapshotValidationError.hashMismatch(
                expected: snapshot.outputAlignmentsHash, actual: actualHash
            )
        case .reportOnly:
            DPKLog.alignment.warning("Snapshot output hash mismatch. Expected \(snapshot.outputAlignmentsHash, privacy: .public), got \(actualHash, privacy: .public)")
            return false
        }
    }
}
