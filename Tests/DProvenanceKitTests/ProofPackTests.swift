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

    /// Carries a third string (`status`) co-located with role+sha256 — the shape that let
    /// the first review draft be bypassed: matching the role against ANY sibling string.
    private struct SiblingEvent: TraceableEvent {
        struct Ref: Codable, Sendable, Equatable {
            let role: String
            let sha256: String
            let status: String
        }
        let typeIdentifier: String
        let artifacts: [Ref]
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
        // Role matches the one makeRun records co-located with the digest, so this v2 pack
        // binds; the test's point is the base64 carrier for non-UTF-8 bytes.
        let pack = try makePack(
            boundDigests: [digest],
            artifacts: [ProofPackArtifact(
                role: "claim-proof-report",
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
        // A version above the current schema is rejected, never optimistically accepted.
        let futureVersion = ProofPackDocument(
            proofPackVersion: ProofPackDocument.schemaVersion + 1,
            attestation: valid.attestation,
            artifacts: valid.artifacts
        )

        let result = futureVersion.verify()
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.failure, .unsupportedVersion)
        XCTAssertNil(result.attestation)
    }

    // MARK: - v2 role binding

    func testDefaultPackIsV2AndRoleBound() throws {
        let digest = hex(reportBytes)
        // makePack uses the default version → v2. The bound event records
        // {role: "claim-proof-report", sha256: digest} co-located, and the artifact
        // declares the same role, so the role is signer-vouched.
        let pack = try makePack(
            boundDigests: [digest],
            artifacts: [utf8Artifact(bytes: reportBytes, sha256: digest)]
        )
        XCTAssertEqual(pack.proofPackVersion, 2)

        let result = pack.verify()
        XCTAssertTrue(result.isValid, result.failure.map(String.init(describing:)) ?? "")
        XCTAssertEqual(result.bindings.count, 1)
        XCTAssertEqual(result.bindings[0].strength, .roleBound)
        XCTAssertEqual(result.bindingStrength, .roleBound)
    }

    func testV2RelabelAfterSigningFailsToBind() throws {
        // The relabel attack: a genuine pack whose trace recorded role "claim-proof-report"
        // for these bytes, re-wrapped with the artifact claiming role "board-approved-final"
        // (same bytes, same digest). The fake role is not in the signed trace, so under v2
        // the artifact must fail to bind — the signature never covered "board-approved-final".
        let digest = hex(reportBytes)
        let relabeled = ProofPackArtifact(
            role: "board-approved-final",
            mediaType: "application/json",
            encoding: .utf8,
            content: String(decoding: reportBytes, as: UTF8.self),
            sha256: digest
        )
        let pack = try makePack(boundDigests: [digest], artifacts: [relabeled])
        XCTAssertEqual(pack.proofPackVersion, 2)

        let result = pack.verify()
        XCTAssertFalse(result.isValid, "a role the signer never vouched for must not bind under v2")
        XCTAssertEqual(result.failure, .artifactNotBound(index: 0))
        XCTAssertEqual(result.attestation?.isValid, true, "the attestation itself is untouched")
    }

    func testV1RelabelStillVerifiesButIsLabeledValuePresenceOnly() throws {
        // The identical relabel under a v1 pack: it still verifies (v1 binds digest presence
        // only), but the result must honestly report that the role is NOT signer-vouched, so
        // a consumer is not silently misled.
        let digest = hex(reportBytes)
        let relabeled = ProofPackArtifact(
            role: "board-approved-final",
            mediaType: "application/json",
            encoding: .utf8,
            content: String(decoding: reportBytes, as: UTF8.self),
            sha256: digest
        )
        let signed = try TraceAttestationDocument.signed(
            run: makeRun(boundDigests: [digest]),
            using: SoftwareTraceAttestationKey(),
            issuedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )
        let v1Pack = ProofPackDocument(proofPackVersion: 1, attestation: signed, artifacts: [relabeled])

        let result = v1Pack.verify()
        XCTAssertTrue(result.isValid, "v1 binds on digest presence, so it still verifies")
        XCTAssertEqual(result.bindings.count, 1)
        XCTAssertEqual(result.bindings[0].strength, .valuePresenceOnly)
        XCTAssertEqual(
            result.bindingStrength, .valuePresenceOnly,
            "the weaker v1 binding must be surfaced, not hidden"
        )
    }

    func testV2RequiresRoleColocatedWithDigestNotMerelyPresent() throws {
        // The digest and the role both appear in the trace, but in DIFFERENT events — the
        // role is not co-located with the digest anywhere. v2 must not bind: an attacker
        // could otherwise pair any digest with any role that happens to sit in the trace.
        let digest = hex(reportBytes)
        let runID = uuid("30000000-0000-0000-0000-000000000009")
        let contextID = "proof-pack-split"
        let ts = Date(timeIntervalSince1970: 1_700_000_000.5)
        func ev(_ id: String, _ seq: UInt64, _ payload: TestEvent) -> TraceEvent<TestEvent> {
            TraceEvent(id: uuid(id), runID: runID, contextID: contextID, engineName: "OnDeviceAgent",
                       schemaVersion: 1, sequence: seq, spanID: "report", parentSpanID: nil,
                       payload: payload, timestamp: ts.addingTimeInterval(Double(seq) * 0.1))
        }
        // Event 0 carries the digest with a DIFFERENT role; event 1 carries the target role
        // with NO digest. Neither object co-locates target role + digest.
        let run = TraceRun(runID: runID, contextID: contextID, events: [
            ev("40000000-0000-0000-0000-0000000000a1", 0, TestEvent(
                typeIdentifier: "digest-here", artifacts: [.init(role: "some-other-role", sha256: digest)], priority: .critical)),
            ev("40000000-0000-0000-0000-0000000000a2", 1, TestEvent(
                typeIdentifier: "role-here", artifacts: [.init(role: "claim-proof-report", sha256: "0")], priority: .critical)),
        ])
        let signed = try TraceAttestationDocument.signed(
            run: run, using: SoftwareTraceAttestationKey(),
            issuedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )
        let pack = ProofPackDocument(attestation: signed, artifacts: [
            utf8Artifact(bytes: reportBytes, sha256: digest)  // role "claim-proof-report"
        ])
        XCTAssertEqual(pack.proofPackVersion, 2)

        let result = pack.verify()
        XCTAssertFalse(result.isValid, "role and digest in different objects must not bind under v2")
        XCTAssertEqual(result.failure, .artifactNotBound(index: 0))
    }

    func testV2DoesNotBindRoleToAnArbitrarySiblingString() throws {
        // The bypass an earlier draft allowed: the signer recorded {role:"draft",
        // sha256:D, status:"final"}. An attacker re-labels the artifact role to "final" —
        // a string co-located with the digest, but NOT under a `role` key. v2 must bind the
        // role's value only against a `role` key, so this must fail.
        let digest = hex(reportBytes)
        let runID = uuid("30000000-0000-0000-0000-00000000000f")
        let contextID = "proof-pack-sibling"
        let ts = Date(timeIntervalSince1970: 1_700_000_000.5)
        let run = TraceRun(runID: runID, contextID: contextID, events: [
            TraceEvent(
                id: uuid("40000000-0000-0000-0000-0000000000b1"), runID: runID, contextID: contextID,
                engineName: "OnDeviceAgent", schemaVersion: 1, sequence: 0, spanID: "report", parentSpanID: nil,
                payload: SiblingEvent(
                    typeIdentifier: "artifact-emitted",
                    artifacts: [.init(role: "draft", sha256: digest, status: "final")],
                    priority: .critical),
                timestamp: ts)
        ])
        let signed = try TraceAttestationDocument.signed(
            run: run, using: SoftwareTraceAttestationKey(),
            issuedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )
        // The genuine role that WOULD bind is "draft"; the attacker claims "final".
        let relabeled = ProofPackArtifact(
            role: "final", mediaType: "application/json", encoding: .utf8,
            content: String(decoding: reportBytes, as: UTF8.self), sha256: digest
        )
        let pack = ProofPackDocument(attestation: signed, artifacts: [relabeled])
        XCTAssertEqual(pack.proofPackVersion, 2)

        let result = pack.verify()
        XCTAssertFalse(
            result.isValid,
            "a sibling string that is not the `role` value must not be accepted as the role"
        )
        XCTAssertEqual(result.failure, .artifactNotBound(index: 0))

        // Sanity: the genuine role "draft" for the same bytes DOES bind.
        let genuine = ProofPackArtifact(
            role: "draft", mediaType: "application/json", encoding: .utf8,
            content: String(decoding: reportBytes, as: UTF8.self), sha256: digest
        )
        let ok = ProofPackDocument(attestation: signed, artifacts: [genuine]).verify()
        XCTAssertTrue(ok.isValid)
        XCTAssertEqual(ok.bindings.first?.strength, .roleBound)
    }

    func testV2RequiresRoleAndDigestInTheSameObjectNotMerelyTheSamePayload() throws {
        // The same-OBJECT requirement (stronger than same-payload): one signed payload
        // carries two sibling refs — {role:"draft", sha256:D} and {role:"final", sha256:D2}.
        // An attacker embeds the bytes hashing to D but claims role "final". No single object
        // has both role=="final" and sha256==D, so v2 must refuse; a weaker "some object has
        // the role, some object has the digest, same payload" check would wrongly splice
        // D's bytes onto the "final" role.
        let bytesD = reportBytes
        let digestD = hex(bytesD)
        let bytesD2 = Data(#"{"claims":[{"id":"c2","verdict":"refuted"}]}"#.utf8)
        let digestD2 = hex(bytesD2)
        let runID = uuid("30000000-0000-0000-0000-0000000000e5")
        let contextID = "proof-pack-splice"
        let ts = Date(timeIntervalSince1970: 1_700_000_000.5)
        let run = TraceRun(runID: runID, contextID: contextID, events: [
            TraceEvent(
                id: uuid("40000000-0000-0000-0000-0000000000c1"), runID: runID, contextID: contextID,
                engineName: "OnDeviceAgent", schemaVersion: 1, sequence: 0, spanID: "report", parentSpanID: nil,
                payload: TestEvent(
                    typeIdentifier: "artifact-emitted",
                    artifacts: [
                        .init(role: "draft", sha256: digestD),
                        .init(role: "final", sha256: digestD2),
                    ],
                    priority: .critical),
                timestamp: ts)
        ])
        let signed = try TraceAttestationDocument.signed(
            run: run, using: SoftwareTraceAttestationKey(),
            issuedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )
        // Bytes hash to D (draft's digest), but the artifact claims role "final".
        let spliced = ProofPackArtifact(
            role: "final", mediaType: "application/json", encoding: .utf8,
            content: String(decoding: bytesD, as: UTF8.self), sha256: digestD
        )
        let pack = ProofPackDocument(attestation: signed, artifacts: [spliced])

        let result = pack.verify()
        XCTAssertFalse(
            result.isValid,
            "digest and role from DIFFERENT objects must not splice into a binding"
        )
        XCTAssertEqual(result.failure, .artifactNotBound(index: 0))

        // Sanity: the genuine pairing (role "draft" for bytes D) binds.
        let genuine = ProofPackArtifact(
            role: "draft", mediaType: "application/json", encoding: .utf8,
            content: String(decoding: bytesD, as: UTF8.self), sha256: digestD
        )
        let ok = ProofPackDocument(attestation: signed, artifacts: [genuine]).verify()
        XCTAssertTrue(ok.isValid)
        XCTAssertEqual(ok.bindings.first?.strength, .roleBound)
    }

    // MARK: - Fail-closed role-binding policy

    func testRequireRoleBindingRejectsV1Pack() throws {
        let digest = hex(reportBytes)
        let signed = try TraceAttestationDocument.signed(
            run: makeRun(boundDigests: [digest]),
            using: SoftwareTraceAttestationKey(),
            issuedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )
        let v1Pack = ProofPackDocument(
            proofPackVersion: 1, attestation: signed,
            artifacts: [utf8Artifact(bytes: reportBytes, sha256: digest)]
        )

        // Default: v1 verifies (labeled).
        XCTAssertTrue(v1Pack.verify().isValid)
        // Fail-closed: a caller that demands role binding rejects the v1 pack outright,
        // before any cryptography, with a distinct reason.
        let strict = v1Pack.verify(requireRoleBinding: true)
        XCTAssertFalse(strict.isValid)
        XCTAssertEqual(strict.failure, .roleBindingRequired)
        XCTAssertNil(strict.attestation)
    }

    func testRequireRoleBindingAcceptsV2Pack() throws {
        let digest = hex(reportBytes)
        let pack = try makePack(
            boundDigests: [digest],
            artifacts: [utf8Artifact(bytes: reportBytes, sha256: digest)]
        )
        XCTAssertEqual(pack.proofPackVersion, 2)

        let strict = pack.verify(requireRoleBinding: true)
        XCTAssertTrue(strict.isValid, "a v2 pack satisfies the role-binding requirement")
        XCTAssertEqual(strict.bindingStrength, .roleBound)
    }

    // MARK: - Version boundaries

    func testVersionZeroAndNegativeAreRejected() throws {
        let digest = hex(reportBytes)
        let base = try makePack(
            boundDigests: [digest],
            artifacts: [utf8Artifact(bytes: reportBytes, sha256: digest)]
        )
        for badVersion in [0, -1] {
            let pack = ProofPackDocument(
                proofPackVersion: badVersion, attestation: base.attestation, artifacts: base.artifacts
            )
            let result = pack.verify()
            XCTAssertFalse(result.isValid, "version \(badVersion) must be rejected")
            XCTAssertEqual(result.failure, .unsupportedVersion)
            XCTAssertNil(result.bindingStrength, "an invalid pack has no binding strength")
        }
    }

    func testMixedGenuineAndRelabeledArtifactsFailUnderV2() throws {
        // Two artifacts sharing the recorded role: the first genuine, the second relabeled.
        // One bad binding must fail the whole pack (fail-closed), not pass on the good one.
        let genuineBytes = reportBytes
        let genuineDigest = hex(genuineBytes)
        let otherBytes = Data(#"{"claims":[{"id":"c2","verdict":"refuted"}]}"#.utf8)
        let otherDigest = hex(otherBytes)
        let pack = try makePack(
            boundDigests: [genuineDigest, otherDigest],
            artifacts: [
                utf8Artifact(bytes: genuineBytes, sha256: genuineDigest),  // role "claim-proof-report" ✓
                ProofPackArtifact(role: "board-approved-final", mediaType: "application/json",
                                  encoding: .utf8, content: String(decoding: otherBytes, as: UTF8.self),
                                  sha256: otherDigest),                     // relabeled ✗
            ]
        )
        let result = pack.verify()
        XCTAssertFalse(result.isValid, "one unvouched role must fail the whole pack")
        XCTAssertEqual(result.failure, .artifactNotBound(index: 1))
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
        // The committed v1 vector still verifies, but its role is producer-asserted.
        XCTAssertEqual(result.bindingStrength, .valuePresenceOnly)
    }

    func testPublicProofPackVectorV2Verifies() throws {
        let data = try Data(contentsOf: vectorURL(version: 2))
        let pack = try ProofPackDocument.decodeJSON(data)

        let result = pack.verify()
        XCTAssertTrue(result.isValid, result.failure.map(String.init(describing:)) ?? "unknown failure")
        XCTAssertEqual(pack.proofPackVersion, 2)
        XCTAssertEqual(result.bindings.count, pack.artifacts.count)
        XCTAssertEqual(result.bindingStrength, .roleBound, "the v2 vector's role must be signer-vouched")
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
        // Pinned to v1 explicitly: this vector is the legacy digest-only binding, kept so
        // the verifier's v1 acceptance stays covered. New packs default to v2.
        let pack = ProofPackDocument(
            proofPackVersion: 1,
            attestation: document,
            artifacts: [utf8Artifact(bytes: artifactBytes, sha256: digest)]
        )
        XCTAssertTrue(pack.verify().isValid)

        try pack.jsonData().write(to: vectorURL(version: 1), options: .atomic)
    }

    func testGenerateProofPackVectorV2() throws {
        guard ProcessInfo.processInfo.environment["DPK_GENERATE_PROOF_PACK_VECTOR"] == "1" else {
            throw XCTSkip("Vector generator — set DPK_GENERATE_PROOF_PACK_VECTOR=1 to regenerate")
        }

        let artifactBytes = Data(
            #"{"claims":[{"id":"c1","verdict":"supported"},{"id":"c2","verdict":"refuted"}]}"#.utf8
        )
        let digest = hex(artifactBytes)
        let key = try SoftwareTraceAttestationKey(
            rawRepresentation: Data((1...32).map { UInt8($0) })
        )
        let document = try TraceAttestationDocument.signed(
            run: makeRun(boundDigests: [digest]),
            using: key,
            issuedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )
        // Default version → v2. makeRun records {role: "claim-proof-report", sha256: digest}
        // co-located, matching the artifact's role, so the role is signer-vouched.
        let pack = ProofPackDocument(
            attestation: document,
            artifacts: [utf8Artifact(bytes: artifactBytes, sha256: digest)]
        )
        let result = pack.verify()
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.bindingStrength, .roleBound)

        try pack.jsonData().write(to: vectorURL(version: 2), options: .atomic)
    }

    // MARK: - Fixtures

    private func vectorURL(version: Int = 1) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs")
            .appendingPathComponent("test-vectors")
            .appendingPathComponent("proof-pack-v\(version).json")
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
