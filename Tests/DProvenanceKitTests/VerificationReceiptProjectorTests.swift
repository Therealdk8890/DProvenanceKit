import CryptoKit
import Foundation
import XCTest
@testable import DProvenanceKit

/// Phase 1C: `ProofPackDocument` → `claim-path-v1` → `VerificationReceipt`.
/// Golden fixtures under `fixtures/verification-receipt/` lock status semantics.
/// Packs are real and go through the projector — status is never hard-coded without
/// evaluating integrity + invariant.
final class VerificationReceiptProjectorTests: XCTestCase {
    private struct TestEvent: TraceableEvent {
        struct ArtifactRef: Codable, Sendable, Equatable {
            let role: String
            let sha256: String
        }

        let typeIdentifier: String
        let artifacts: [ArtifactRef]
        let priority: TracePriority
    }

    private let claimText = "The filing was submitted on May 14, 2025."

    // MARK: - Fixture Codable / invariant lock

    func testClaimPathV1MatchesFixtureExactly() throws {
        let data = try Data(contentsOf: fixtureURL("invariant-claim-path-v1.json"))
        let loaded = try VerificationInvariant.decodeJSON(data)
        XCTAssertEqual(loaded, .claimPathV1)
        XCTAssertEqual(loaded.id, "claim-path-v1")
        XCTAssertEqual(loaded.requiredSteps, [.evidence, .extract, .verify, .claim])
        XCTAssertEqual(loaded.mustInclude, [.verify])
        XCTAssertEqual(loaded.ordering.count, 3)
    }

    func testGoldenReceiptFixturesDecodeAndStatusMatchesFilename() throws {
        let cases: [(String, VerificationReceipt.Status)] = [
            ("verified.json", .verified),
            ("incomplete.json", .incomplete),
            ("tampered.json", .tampered)
        ]
        for (name, expected) in cases {
            let receipt = try VerificationReceipt.decodeJSON(Data(contentsOf: fixtureURL(name)))
            XCTAssertEqual(receipt.status, expected, name)
            XCTAssertEqual(receipt.invariantID, "claim-path-v1", name)
            XCTAssertEqual(receipt.projection.from, "proof_pack", name)
            XCTAssertEqual(receipt.version, "1.0", name)
            if expected == .verified {
                XCTAssertTrue(receipt.integrity.allPassed, name)
                XCTAssertNil(receipt.statusReason, name)
            } else {
                XCTAssertNotNil(receipt.statusReason, name)
            }
        }
    }

    func testGoldenReceiptRoundTripCodable() throws {
        for name in ["verified.json", "incomplete.json", "tampered.json"] {
            let original = try VerificationReceipt.decodeJSON(Data(contentsOf: fixtureURL(name)))
            let encoded = try original.jsonData(prettyPrinted: false)
            let roundTripped = try VerificationReceipt.decodeJSON(encoded)
            XCTAssertEqual(roundTripped, original, name)
        }
        let inv = try VerificationInvariant.decodeJSON(
            Data(contentsOf: fixtureURL("invariant-claim-path-v1.json"))
        )
        let invRound = try VerificationInvariant.decodeJSON(inv.jsonData(prettyPrinted: false))
        XCTAssertEqual(invRound, inv)
    }

    // MARK: - Projector: verified / incomplete / tampered via real ProofPack

    func testProjectorVerifiedFromValidPackAndFullSteps() throws {
        let (pack, _) = try makeValidPack()
        XCTAssertTrue(pack.verify().isValid)

        let receipt = VerificationReceiptProjector.project(
            pack: pack,
            claimText: claimText,
            steps: VerificationReceiptProjector.claimPathSteps(includeVerify: true)
        )

        XCTAssertEqual(receipt.status, .verified)
        XCTAssertNil(receipt.statusReason)
        XCTAssertTrue(receipt.integrity.allPassed)
        XCTAssertEqual(receipt.invariantID, "claim-path-v1")
        XCTAssertEqual(receipt.projection.from, "proof_pack")
        XCTAssertEqual(receipt.projection.proofPackVersion, 2)
        XCTAssertEqual(receipt.steps.map(\.type), [.evidence, .extract, .verify, .claim])
        XCTAssertEqual(receipt.claim.text, claimText)
        XCTAssertFalse(receipt.sources.isEmpty)
        XCTAssertEqual(receipt.attestation.contextID, pack.attestation.attestation.contextID)
        XCTAssertEqual(receipt.attestation.traceDigest, pack.attestation.attestation.traceDigest)
        XCTAssertEqual(receipt.attestation.keyID, pack.attestation.attestation.keyID)
    }

    func testProjectorIncompleteWhenVerifyStepMissing() throws {
        let (pack, _) = try makeValidPack()
        XCTAssertTrue(pack.verify().isValid)

        let receipt = pack.verificationReceipt(
            claimText: claimText,
            steps: VerificationReceiptProjector.claimPathSteps(includeVerify: false)
        )

        XCTAssertEqual(receipt.status, .incomplete)
        XCTAssertTrue(receipt.integrity.allPassed, "incomplete requires integrity OK")
        XCTAssertEqual(
            receipt.statusReason,
            "Required step type verify is missing; claim-path-v1 invariant is not satisfied."
        )
        XCTAssertFalse(receipt.steps.map(\.type).contains(.verify))
        XCTAssertEqual(receipt.invariantID, "claim-path-v1")

        let eval = VerificationInvariant.claimPathV1.evaluate(steps: receipt.steps)
        XCTAssertFalse(eval.satisfied)
    }

    func testProjectorTamperedWhenArtifactDigestMismatch() throws {
        let (validPack, digest) = try makeValidPack()
        XCTAssertTrue(validPack.verify().isValid)

        let tamperedBytes = Data(#"{"claims":[{"id":"c1","verdict":"refuted"}]}"#.utf8)
        let tamperedPack = ProofPackDocument(
            proofPackVersion: validPack.proofPackVersion,
            attestation: validPack.attestation,
            artifacts: [
                ProofPackArtifact(
                    role: validPack.artifacts[0].role,
                    mediaType: validPack.artifacts[0].mediaType,
                    encoding: .utf8,
                    content: String(decoding: tamperedBytes, as: UTF8.self),
                    sha256: digest
                )
            ]
        )
        let verifyResult = tamperedPack.verify()
        XCTAssertFalse(verifyResult.isValid)
        XCTAssertEqual(verifyResult.failure, .artifactDigestMismatch(index: 0))

        let receipt = VerificationReceiptProjector.project(
            pack: tamperedPack,
            claimText: claimText,
            // Full steps on purpose: tampered must win over a complete claim-path.
            steps: VerificationReceiptProjector.claimPathSteps(includeVerify: true)
        )

        XCTAssertEqual(receipt.status, .tampered)
        XCTAssertFalse(receipt.integrity.allPassed)
        XCTAssertFalse(receipt.integrity.evidence)
        XCTAssertFalse(receipt.integrity.filesUnchanged)
        XCTAssertEqual(
            receipt.statusReason,
            "Source content hash no longer matches the digest bound in the signed proof pack (files_unchanged=false); attestation integrity checks fail."
        )
    }

    func testProjectorTamperedWhenSourceDigestsDiverge() throws {
        let (pack, digest) = try makeValidPack()
        XCTAssertTrue(pack.verify().isValid)

        let otherDigest = hex(Data("mutated-source-bytes".utf8))
        XCTAssertNotEqual(otherDigest, digest)

        let receipt = VerificationReceiptProjector.project(
            pack: pack,
            claimText: claimText,
            steps: VerificationReceiptProjector.claimPathSteps(includeVerify: true),
            currentSourceDigestsByRole: [pack.artifacts[0].role: otherDigest]
        )

        XCTAssertEqual(receipt.status, .tampered)
        XCTAssertFalse(receipt.integrity.filesUnchanged)
        XCTAssertFalse(receipt.integrity.evidence)
    }

    func testTamperedTakesPrecedenceOverIncompleteSteps() throws {
        let (validPack, digest) = try makeValidPack()
        let tamperedBytes = Data(#"{"tampered":true}"#.utf8)
        let tamperedPack = ProofPackDocument(
            attestation: validPack.attestation,
            artifacts: [
                ProofPackArtifact(
                    role: validPack.artifacts[0].role,
                    mediaType: "application/json",
                    encoding: .utf8,
                    content: String(decoding: tamperedBytes, as: UTF8.self),
                    sha256: digest
                )
            ]
        )
        XCTAssertFalse(tamperedPack.verify().isValid)

        let receipt = VerificationReceiptProjector.project(
            pack: tamperedPack,
            claimText: claimText,
            steps: VerificationReceiptProjector.claimPathSteps(includeVerify: false)
        )

        XCTAssertEqual(receipt.status, .tampered)
        XCTAssertNotEqual(receipt.status, .incomplete)
    }

    // MARK: - Anti-hardcode / evaluator must run

    func testCannotGetVerifiedWithoutIntegrityAndInvariant() throws {
        let (pack, _) = try makeValidPack()

        let incomplete = VerificationReceiptProjector.project(
            pack: pack,
            claimText: claimText,
            steps: VerificationReceiptProjector.claimPathSteps(includeVerify: false)
        )
        XCTAssertNotEqual(incomplete.status, .verified)

        let (validPack, digest) = try makeValidPack()
        let bad = ProofPackDocument(
            attestation: validPack.attestation,
            artifacts: [
                ProofPackArtifact(
                    role: "claim-proof-report",
                    mediaType: "application/json",
                    encoding: .utf8,
                    content: #"{"x":1}"#,
                    sha256: digest
                )
            ]
        )
        let tampered = VerificationReceiptProjector.project(
            pack: bad,
            claimText: claimText,
            steps: VerificationReceiptProjector.claimPathSteps(includeVerify: true)
        )
        XCTAssertNotEqual(tampered.status, .verified)
        XCTAssertEqual(tampered.status, .tampered)
    }

    func testProjectedReceiptMatchesGoldenStatusSemantics() throws {
        let goldenVerified = try VerificationReceipt.decodeJSON(
            Data(contentsOf: fixtureURL("verified.json"))
        )
        let goldenIncomplete = try VerificationReceipt.decodeJSON(
            Data(contentsOf: fixtureURL("incomplete.json"))
        )
        let goldenTampered = try VerificationReceipt.decodeJSON(
            Data(contentsOf: fixtureURL("tampered.json"))
        )

        let (pack, digest) = try makeValidPack()

        let verified = pack.verificationReceipt(
            claimText: goldenVerified.claim.text,
            steps: goldenVerified.steps
        )
        XCTAssertEqual(verified.status, goldenVerified.status)
        XCTAssertEqual(verified.integrity, goldenVerified.integrity)
        XCTAssertEqual(verified.steps.map(\.type), goldenVerified.steps.map(\.type))

        let incomplete = pack.verificationReceipt(
            claimText: goldenIncomplete.claim.text,
            steps: goldenIncomplete.steps
        )
        XCTAssertEqual(incomplete.status, goldenIncomplete.status)
        XCTAssertEqual(incomplete.integrity, goldenIncomplete.integrity)
        XCTAssertEqual(incomplete.statusReason, goldenIncomplete.statusReason)

        let tamperedBytes = Data(#"{"claims":[{"id":"c1","verdict":"refuted"}]}"#.utf8)
        let tamperedPack = ProofPackDocument(
            attestation: pack.attestation,
            artifacts: [
                ProofPackArtifact(
                    role: pack.artifacts[0].role,
                    mediaType: "application/json",
                    encoding: .utf8,
                    content: String(decoding: tamperedBytes, as: UTF8.self),
                    sha256: digest
                )
            ]
        )
        let tampered = VerificationReceiptProjector.project(
            pack: tamperedPack,
            claimText: goldenTampered.claim.text,
            steps: goldenTampered.steps
        )
        XCTAssertEqual(tampered.status, goldenTampered.status)
        XCTAssertFalse(tampered.integrity.allPassed)
        XCTAssertEqual(tampered.steps.map(\.type), goldenTampered.steps.map(\.type))
        // Digest mismatch leaves attestation valid, so trace may stay true — status is
        // still tampered. Golden fixture uses a fail-closed all-false integrity summary.
        XCTAssertFalse(tampered.integrity.evidence)
        XCTAssertFalse(tampered.integrity.filesUnchanged)
    }

    func testInvariantOrderingViolationIsIncomplete() throws {
        let (pack, _) = try makeValidPack()
        let outOfOrder: [VerificationReceipt.Step] = [
            .init(type: .claim),
            .init(type: .verify),
            .init(type: .extract),
            .init(type: .evidence)
        ]
        let receipt = pack.verificationReceipt(claimText: claimText, steps: outOfOrder)
        XCTAssertEqual(receipt.status, .incomplete)
        XCTAssertTrue(receipt.statusReason?.contains("ordering") == true)
    }

    // MARK: - Fixtures / builders (mirrors ProofPackTests)

    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("fixtures")
            .appendingPathComponent("verification-receipt")
            .appendingPathComponent(name)
    }

    private func makeValidPack() throws -> (ProofPackDocument, String) {
        let reportBytes = Data(#"{"claims":[{"id":"c1","verdict":"supported"}]}"#.utf8)
        let digest = hex(reportBytes)
        let document = try TraceAttestationDocument.signed(
            run: makeRun(boundDigests: [digest]),
            using: SoftwareTraceAttestationKey(),
            issuedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )
        let pack = ProofPackDocument(
            attestation: document,
            artifacts: [
                ProofPackArtifact(
                    role: "claim-proof-report",
                    mediaType: "application/json",
                    encoding: .utf8,
                    content: String(decoding: reportBytes, as: UTF8.self),
                    sha256: digest
                )
            ]
        )
        return (pack, digest)
    }

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
                )
            ]
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
