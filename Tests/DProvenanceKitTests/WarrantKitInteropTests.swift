import CryptoKit
import Foundation
import XCTest
@testable import DProvenanceKit

/// Narrow interoperability test for the published WarrantKit portable evidence contract.
///
/// DProvenanceKit treats the WarrantKit document as an opaque artifact. The semantic
/// assertions here are limited to the runtime-binding invariants needed to demonstrate
/// the boundary; DProvenanceKit does not become a WarrantKit verifier.
final class WarrantKitInteropTests: XCTestCase {
    private struct ArtifactRef: Codable, Sendable, Equatable {
        let role: String
        let sha256: String
    }

    private struct ArtifactEvent: TraceableEvent {
        let typeIdentifier: String
        let artifact: ArtifactRef
        let priority: TracePriority
    }

    private let role = "warrantkit-runtime-evidence"

    func testWarrantKitEvidenceEmbedsAndVerifiesAsDPKProofPack() throws {
        let bytes = try fixtureData()
        let digest = sha256(bytes)
        let pack = try makePack(artifactBytes: bytes, digest: digest)

        let result = pack.verify(requireRoleBinding: true)

        XCTAssertTrue(result.isValid, result.failure.map(String.init(describing:)) ?? "unknown failure")
        XCTAssertEqual(result.bindingStrength, .roleBound)
        XCTAssertEqual(result.bindings.first?.role, role)
        XCTAssertEqual(result.bindings.first?.sha256, digest)
    }

    func testByteFlipFailsEvidenceBindingWhileSignedProvenanceRemainsIntact() throws {
        let bytes = try fixtureData()
        let digest = sha256(bytes)
        let pack = try makePack(artifactBytes: bytes, digest: digest)

        var tampered = bytes
        tampered[tampered.index(tampered.startIndex, offsetBy: tampered.count / 2)] ^= 0x01

        let tamperedPack = ProofPackDocument(
            attestation: pack.attestation,
            artifacts: [
                ProofPackArtifact(
                    role: role,
                    mediaType: "application/json",
                    encoding: .utf8,
                    content: String(decoding: tampered, as: UTF8.self),
                    sha256: digest
                )
            ]
        )

        let result = tamperedPack.verify(requireRoleBinding: true)

        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.failure, .artifactDigestMismatch(index: 0))
        // The signed provenance trace is unchanged and therefore still valid. The
        // proof-pack boundary rejects the substituted WarrantKit bytes.
        XCTAssertEqual(result.attestation?.isValid, true)

        // The WarrantKit evidence contract also rejects the mutated artifact because
        // the embedded runtime-record digests no longer describe its bytes.
        var tamperedDocument = try JSONSerialization.jsonObject(with: tampered) as! [String: Any]
        XCTAssertThrowsError(try assertWarrantKitRuntimeBindingContract(tamperedDocument))
    }

    func testCryptographicallyValidReboundRecordIsRejectedByRuntimeContract() throws {
        var rebound = try fixtureDocument()
        var proof = rebound["proof"] as! [String: Any]
        var runtimeBinding = proof["runtime_binding"] as! [String: Any]
        runtimeBinding["runtime_id"] = "runtime-forged"
        proof["runtime_binding"] = runtimeBinding
        rebound["proof"] = proof

        let reboundBytes = try JSONSerialization.data(
            withJSONObject: rebound,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        let reboundDigest = sha256(reboundBytes)

        // DPK can honestly sign and verify these bytes: provenance integrity establishes
        // what was signed, not whether the WarrantKit runtime-binding contract is satisfied.
        let pack = try makePack(artifactBytes: reboundBytes, digest: reboundDigest)
        let provenance = pack.verify(requireRoleBinding: true)
        XCTAssertTrue(provenance.isValid, provenance.failure.map(String.init(describing:)) ?? "unknown failure")

        // The WarrantKit runtime-binding contract rejects the rebound identity.
        XCTAssertThrowsError(try assertWarrantKitRuntimeBindingContract(rebound)) { error in
            XCTAssertTrue(
                String(describing: error).contains("runtime binding runtime_id does not match execution")
            )
        }
    }

    private func makePack(artifactBytes: Data, digest: String) throws -> ProofPackDocument {
        let runID = UUID(uuidString: "30000000-0000-0000-0000-0000000000aa")!
        let contextID = "warrantkit-runtime-interop"
        let timestamp = Date(timeIntervalSince1970: 1_759_000_000)

        let event = TraceEvent(
            id: UUID(uuidString: "40000000-0000-0000-0000-0000000000aa")!,
            runID: runID,
            contextID: contextID,
            engineName: "WarrantKitInterop",
            schemaVersion: 1,
            sequence: 0,
            spanID: "runtime-evidence",
            parentSpanID: nil,
            payload: ArtifactEvent(
                typeIdentifier: "warrantkit-evidence-anchored",
                artifact: ArtifactRef(role: role, sha256: digest),
                priority: .critical
            ),
            timestamp: timestamp
        )

        let run = TraceRun(runID: runID, contextID: contextID, events: [event])
        let attestation = try TraceAttestationDocument.signed(
            run: run,
            using: SoftwareTraceAttestationKey(),
            issuedAt: timestamp.addingTimeInterval(1)
        )

        return ProofPackDocument(
            attestation: attestation,
            artifacts: [
                ProofPackArtifact(
                    role: role,
                    mediaType: "application/json",
                    encoding: .utf8,
                    content: String(decoding: artifactBytes, as: UTF8.self),
                    sha256: digest
                )
            ]
        )
    }

    private func fixtureURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("fixtures")
            .appendingPathComponent("warrantkit-runtime-pinned-evidence-v1.json")
    }

    private func fixtureData() throws -> Data {
        try Data(contentsOf: fixtureURL())
    }

    private func fixtureDocument() throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: fixtureData())
        return object as! [String: Any]
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Minimal semantic boundary assertion kept local to this interoperability test.
    /// The authoritative portable verifier remains WarrantKit-owned and is not imported here.
    private func assertWarrantKitRuntimeBindingContract(_ document: [String: Any]) throws {
        let execution = document["execution"] as! [String: Any]
        let proof = document["proof"] as! [String: Any]
        let binding = proof["runtime_binding"] as! [String: Any]

        guard binding["runtime_id"] as? String == execution["runtime_id"] as? String else {
            throw NSError(
                domain: "WarrantKitInterop",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "runtime binding runtime_id does not match execution"]
            )
        }

        let runtimeID = binding["runtime_id"] as! String
        let agentID = binding["agent_id"] as! String
        let epoch = binding["epoch"] as! Int

        for label in ["authority", "enforcement", "observation"] {
            let item = binding[label] as! [String: Any]
            let record = item["record"] as! [String: Any]

            guard record["runtime_id"] as? String == runtimeID else {
                throw NSError(
                    domain: "WarrantKitInterop",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "runtime binding \(label) runtime_id does not match"]
                )
            }
            guard record["agent_id"] as? String == agentID else {
                throw NSError(
                    domain: "WarrantKitInterop",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "runtime binding \(label) agent_id does not match"]
                )
            }
            guard record["epoch"] as? Int == epoch else {
                throw NSError(
                    domain: "WarrantKitInterop",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "runtime binding \(label) epoch does not match"]
                )
            }

            let canonical = try JSONSerialization.data(
                withJSONObject: record,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
            let expectedDigest = "sha256:" + sha256(canonical)
            guard item["digest"] as? String == expectedDigest else {
                throw NSError(
                    domain: "WarrantKitInterop",
                    code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "runtime binding \(label) digest does not match record"]
                )
            }
        }
    }
}
