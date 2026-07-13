import CryptoKit
import Foundation
import XCTest
@testable import DProvenanceKit

final class ProofPackTests: XCTestCase {
    /// A payload that carries artifact digests the way a real producer would: nested inside
    /// an object array, so the happy paths also exercise the deep string-leaf walk.
    private struct TestEvent: TraceableEvent {
        struct ArtifactRef: Codable, Sendable, Equatable {
            let role: String
            let sha256: String
        }

        let typeIdentifier: String
        let artifacts: [ArtifactRef]
        let priority: TracePriority
    }

    private let reportBytes = Data(#"{"claims":[{"id":"c1","verdict":"supported"}]}"#.utf8)

    // MARK: - Happy paths

    func testUTF8ArtifactPackVerifies() throws {
        let digest = hex(reportBytes)
        let pack = try makePack(
            boundDigests: [digest],
            artifacts: [utf8Artifact(bytes: reportBytes, sha256: digest)]
        )

        let result = pack.verify()
        XCTAssertTrue(result.isValid, result.failure.map(String.init(describing:)) ?? "")
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.attestation?.isValid, true)
        XCTAssertEqual(result.bindings.count, 1)
        XCTAssertEqual(result.bindings[0].artifactIndex, 0)
        XCTAssertEqual(result.bindings[0].role, "claim-proof-report")
        XCTAssertEqual(result.bindings[0].sha256, digest)
        // The digest lives in the second event's payload; the first event binds nothing.
        XCTAssertEqual(result.bindings[0].eventIndex, 1)
        XCTAssertEqual(result.bindings[0].eventTypeIdentifier, "artifact-emitted")
    }

    func testBase64ArtifactPackVerifies() throws {
        // Deliberately not valid UTF-8, so only the base64 carrier can represent it.
        let binaryBytes = Data([0x00, 0xff, 0xfe, 0x10, 0x80, 0x7f])
        let digest = hex(binaryBytes)
        let pack = try makePack(
            boundDigests: [digest],
            artifacts: [ProofPackArtifact(
                role: "dataset-extract",
                mediaType: "application/octet-stream",
                encoding: .base64,
                content: binaryBytes.base64EncodedString(),
                sha256: digest
            )]
        )

        let result = pack.verify()
        XCTAssertTrue(result.isValid, result.failure.map(String.init(describing:)) ?? "")
        XCTAssertEqual(result.bindings.count, 1)
        XCTAssertEqual(result.bindings[0].eventIndex, 1)
    }

    // MARK: - Artifact failures

    func testTamperedArtifactContentIsDetected() throws {
        let digest = hex(reportBytes)
        let tamperedBytes = Data(#"{"claims":[{"id":"c1","verdict":"refuted"}]}"#.utf8)
        let pack = try makePack(
            boundDigests: [digest],
            artifacts: [utf8Artifact(bytes: tamperedBytes, sha256: digest)]
        )

        let result = pack.verify()
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.failure, .artifactDigestMismatch(index: 0))
        // The attestation itself was fine — only the embedded bytes were substituted.
        XCTAssertEqual(result.attestation?.isValid, true)
        XCTAssertTrue(result.bindings.isEmpty)
    }

    func testArtifactWhoseDigestIsNotInTraceIsNotBound() throws {
        let boundDigest = hex(Data("some other artifact".utf8))
        let digest = hex(reportBytes)
        let pack = try makePack(
            boundDigests: [boundDigest],
            artifacts: [utf8Artifact(bytes: reportBytes, sha256: digest)]
        )

        let result = pack.verify()
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.failure, .artifactNotBound(index: 0))
        XCTAssertEqual(result.attestation?.isValid, true)
    }

    func testEmptyArtifactsAreRejected() throws {
        let pack = try makePack(boundDigests: [hex(reportBytes)], artifacts: [])

        let result = pack.verify()
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.failure, .noArtifacts)
        XCTAssertNil(result.attestation)
    }

    func testUnsupportedVersionIsRejected() throws {
        let digest = hex(reportBytes)
        let valid = try makePack(
            boundDigests: [digest],
            artifacts: [utf8Artifact(bytes: reportBytes, sha256: digest)]
        )
        let futureVersion = ProofPackDocument(
            proofPackVersion: 2,
            attestation: valid.attestation,
            artifacts: valid.artifacts
        )

        let result = futureVersion.verify()
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.failure, .unsupportedVersion)
        XCTAssertNil(result.attestation)
    }

    func testUppercaseHexDigestIsRejectedNotNormalized() throws {
        let digest = hex(reportBytes)
        // Even the *correct* digest is malformed when uppercased: the verifier must never
        // repair a producer's claim into something that then matches.
        let pack = try makePack(
            boundDigests: [digest],
            artifacts: [utf8Artifact(bytes: reportBytes, sha256: digest.uppercased())]
        )

        let result = pack.verify()
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.failure, .malformedArtifact(index: 0, reason: .malformedDigest))
        // Rejected before any cryptography ran.
        XCTAssertNil(result.attestation)
    }

    func testUndecodableBase64ContentIsRejected() throws {
        let digest = hex(reportBytes)
        let pack = try makePack(
            boundDigests: [digest],
            artifacts: [ProofPackArtifact(
                role: "claim-proof-report",
                mediaType: "application/json",
                encoding: .base64,
                content: "not base64!!!",
                sha256: digest
            )]
        )

        let result = pack.verify()
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.failure, .malformedArtifact(index: 0, reason: .undecodableContent))
    }

    func testEmptyRoleIsRejected() throws {
        let digest = hex(reportBytes)
        let pack = try makePack(
            boundDigests: [digest],
            artifacts: [ProofPackArtifact(
                role: "",
                mediaType: "application/json",
                encoding: .utf8,
                content: String(decoding: reportBytes, as: UTF8.self),
                sha256: digest
            )]
        )

        let result = pack.verify()
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.failure, .malformedArtifact(index: 0, reason: .emptyRole))
    }

    // MARK: - Attestation coupling

    func testAttestationFailurePropagates() throws {
        let digest = hex(reportBytes)
        let pack = try makePack(
            boundDigests: [digest],
            artifacts: [utf8Artifact(bytes: reportBytes, sha256: digest)]
        )

        // Tamper an event payload after signing; the pack must fail on the attestation,
        // never reach the binding step, and surface the underlying reason.
        var events = pack.attestation.trace.events
        let original = events[0]
        events[0] = AttestableTraceEvent(
            id: original.id,
            runID: original.runID,
            contextID: original.contextID,
            engineName: original.engineName,
            schemaVersion: original.schemaVersion,
            sequence: original.sequence,
            spanID: original.spanID,
            parentSpanID: original.parentSpanID,
            typeIdentifier: original.typeIdentifier,
            priority: original.priority,
            payloadJSON: original.payloadJSON.replacingOccurrences(
                of: "policy-check",
                with: "policy-hacked"
            ),
            timestampUnixMicroseconds: original.timestampUnixMicroseconds
        )
        let tampered = ProofPackDocument(
            attestation: TraceAttestationDocument(
                trace: AttestableTrace(
                    runID: pack.attestation.trace.runID,
                    contextID: pack.attestation.trace.contextID,
                    events: events,
                    edges: pack.attestation.trace.edges
                ),
                attestation: pack.attestation.attestation
            ),
            artifacts: pack.artifacts
        )

        let result = tampered.verify()
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.failure, .attestationFailed(.digestMismatch))
        XCTAssertEqual(result.attestation?.failure, .digestMismatch)
        XCTAssertTrue(result.bindings.isEmpty)
    }

    func testTrustedKeyPinningPassesThrough() throws {
        let digest = hex(reportBytes)
        let pack = try makePack(
            boundDigests: [digest],
            artifacts: [utf8Artifact(bytes: reportBytes, sha256: digest)]
        )
        let signerKeyID = pack.attestation.attestation.keyID

        let pinned = pack.verify(trustedKeyIDs: [signerKeyID])
        XCTAssertTrue(pinned.isValid)
        XCTAssertEqual(pinned.attestation?.trust, .trustedKey)

        let mispinned = pack.verify(trustedKeyIDs: [String(repeating: "0", count: 64)])
        XCTAssertFalse(mispinned.isValid)
        XCTAssertEqual(mispinned.failure, .attestationFailed(.untrustedKey))
    }

    // MARK: - Serialization

    func testJSONRoundTripPreservesVerification() throws {
        let digest = hex(reportBytes)
        let pack = try makePack(
            boundDigests: [digest],
            artifacts: [utf8Artifact(bytes: reportBytes, sha256: digest)]
        )

        let data = try pack.jsonData()
        let decoded = try ProofPackDocument.decodeJSON(data)

        XCTAssertEqual(decoded, pack)
        XCTAssertTrue(decoded.verify().isValid)
    }

    // MARK: - Committed vector

    func testPublicProofPackVectorVerifies() throws {
        let data = try Data(contentsOf: vectorURL())
        let pack = try ProofPackDocument.decodeJSON(data)

        let result = pack.verify()
        XCTAssertTrue(result.isValid, result.failure.map(String.init(describing:)) ?? "unknown failure")
        XCTAssertEqual(pack.proofPackVersion, 1)
        XCTAssertEqual(pack.attestation.attestation.version, 1)
        XCTAssertEqual(pack.attestation.attestation.algorithm, .p256SHA256)
        XCTAssertEqual(pack.attestation.attestation.canonicalization, .dpkBinaryV1)
        XCTAssertEqual(result.bindings.count, pack.artifacts.count)
    }

    /// Regenerates docs/test-vectors/proof-pack-v1.json. Skipped by default so the committed
    /// vector stays byte-stable; run with DPK_GENERATE_PROOF_PACK_VECTOR=1 to rewrite it:
    ///
    ///     DPK_GENERATE_PROOF_PACK_VECTOR=1 swift test \
    ///       --filter ProofPackTests/testGenerateProofPackVector
    func testGenerateProofPackVector() throws {
        guard ProcessInfo.processInfo.environment["DPK_GENERATE_PROOF_PACK_VECTOR"] == "1" else {
            throw XCTSkip("Vector generator — set DPK_GENERATE_PROOF_PACK_VECTOR=1 to regenerate")
        }

        let artifactBytes = Data(
            #"{"claims":[{"id":"c1","verdict":"supported"},{"id":"c2","verdict":"refuted"}]}"#.utf8
        )
        let digest = hex(artifactBytes)
        // Deterministic, obviously-test-only signing scalar so regeneration keeps the key ID.
        let key = try SoftwareTraceAttestationKey(
            rawRepresentation: Data((1...32).map { UInt8($0) })
        )
        let document = try TraceAttestationDocument.signed(
            run: makeRun(boundDigests: [digest]),
            using: key,
            issuedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )
        let pack = ProofPackDocument(
            attestation: document,
            artifacts: [utf8Artifact(bytes: artifactBytes, sha256: digest)]
        )
        XCTAssertTrue(pack.verify().isValid)

        try pack.jsonData().write(to: vectorURL(), options: .atomic)
    }

    // MARK: - Fixtures

    private func vectorURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs")
            .appendingPathComponent("test-vectors")
            .appendingPathComponent("proof-pack-v1.json")
    }

    private func makePack(
        boundDigests: [String],
        artifacts: [ProofPackArtifact]
    ) throws -> ProofPackDocument {
        let document = try TraceAttestationDocument.signed(
            run: makeRun(boundDigests: boundDigests),
            using: SoftwareTraceAttestationKey(),
            issuedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )
        return ProofPackDocument(attestation: document, artifacts: artifacts)
    }

    /// A three-event run whose middle event carries the artifact digests, matching the
    /// producer rule in docs/PROOF_PACK.md: record the hash before attesting.
    private func makeRun(boundDigests: [String]) -> TraceRun<TestEvent> {
        let runID = uuid("30000000-0000-0000-0000-000000000001")
        let contextID = "proof-pack-case-1"
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000.5)

        func event(
            id: String,
            sequence: UInt64,
            payload: TestEvent,
            offset: TimeInterval
        ) -> TraceEvent<TestEvent> {
            TraceEvent(
                id: uuid(id),
                runID: runID,
                contextID: contextID,
                engineName: "OnDeviceAgent",
                schemaVersion: 1,
                sequence: sequence,
                spanID: "report",
                parentSpanID: nil,
                payload: payload,
                timestamp: timestamp.addingTimeInterval(offset)
            )
        }

        return TraceRun(
            runID: runID,
            contextID: contextID,
            events: [
                event(
                    id: "40000000-0000-0000-0000-000000000001",
                    sequence: 0,
                    payload: TestEvent(
                        typeIdentifier: "policy-check",
                        artifacts: [],
                        priority: .structural
                    ),
                    offset: 0
                ),
                event(
                    id: "40000000-0000-0000-0000-000000000002",
                    sequence: 1,
                    payload: TestEvent(
                        typeIdentifier: "artifact-emitted",
                        artifacts: boundDigests.map {
                            TestEvent.ArtifactRef(role: "claim-proof-report", sha256: $0)
                        },
                        priority: .critical
                    ),
                    offset: 0.25
                ),
                event(
                    id: "40000000-0000-0000-0000-000000000003",
                    sequence: 2,
                    payload: TestEvent(
                        typeIdentifier: "final-decision",
                        artifacts: [],
                        priority: .critical
                    ),
                    offset: 0.5
                ),
            ]
        )
    }

    private func utf8Artifact(bytes: Data, sha256: String) -> ProofPackArtifact {
        ProofPackArtifact(
            role: "claim-proof-report",
            mediaType: "application/json",
            encoding: .utf8,
            content: String(decoding: bytes, as: UTF8.self),
            sha256: sha256
        )
    }

    private func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func uuid(_ value: String) -> UUID {
        guard let id = UUID(uuidString: value) else {
            XCTFail("Invalid UUID fixture: \(value)")
            return UUID()
        }
        return id
    }
}
