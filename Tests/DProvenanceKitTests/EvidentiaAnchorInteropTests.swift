import CryptoKit
import Foundation
import XCTest
@testable import DProvenanceKit

/// Test-only exchange fixture for an Evidentia-style external anchor.
///
/// The fixture models the provider-facing fields without calling Evidentia or
/// introducing a production integration. A live provider response remains an
/// external trust boundary and must be verified separately.
final class EvidentiaAnchorInteropTests: XCTestCase {
    private struct AnchorExchange: Codable, Equatable {
        let schemaVersion: String
        let artifactSHA256: String
        let anchorSystem: String
        let anchorID: String
        let anchoredAt: Date
        let provider: Provider

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case artifactSHA256 = "artifact_sha256"
            case anchorSystem = "anchor_system"
            case anchorID = "anchor_id"
            case anchoredAt = "anchored_at"
            case provider
        }
    }

    private struct Provider: Codable, Equatable {
        let proofID: String
        let eventHash: String
        let algorithm: String
        let chain: String

        enum CodingKeys: String, CodingKey {
            case proofID = "proof_id"
            case eventHash = "event_hash"
            case algorithm
            case chain
        }
    }

    private let artifact = Data(#"{"runtime_id":"runtime-1","epoch":7,"state":"contained"}"#.utf8)

    func testFixtureBindsExactArtifactDigest() throws {
        let anchor = try fixture()

        XCTAssertEqual(anchor.schemaVersion, "external-anchor-exchange/v1")
        XCTAssertEqual(anchor.anchorSystem, "evidentia")
        XCTAssertEqual(anchor.provider.proofID, "EV-FIXTURE-001")
        XCTAssertEqual(anchor.provider.algorithm, "Ed25519")
        XCTAssertEqual(anchor.artifactSHA256, sha256(artifact))
        XCTAssertTrue(isAnchored(artifact, by: anchor))
    }

    func testByteMutationCannotReuseEvidentiaAnchorFixture() throws {
        let anchor = try fixture()

        var mutated = artifact
        mutated[mutated.startIndex + 5] ^= 0x01

        XCTAssertNotEqual(sha256(mutated), anchor.artifactSHA256)
        XCTAssertFalse(isAnchored(mutated, by: anchor))
    }

    func testCryptographicallyValidReplacementCannotReuseEvidentiaAnchorFixture() throws {
        let anchor = try fixture()
        let replacement = Data(#"{"runtime_id":"runtime-forged","epoch":8,"state":"contained"}"#.utf8)

        // A real DPK attestation could honestly sign the replacement. That would
        // establish integrity of the replacement, not inheritance of this anchor.
        XCTAssertNotEqual(sha256(replacement), anchor.artifactSHA256)
        XCTAssertFalse(isAnchored(replacement, by: anchor))
    }

    private func fixture() throws -> AnchorExchange {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AnchorExchange.self, from: Data(contentsOf: fixtureURL()))
    }

    private func fixtureURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("fixtures")
            .appendingPathComponent("external-anchor-evidentia-v1.json")
    }

    private func isAnchored(_ artifact: Data, by anchor: AnchorExchange) -> Bool {
        sha256(artifact) == anchor.artifactSHA256
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
