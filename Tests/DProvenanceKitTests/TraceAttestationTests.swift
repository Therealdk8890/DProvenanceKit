import Foundation
import XCTest
@testable import DProvenanceKit

final class TraceAttestationTests: XCTestCase {
    private struct TestEvent: TraceableEvent {
        let typeIdentifier: String
        let value: String
        let priority: TracePriority
    }

    func testSoftwareKeyAttestationVerifiesWithEmbeddedAndPinnedKey() throws {
        let run = makeRun()
        let key = SoftwareTraceAttestationKey()
        let document = try TraceAttestationDocument.signed(
            run: run,
            edges: makeEdges(run: run),
            using: key,
            issuedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )

        let embedded = document.verify()
        XCTAssertTrue(embedded.isValid)
        XCTAssertEqual(embedded.trust, .embeddedKeyOnly)
        XCTAssertNil(embedded.failure)

        let pinned = document.verify(trustedKeyIDs: [document.attestation.keyID])
        XCTAssertTrue(pinned.isValid)
        XCTAssertEqual(pinned.trust, .trustedKey)
    }

    func testUnknownPinnedKeyIsRejected() throws {
        let document = try makeDocument()
        let result = document.verify(trustedKeyIDs: [String(repeating: "0", count: 64)])

        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.failure, .untrustedKey)
    }

    func testPayloadModificationIsDetected() throws {
        let document = try makeDocument()
        var events = document.trace.events
        let original = events[0]
        events[0] = copy(original, payloadJSON: original.payloadJSON.replacingOccurrences(
            of: "allow",
            with: "deny"
        ))
        let tampered = AttestableTrace(
            runID: document.trace.runID,
            contextID: document.trace.contextID,
            events: events,
            edges: document.trace.edges
        )

        let result = TraceAttestationVerifier.verify(document.attestation, for: tampered)
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.failure, .digestMismatch)
    }

    func testEventDeletionIsDetected() throws {
        let document = try makeDocument()
        let tampered = AttestableTrace(
            runID: document.trace.runID,
            contextID: document.trace.contextID,
            events: Array(document.trace.events.dropLast()),
            edges: document.trace.edges
        )

        let result = TraceAttestationVerifier.verify(document.attestation, for: tampered)
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.failure, .eventCountMismatch)
    }

    func testEventReorderingIsDetected() throws {
        let document = try makeDocument()
        let tampered = AttestableTrace(
            runID: document.trace.runID,
            contextID: document.trace.contextID,
            events: Array(document.trace.events.reversed()),
            edges: document.trace.edges
        )

        let result = TraceAttestationVerifier.verify(document.attestation, for: tampered)
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.failure, .nonMonotonicSequence)
    }

    func testEdgeDeletionIsDetected() throws {
        let document = try makeDocument()
        let tampered = AttestableTrace(
            runID: document.trace.runID,
            contextID: document.trace.contextID,
            events: document.trace.events,
            edges: []
        )

        let result = TraceAttestationVerifier.verify(document.attestation, for: tampered)
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.failure, .edgeCountMismatch)
    }

    func testEnvelopeModificationInvalidatesSignature() throws {
        let document = try makeDocument()
        let original = document.attestation
        let tampered = TraceAttestation(
            version: original.version,
            algorithm: original.algorithm,
            canonicalization: original.canonicalization,
            runID: original.runID,
            contextID: original.contextID,
            eventCount: original.eventCount,
            edgeCount: original.edgeCount,
            traceDigest: original.traceDigest,
            issuedAtUnixMicroseconds: original.issuedAtUnixMicroseconds + 1,
            keyID: original.keyID,
            publicKeyBase64: original.publicKeyBase64,
            signatureBase64: original.signatureBase64
        )

        let result = TraceAttestationVerifier.verify(tampered, for: document.trace)
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.failure, .invalidSignature)
    }

    func testDocumentJSONRoundTripPreservesVerification() throws {
        let document = try makeDocument()
        let data = try document.jsonData()
        let decoded = try TraceAttestationDocument.decodeJSON(data)

        XCTAssertEqual(decoded, document)
        XCTAssertTrue(decoded.verify().isValid)
    }

    func testAttestorRejectsEventFromDifferentRun() throws {
        let document = try makeDocument()
        var events = document.trace.events
        let original = events[0]
        events[0] = AttestableTraceEvent(
            id: original.id,
            runID: uuid("ffffffff-ffff-ffff-ffff-ffffffffffff"),
            contextID: original.contextID,
            engineName: original.engineName,
            schemaVersion: original.schemaVersion,
            sequence: original.sequence,
            spanID: original.spanID,
            parentSpanID: original.parentSpanID,
            typeIdentifier: original.typeIdentifier,
            priority: original.priority,
            payloadJSON: original.payloadJSON,
            timestampUnixMicroseconds: original.timestampUnixMicroseconds
        )
        let malformed = AttestableTrace(
            runID: document.trace.runID,
            contextID: document.trace.contextID,
            events: events,
            edges: document.trace.edges
        )

        XCTAssertThrowsError(try TraceAttestor.attest(
            trace: malformed,
            using: SoftwareTraceAttestationKey()
        )) { error in
            guard case TraceAttestationError.eventRunIDMismatch(original.id) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testPublicAttestationVectorVerifies() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let vectorURL = repositoryRoot
            .appendingPathComponent("docs")
            .appendingPathComponent("test-vectors")
            .appendingPathComponent("attestation-v1.json")
        let data = try Data(contentsOf: vectorURL)
        let document = try TraceAttestationDocument.decodeJSON(data)

        let result = document.verify()
        XCTAssertTrue(result.isValid, result.failure?.rawValue ?? "unknown failure")
        XCTAssertEqual(document.attestation.version, 1)
        XCTAssertEqual(document.attestation.algorithm, .p256SHA256)
        XCTAssertEqual(document.attestation.canonicalization, .dpkBinaryV1)
    }

    func testSecureEnclaveKeySignsWhenHardwareIsAvailable() throws {
        guard SecureEnclaveTraceAttestationKey.isAvailable else { return }

        let key = try SecureEnclaveTraceAttestationKey()
        let document = try TraceAttestationDocument.signed(run: makeRun(), using: key)
        XCTAssertTrue(document.verify().isValid)
    }

    private func makeDocument() throws -> TraceAttestationDocument {
        let run = makeRun()
        return try TraceAttestationDocument.signed(
            run: run,
            edges: makeEdges(run: run),
            using: SoftwareTraceAttestationKey(),
            issuedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
    }

    private func makeRun() -> TraceRun<TestEvent> {
        let runID = uuid("10000000-0000-0000-0000-000000000001")
        let firstID = uuid("20000000-0000-0000-0000-000000000001")
        let secondID = uuid("20000000-0000-0000-0000-000000000002")
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000.123456)

        return TraceRun(
            runID: runID,
            contextID: "regulated-case-17",
            events: [
                TraceEvent(
                    id: firstID,
                    runID: runID,
                    contextID: "regulated-case-17",
                    engineName: "OnDeviceAgent",
                    schemaVersion: 1,
                    sequence: 0,
                    spanID: "decision",
                    parentSpanID: nil,
                    payload: TestEvent(
                        typeIdentifier: "policy-check",
                        value: "allow",
                        priority: .structural
                    ),
                    timestamp: timestamp
                ),
                TraceEvent(
                    id: secondID,
                    runID: runID,
                    contextID: "regulated-case-17",
                    engineName: "OnDeviceAgent",
                    schemaVersion: 1,
                    sequence: 1,
                    spanID: "decision",
                    parentSpanID: nil,
                    payload: TestEvent(
                        typeIdentifier: "final-decision",
                        value: "approved",
                        priority: .critical
                    ),
                    timestamp: timestamp.addingTimeInterval(0.25)
                )
            ]
        )
    }

    private func makeEdges(run: TraceRun<TestEvent>) -> [TraceEdge] {
        [TraceEdge(
            sourceID: run.events[0].id,
            targetID: run.events[1].id,
            type: .verifiedBy
        )]
    }

    private func copy(
        _ event: AttestableTraceEvent,
        payloadJSON: String
    ) -> AttestableTraceEvent {
        AttestableTraceEvent(
            id: event.id,
            runID: event.runID,
            contextID: event.contextID,
            engineName: event.engineName,
            schemaVersion: event.schemaVersion,
            sequence: event.sequence,
            spanID: event.spanID,
            parentSpanID: event.parentSpanID,
            typeIdentifier: event.typeIdentifier,
            priority: event.priority,
            payloadJSON: payloadJSON,
            timestampUnixMicroseconds: event.timestampUnixMicroseconds
        )
    }

    private func uuid(_ value: String) -> UUID {
        guard let id = UUID(uuidString: value) else {
            XCTFail("Invalid UUID fixture: \(value)")
            return UUID()
        }
        return id
    }
}
