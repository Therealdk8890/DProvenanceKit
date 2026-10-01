import CryptoKit
import Foundation
import XCTest
@testable import DProvenanceKit

/// Test-only model of the external-anchor interoperability boundary.
///
/// This deliberately does not introduce an anchoring service or production API.
/// The anchor is treated as an opaque external statement over an exact artifact digest.
final class ExternalAnchorInteropTests: XCTestCase {
    private struct ExternalAnchor: Equatable {
        let anchorID: String
        let anchorSystem: String
        let artifactSHA256: String
        let anchoredAt: Date
    }

    func testByteMutationCannotReuseOriginalExternalAnchor() throws {
        let original = Data(#"{"runtime_id":"runtime-1","epoch":7,"state":"contained"}"#.utf8)
        let anchor = makeAnchor(for: original)

        var mutated = original
        mutated[mutated.startIndex + 5] ^= 0x01

        XCTAssertNotEqual(sha256(mutated), anchor.artifactSHA256)
        XCTAssertFalse(isAnchored(mutated, by: anchor))
    }

    func testCryptographicallyValidReplacementCannotReuseOriginalExternalAnchor() throws {
        let original = Data(#"{"runtime_id":"runtime-1","epoch":7,"state":"contained"}"#.utf8)
        let replacement = Data(#"{"runtime_id":"runtime-forged","epoch":8,"state":"contained"}"#.utf8)
        let anchor = makeAnchor(for: original)

        // The replacement is a perfectly well-formed artifact. In a real deployment,
        // DProvenanceKit could also receive a newly signed attestation over these bytes.
        // That internal cryptographic validity does not change the external anchor.
        XCTAssertNotEqual(sha256(replacement), anchor.artifactSHA256)
        XCTAssertFalse(isAnchored(replacement, by: anchor))
    }

    func testUnchangedArtifactMatchesExternalAnchor() throws {
        let artifact = Data(#"{"runtime_id":"runtime-1","epoch":7,"state":"contained"}"#.utf8)
        let anchor = makeAnchor(for: artifact)

        XCTAssertTrue(isAnchored(artifact, by: anchor))
    }

    private func makeAnchor(for artifact: Data) -> ExternalAnchor {
        ExternalAnchor(
            anchorID: "anchor-fixture-001",
            anchorSystem: "external-anchor-fixture",
            artifactSHA256: sha256(artifact),
            anchoredAt: Date(timeIntervalSince1970: 1_759_000_100)
        )
    }

    private func isAnchored(_ artifact: Data, by anchor: ExternalAnchor) -> Bool {
        sha256(artifact) == anchor.artifactSHA256
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
