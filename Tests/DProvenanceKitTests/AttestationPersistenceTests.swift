import Foundation
import XCTest
@testable import DProvenanceKit

/// Coverage for drift-proof local re-verification (enhancement #2): the SQLite store
/// persists the signed `TraceAttestationDocument` and re-verifies against its FROZEN
/// canonical bytes, never re-encoding the payload at verify time. That is what keeps a
/// genuine attestation valid across an app restart or an OS/Swift upgrade, even if
/// Foundation's `JSONEncoder` output drifts between versions.
final class AttestationPersistenceTests: XCTestCase {

    /// A payload whose canonical JSON is sensitive to encoder configuration: the URL
    /// forward slashes are escaped by the store's record encoder (`[.sortedKeys]`
    /// escapes `/` as `\/`) but NOT by the attestation encoder
    /// (`[.sortedKeys, .withoutEscapingSlashes]`). That divergence already exists in the
    /// codebase and is a faithful, non-hypothetical stand-in for the kind of byte-level
    /// difference a Foundation version bump can introduce.
    private struct PolicyDecision: TraceableEvent {
        let typeIdentifier: String
        let uri: String
        let outcome: String
        let priority: TracePriority
    }

    private var storeURL: URL!

    override func setUp() {
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sqlite")
    }

    override func tearDown() {
        let base = storeURL.deletingLastPathComponent()
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(
                at: base.appendingPathComponent(storeURL.lastPathComponent + suffix))
        }
    }

    private func makeRun(runID: UUID) -> TraceRun<PolicyDecision> {
        let event = TraceEvent(
            runID: runID,
            contextID: "case-42",
            engineName: "OnDeviceAgent",
            schemaVersion: 1,
            sequence: 0,
            spanID: "decision",
            parentSpanID: nil,
            payload: PolicyDecision(
                typeIdentifier: "policy-check",
                uri: "https://example.com/policies/a/b",
                outcome: "allow",
                priority: .critical
            ),
            timestamp: Date(timeIntervalSince1970: 1_700_000_000.5)
        )
        return TraceRun(runID: runID, contextID: "case-42", events: [event])
    }

    /// A persisted attestation survives a full store teardown + reopen (the closest
    /// analog to an app relaunch or OS upgrade) and still verifies against a pinned key.
    func testStoredAttestationSurvivesStoreReopenAndVerifies() async throws {
        let runID = UUID()
        let keyID: String

        do {
            let store = try SQLiteTraceStore<PolicyDecision>(fileURL: storeURL)
            let run = makeRun(runID: runID)
            for event in run.events { store.record(event) }
            let fetched = try await store.getRun(id: runID)
            let hydrated = try XCTUnwrap(fetched)
            let document = try TraceAttestationDocument.signed(
                run: hydrated, using: SoftwareTraceAttestationKey())
            keyID = document.attestation.keyID
            try store.saveAttestation(document)
            _ = await store.close()
        }

        // A fresh store instance over the same file == the process relaunching.
        let reopened = try SQLiteTraceStore<PolicyDecision>(fileURL: storeURL)
        let result = try XCTUnwrap(
            try reopened.verifyStoredAttestation(runID: runID, trustedKeyIDs: [keyID]))
        XCTAssertTrue(result.isValid, result.failure?.rawValue ?? "unknown failure")
        XCTAssertEqual(result.trust, .trustedKey)
        _ = await reopened.close()
    }

    /// Verifying a run that was never attested returns `nil`, not a spurious pass/fail.
    func testVerifyStoredAttestationIsNilWhenAbsent() throws {
        let store = try SQLiteTraceStore<PolicyDecision>(fileURL: storeURL)
        XCTAssertNil(try store.verifyStoredAttestation(runID: UUID()))
    }

    /// The drift guard. Bytes that are JSON-equivalent to the signed payload but not
    /// byte-identical (slashes escaped, exactly as an older/other Foundation — or this
    /// store's own record encoder — would emit) must FAIL the digest, while the frozen
    /// persisted document still passes. This is the property that makes re-encoding at
    /// verify time unsafe and the persisted-bytes path safe.
    func testReEncodingDriftFailsDigestButFrozenDocumentSurvives() async throws {
        let runID = UUID()
        let store = try SQLiteTraceStore<PolicyDecision>(fileURL: storeURL)
        let run = makeRun(runID: runID)
        for event in run.events { store.record(event) }
        let fetched = try await store.getRun(id: runID)
        let hydrated = try XCTUnwrap(fetched)
        let document = try TraceAttestationDocument.signed(
            run: hydrated, using: SoftwareTraceAttestationKey())
        try store.saveAttestation(document)

        // The frozen canonical bytes keep slashes UNescaped (attestation encoder).
        let signedJSON = document.trace.events[0].payloadJSON
        XCTAssertTrue(signedJSON.contains("example.com/policies/a/b"),
                      "expected unescaped canonical payload, got: \(signedJSON)")

        // Simulate cross-version encoder drift: same JSON value, different bytes.
        // Re-hashing THESE bytes must fail — proving the digest is byte-exact.
        let drifted = driftEscapingSlashes(document.trace)
        XCTAssertNotEqual(drifted.events[0].payloadJSON, signedJSON, "drift must change bytes")
        let driftResult = TraceAttestationVerifier.verify(document.attestation, for: drifted)
        XCTAssertFalse(driftResult.isValid)
        XCTAssertEqual(driftResult.failure, .digestMismatch,
                       "re-encoded (drifted) bytes should fail the digest")

        // The persisted document verifies because it carries the exact signed bytes.
        let stored = try XCTUnwrap(try store.verifyStoredAttestation(runID: runID))
        XCTAssertTrue(stored.isValid, stored.failure?.rawValue ?? "unknown failure")
        _ = await store.close()
    }

    /// Airtight proof that verification consumes the frozen document, not a
    /// re-derivation from `trace_events`: it still verifies for a run whose event rows
    /// never existed. If `verifyStoredAttestation` re-hydrated + re-encoded the run, an
    /// empty event table would make this fail.
    func testVerifyStoredAttestationDoesNotDependOnEventRows() async throws {
        let runID = UUID()
        let store = try SQLiteTraceStore<PolicyDecision>(fileURL: storeURL)

        // Sign a run that is NEVER recorded into trace_events.
        let document = try TraceAttestationDocument.signed(
            run: makeRun(runID: runID), using: SoftwareTraceAttestationKey())
        try store.saveAttestation(document)

        let absent = try await store.getRun(id: runID)
        XCTAssertNil(absent, "no event rows should exist")

        let result = try XCTUnwrap(try store.verifyStoredAttestation(runID: runID))
        XCTAssertTrue(result.isValid, result.failure?.rawValue ?? "unknown failure")
        _ = await store.close()
    }

    /// Re-attesting a run replaces its stored document rather than duplicating it.
    func testReAttestingReplacesStoredDocument() async throws {
        let runID = UUID()
        let store = try SQLiteTraceStore<PolicyDecision>(fileURL: storeURL)
        let run = makeRun(runID: runID)

        let first = try TraceAttestationDocument.signed(
            run: run, using: SoftwareTraceAttestationKey())
        try store.saveAttestation(first)

        let secondKey = SoftwareTraceAttestationKey()
        let second = try TraceAttestationDocument.signed(run: run, using: secondKey)
        try store.saveAttestation(second)

        let loaded = try XCTUnwrap(try store.loadAttestation(runID: runID))
        XCTAssertEqual(loaded.attestation.keyID, second.attestation.keyID)
        XCTAssertTrue(loaded.verify(trustedKeyIDs: [second.attestation.keyID]).isValid)
        _ = await store.close()
    }

    /// Saving after `close()` is refused loudly, matching how post-close records are
    /// counted rather than silently written to a quiesced archive.
    func testSaveAfterCloseThrows() async throws {
        let runID = UUID()
        let store = try SQLiteTraceStore<PolicyDecision>(fileURL: storeURL)
        let document = try TraceAttestationDocument.signed(
            run: makeRun(runID: runID), using: SoftwareTraceAttestationKey())
        _ = await store.close()

        XCTAssertThrowsError(try store.saveAttestation(document)) { error in
            guard case TraceError.storeClosed = error else {
                return XCTFail("expected TraceError.storeClosed, got \(error)")
            }
        }
    }

    /// Rewrites every payloadJSON to escape forward slashes (`/` -> `\/`) without changing
    /// the JSON value — a faithful stand-in for Foundation output drift across OS versions
    /// (and, concretely, exactly what this store's own record encoder emits).
    private func driftEscapingSlashes(_ trace: AttestableTrace) -> AttestableTrace {
        let drifted = trace.events.map { event in
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
                payloadJSON: event.payloadJSON.replacingOccurrences(of: "/", with: "\\/"),
                timestampUnixMicroseconds: event.timestampUnixMicroseconds
            )
        }
        return AttestableTrace(
            runID: trace.runID,
            contextID: trace.contextID,
            events: drifted,
            edges: trace.edges
        )
    }
}
