import XCTest
@testable import DProvenanceKit
import Foundation

/// Structural validation of an attestation's lineage edge set. Events were already
/// validated individually, but the edge list used to be accepted verbatim — an
/// attestor would sign (and a verifier certify) self-loops, repeated edges, and
/// edges with no relation to the attested run.
///
/// Cross-run lineage is legitimate: upstream edges may reference events archived in
/// other runs, including chains whose middle hops never touch this run's events
/// directly. What is rejected is an edge (or component) with NO connection to the
/// run through the edge graph.
final class TraceAttestationEdgeValidationTests: XCTestCase {
    private func makeEvent(id: UUID, runID: UUID, sequence: UInt64) -> AttestableTraceEvent {
        AttestableTraceEvent(
            id: id, runID: runID, contextID: "ctx", engineName: "engine",
            schemaVersion: 1, sequence: sequence, spanID: nil, parentSpanID: nil,
            typeIdentifier: "step", priority: TracePriority.structural.rawValue,
            payloadJSON: #"{"k":"v"}"#, timestampUnixMicroseconds: Int64(sequence)
        )
    }

    private func makeTrace(edges: [TraceEdge], eventIDs: [UUID], runID: UUID = UUID()) -> AttestableTrace {
        AttestableTrace(
            runID: runID,
            contextID: "ctx",
            events: eventIDs.enumerated().map { makeEvent(id: $1, runID: runID, sequence: UInt64($0)) },
            edges: edges
        )
    }

    private func assertSigningFails(
        _ trace: AttestableTrace,
        with expected: (TraceAttestationError) -> Bool,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try TraceAttestor.attest(trace: trace, using: SoftwareTraceAttestationKey()),
            message, file: file, line: line
        ) { error in
            guard let attestationError = error as? TraceAttestationError, expected(attestationError) else {
                return XCTFail("unexpected error: \(error)", file: file, line: line)
            }
        }
    }

    func testSelfReferentialEdgeIsRejectedAtSigning() {
        let a = UUID()
        let trace = makeTrace(edges: [TraceEdge(sourceID: a, targetID: a, type: .derivedFrom)], eventIDs: [a])
        assertSigningFails(trace, with: {
            if case .selfReferentialEdge = $0 { return true } else { return false }
        }, "an event cannot be its own lineage")
    }

    func testDuplicateEdgeIsRejectedAtSigning() {
        let a = UUID(), b = UUID()
        let edge = TraceEdge(sourceID: b, targetID: a, type: .derivedFrom)
        let trace = makeTrace(edges: [edge, edge], eventIDs: [a, b])
        assertSigningFails(trace, with: {
            if case .duplicateEdge = $0 { return true } else { return false }
        }, "the same edge listed twice is a construction error")
    }

    func testDanglingEdgeIsRejectedAtSigning() {
        let a = UUID()
        let unrelated = TraceEdge(sourceID: UUID(), targetID: UUID(), type: .informed)
        let trace = makeTrace(edges: [unrelated], eventIDs: [a])
        assertSigningFails(trace, with: {
            if case .danglingEdge = $0 { return true } else { return false }
        }, "an edge with no connection to the attested run must not be signed into it")
    }

    func testCrossRunLineageChainAnchoredToTheRunIsAccepted() throws {
        // externalB and externalC live in OTHER runs (exactly what upstream
        // lineageEdges(of:) returns); the chain anchors to the run through eventA.
        let eventA = UUID(), externalB = UUID(), externalC = UUID()
        let trace = makeTrace(
            edges: [
                TraceEdge(sourceID: externalB, targetID: eventA, type: .derivedFrom),
                TraceEdge(sourceID: externalC, targetID: externalB, type: .derivedFrom),
            ],
            eventIDs: [eventA]
        )
        let attestation = try TraceAttestor.attest(trace: trace, using: SoftwareTraceAttestationKey())
        let result = TraceAttestationVerifier.verify(attestation, for: trace)
        XCTAssertTrue(result.isValid)
        XCTAssertNil(result.failure)
    }

    func testReversedOrderChainRequiresMultiPassAnchoring() throws {
        // Listed far-end first: [C→B, B→A]. C→B anchors nothing on the first pass;
        // only after B→A anchors B can C→B anchor. Pins the fixpoint loop — a
        // single-pass implementation would wrongly reject this legitimate chain.
        let eventA = UUID(), externalB = UUID(), externalC = UUID()
        let trace = makeTrace(
            edges: [
                TraceEdge(sourceID: externalC, targetID: externalB, type: .derivedFrom),
                TraceEdge(sourceID: externalB, targetID: eventA, type: .derivedFrom),
            ],
            eventIDs: [eventA]
        )
        let attestation = try TraceAttestor.attest(trace: trace, using: SoftwareTraceAttestationKey())
        XCTAssertTrue(TraceAttestationVerifier.verify(attestation, for: trace).isValid)
    }

    func testDisconnectedMultiEdgeComponentIsRejected() {
        // A component that is internally connected (X→Y, Y→Z) but touches nothing in
        // the run must still be rejected — mutual anchoring between unrelated edges
        // must not satisfy the fixpoint.
        let eventA = UUID(), externalB = UUID()
        let x = UUID(), y = UUID(), z = UUID()
        let trace = makeTrace(
            edges: [
                TraceEdge(sourceID: externalB, targetID: eventA, type: .derivedFrom), // anchored
                TraceEdge(sourceID: x, targetID: y, type: .informed),                 // island
                TraceEdge(sourceID: y, targetID: z, type: .informed),                 // island
            ],
            eventIDs: [eventA]
        )
        assertSigningFails(trace, with: {
            if case .danglingEdge = $0 { return true } else { return false }
        }, "an island of mutually-connected edges unrelated to the run must not be signed")
    }

    func testVerificationRejectsStructurallyInvalidEdgeSets() throws {
        // A document signed with sound edges, then presented with a tampered edge set,
        // must fail on STRUCTURE (self/duplicate/dangling), before digest comparison.
        let a = UUID(), b = UUID()
        let sound = makeTrace(edges: [TraceEdge(sourceID: b, targetID: a, type: .derivedFrom)], eventIDs: [a, b])
        let attestation = try TraceAttestor.attest(trace: sound, using: SoftwareTraceAttestationKey())

        let selfLoop = AttestableTrace(
            runID: sound.runID, contextID: sound.contextID, events: sound.events,
            edges: [TraceEdge(sourceID: a, targetID: a, type: .derivedFrom)]
        )
        XCTAssertEqual(TraceAttestationVerifier.verify(attestation, for: selfLoop).failure, .selfReferentialEdge)

        let dangling = AttestableTrace(
            runID: sound.runID, contextID: sound.contextID, events: sound.events,
            edges: [TraceEdge(sourceID: UUID(), targetID: UUID(), type: .informed)]
        )
        XCTAssertEqual(TraceAttestationVerifier.verify(attestation, for: dangling).failure, .danglingEdge)

        let original = TraceEdge(sourceID: b, targetID: a, type: .derivedFrom)
        let duplicated = AttestableTrace(
            runID: sound.runID, contextID: sound.contextID, events: sound.events,
            edges: [original, original]
        )
        XCTAssertEqual(TraceAttestationVerifier.verify(attestation, for: duplicated).failure, .duplicateEdge)
    }

    func testEdgelessTraceStillSignsAndVerifies() throws {
        let trace = makeTrace(edges: [], eventIDs: [UUID()])
        let attestation = try TraceAttestor.attest(trace: trace, using: SoftwareTraceAttestationKey())
        XCTAssertTrue(TraceAttestationVerifier.verify(attestation, for: trace).isValid)
    }
}
