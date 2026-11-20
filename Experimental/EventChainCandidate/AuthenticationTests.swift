import CryptoKit
import Foundation

private struct AttestationFixture: Decodable {
    struct Header: Decodable { let traceDigest: String }
    struct Event: Decodable {
        let id: String
        let runID: String
        let contextID: String
        let engineName: String
        let schemaVersion: Int64
        let sequence: UInt64
        let spanID: String?
        let parentSpanID: String?
        let typeIdentifier: String
        let priority: Int64
        let payloadJSON: String
        let timestampUnixMicroseconds: Int64

        func normalized() -> ChainEvent {
            ChainEvent(eventID: id, runID: runID, contextID: contextID, engineName: engineName,
                       schemaVersion: schemaVersion, eventSequence: sequence, spanID: spanID,
                       parentSpanID: parentSpanID, typeIdentifier: typeIdentifier, priority: priority,
                       payloadJSON: payloadJSON, timestampUnixMicroseconds: timestampUnixMicroseconds)
        }
    }
    struct Trace: Decodable {
        let runID: String
        let contextID: String
        let events: [Event]
    }
    let attestation: Header
    let trace: Trace
}

private func authRejects(_ expected: AuthenticationFailure, _ operation: () throws -> Void) throws {
    do {
        try operation()
    } catch let error as AuthenticationFailure {
        try check(error == expected, "expected \(expected), got \(error)")
        return
    }
    throw TestFailure.assertion("accepted invalid authentication: \(expected)")
}

func testAuthentication(_ directory: URL) throws {
    let fixture = try JSONDecoder().decode(
        AttestationFixture.self, from: Data(contentsOf: directory.appendingPathComponent("attestation-v1.json"))
    )
    let run = fixture.trace.runID
    let events = fixture.trace.events.map { $0.normalized() }
    var builder = try ChainBuilder(runID: run)
    for event in events { try builder.append(event) }
    let chain = builder.snapshot()
    let original = CoveredTrace(runID: run, contextID: fixture.trace.contextID, events: events, edges: [])
    let digest = try ChainCodec.digest(ClosureAuthentication.traceBytes(chain, original, expectedRunID: run))
    try check(hex(digest) == fixture.attestation.traceDigest, "existing DPK attestation digest")
    guard events.count >= 2 else { throw TestFailure.assertion("missing trace events") }
    let edge = TraceEdge(sourceID: events[0].eventID, targetID: events[1].eventID, type: "derivedFrom")
    let trace = CoveredTrace(runID: run, contextID: original.contextID, events: events, edges: [edge])
    let key = P256.Signing.PrivateKey()
    let other = P256.Signing.PrivateKey()
    let raw = key.publicKey.x963Representation
    let pin = ChainCodec.digest(raw)
    let signed = try ClosureAuthentication.sign(
        chain, trace, expectedRunID: run, issuedAt: 123, publicKeyX963: raw
    ) { try key.signature(for: $0).derRepresentation }
    try ClosureAuthentication.verify(chain, trace, signed, expectedRunID: run,
                                     trustedKeyID: pin, requireEvidence: true)
    try authRejects(.untrustedKey) {
        try ClosureAuthentication.verify(chain, trace, signed, expectedRunID: run,
                                         trustedKeyID: ChainCodec.digest(other.publicKey.x963Representation))
    }
    var bad = signed
    bad.publicKeyX963 = other.publicKey.x963Representation
    try authRejects(.keyMismatch) {
        try ClosureAuthentication.verify(chain, trace, bad, expectedRunID: run, trustedKeyID: pin)
    }
    bad = signed
    bad.signatureDER = Data([1, 2, 3])
    try authRejects(.invalidSignature) {
        try ClosureAuthentication.verify(chain, trace, bad, expectedRunID: run, trustedKeyID: pin)
    }
    bad = signed
    bad.close.issuedAtUnixMicroseconds += 1
    try authRejects(.invalidSignature) {
        try ClosureAuthentication.verify(chain, trace, bad, expectedRunID: run, trustedKeyID: pin)
    }
    try authRejects(.traceMismatch) {
        try ClosureAuthentication.verify(chain, original, signed, expectedRunID: run, trustedKeyID: pin)
    }
    let duplicate = CoveredTrace(runID: run, contextID: trace.contextID, events: events, edges: [edge, edge])
    try authRejects(.invalidEdge) {
        _ = try ClosureAuthentication.traceBytes(chain, duplicate, expectedRunID: run)
    }
    var prefix = try ChainBuilder(runID: run)
    for event in events.dropLast() { try prefix.append(event) }
    try rejects(.closureMismatch) {
        try ClosureAuthentication.verify(prefix.snapshot(), trace, signed, expectedRunID: run, trustedKeyID: pin)
    }
    var replacement = try ChainBuilder(runID: run)
    for (index, event) in events.enumerated() {
        var modified = event
        if index == 0 { modified.payloadJSON = "{}" }
        try replacement.append(modified)
    }
    try rejects(.closureMismatch) {
        try ClosureAuthentication.verify(
            replacement.snapshot(), trace, signed, expectedRunID: run, trustedKeyID: pin
        )
    }
    try authRejects(.invalidSignature) {
        _ = try ClosureAuthentication.sign(chain, trace, expectedRunID: run, issuedAt: 123, publicKeyX963: raw) {
            try other.signature(for: $0).derRepresentation
        }
    }
    let empty = try ChainBuilder(runID: run).snapshot()
    let emptyTrace = CoveredTrace(runID: run, contextID: "empty", events: [], edges: [])
    let emptySigned = try ClosureAuthentication.sign(
        empty, emptyTrace, expectedRunID: run, issuedAt: 123, publicKeyX963: raw
    ) { try key.signature(for: $0).derRepresentation }
    try ClosureAuthentication.verify(empty, emptyTrace, emptySigned, expectedRunID: run, trustedKeyID: pin)
    try rejects(.empty) {
        try ClosureAuthentication.verify(empty, emptyTrace, emptySigned, expectedRunID: run,
                                         trustedKeyID: pin, requireEvidence: true)
    }
    print("PASS: authenticated P-256 closure, pinned key and exact full trace digest")
}
