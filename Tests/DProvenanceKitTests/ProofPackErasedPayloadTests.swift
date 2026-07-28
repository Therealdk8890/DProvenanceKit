// Copyright 2026 Daniel Kissel
// Licensed under the Apache License, Version 2.0. See LICENSE for details.

import Foundation
import XCTest
@testable import DProvenanceKit

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// `AnyTraceableEvent` carries its domain payload as a JSON *string* under `rawJSON`. Because
/// the proof-pack binding search walks parsed objects, a trace recorded through it used to be
/// entirely unbindable — DProvenanceKit's own erasure type defeated DProvenanceKit's own proof
/// packs, and every artifact came back `artifactNotBound` no matter how well-formed the trace.
///
/// These tests pin both halves of the fix: erased payloads now bind, and strings that merely
/// happen to parse as JSON still do not.
final class ProofPackErasedPayloadTests: XCTestCase {
    private let role = "claim-proof-report"
    private let reportBytes = Data(#"{"claims":[{"id":"c1","verdict":"supported"}]}"#.utf8)

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func artifact(role: String, sha256: String) -> ProofPackArtifact {
        ProofPackArtifact(
            role: role,
            mediaType: "application/json",
            encoding: .utf8,
            content: String(decoding: reportBytes, as: UTF8.self),
            sha256: sha256
        )
    }

    private func run<E: TraceableEvent>(payload: E) -> TraceRun<E> {
        let runID = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
        let contextID = "erased-case"
        return TraceRun(
            runID: runID,
            contextID: contextID,
            events: [
                TraceEvent(
                    id: UUID(uuidString: "40000000-0000-0000-0000-000000000002")!,
                    runID: runID,
                    contextID: contextID,
                    engineName: "ClaimProof",
                    schemaVersion: 1,
                    sequence: 0,
                    spanID: "report",
                    parentSpanID: nil,
                    payload: payload,
                    timestamp: Date(timeIntervalSince1970: 1_700_000_000.5)
                )
            ]
        )
    }

    private func bindingJSON(role: String, sha256: String) -> String {
        "{\"artifacts\":[{\"role\":\"\(role)\",\"sha256\":\"\(sha256)\"}]}"
    }

    private func erasedPayload(rawJSON: String) -> AnyTraceableEvent {
        AnyTraceableEvent(typeIdentifier: "artifact-emitted", priorityValue: 3, rawJSON: rawJSON)
    }

    /// A payload shape that is *not* `AnyTraceableEvent`, but whose single string field holds
    /// text that happens to parse as a valid binding object — the shape an application would
    /// produce by echoing user-controlled input into its trace.
    private struct LoggingEvent: TraceableEvent {
        let message: String
        var typeIdentifier: String { "log" }
        var priority: TracePriority { TracePriority(rawValue: 3) ?? .telemetry }
    }

    // MARK: - The fix

    func testErasedPayloadBindsRoleBound() throws {
        let sha = digest(reportBytes)
        let signed = try TraceAttestationDocument.signed(
            run: run(payload: erasedPayload(rawJSON: bindingJSON(role: role, sha256: sha))),
            using: SoftwareTraceAttestationKey()
        )
        let pack = ProofPackDocument(attestation: signed, artifacts: [artifact(role: role, sha256: sha)])

        let result = pack.verify()
        XCTAssertTrue(result.isValid, "failure: \(String(describing: result.failure))")
        XCTAssertEqual(result.bindingStrength, .roleBound)
        XCTAssertEqual(result.bindings.first?.eventTypeIdentifier, "artifact-emitted")
        XCTAssertEqual(result.bindings.first?.role, role)
    }

    func testErasedPayloadStillFailsWhenTheArtifactIsRelabelledAfterSigning() throws {
        let sha = digest(reportBytes)
        let signed = try TraceAttestationDocument.signed(
            run: run(payload: erasedPayload(rawJSON: bindingJSON(role: role, sha256: sha))),
            using: SoftwareTraceAttestationKey()
        )
        // The signature covers role `claim-proof-report`; the pack claims `court-filing`.
        let pack = ProofPackDocument(
            attestation: signed,
            artifacts: [artifact(role: "court-filing", sha256: sha)]
        )

        XCTAssertFalse(pack.verify().isValid, "unwrapping must not weaken v2 role binding")
    }

    func testErasedPayloadStillFailsWhenTheArtifactBytesAreSubstituted() throws {
        let sha = digest(reportBytes)
        let signed = try TraceAttestationDocument.signed(
            run: run(payload: erasedPayload(rawJSON: bindingJSON(role: role, sha256: sha))),
            using: SoftwareTraceAttestationKey()
        )
        var tampered = reportBytes
        tampered.append(0x20)
        let pack = ProofPackDocument(attestation: signed, artifacts: [
            ProofPackArtifact(
                role: role,
                mediaType: "application/json",
                encoding: .utf8,
                content: String(decoding: tampered, as: UTF8.self),
                sha256: digest(tampered)
            )
        ])

        XCTAssertFalse(pack.verify().isValid)
    }

    // MARK: - The security boundary

    /// The reason unwrapping is restricted to `AnyTraceableEvent`'s exact shape rather than
    /// "any string that parses as JSON". An application that logs attacker-supplied text must
    /// not thereby sign a role/digest pair it never intended to vouch for.
    func testAStringThatMerelyParsesAsJSONIsNotBindingMaterial() throws {
        let sha = digest(reportBytes)
        let hostile = bindingJSON(role: role, sha256: sha)
        let signed = try TraceAttestationDocument.signed(
            run: run(payload: LoggingEvent(message: hostile)),
            using: SoftwareTraceAttestationKey()
        )
        let pack = ProofPackDocument(attestation: signed, artifacts: [artifact(role: role, sha256: sha)])

        let result = pack.verify()
        XCTAssertFalse(result.isValid, "user-controlled text must never become binding material")
        XCTAssertEqual(result.failure, .artifactNotBound(index: 0))
    }
}
