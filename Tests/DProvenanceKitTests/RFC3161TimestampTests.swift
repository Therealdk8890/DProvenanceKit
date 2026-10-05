import XCTest
@testable import DProvenanceKit

final class RFC3161TimestampTests: XCTestCase {
    func testExternalTimestampRoundTripsWithoutChangingAttestation() throws {
        let runID = UUID()
        let trace = AttestableTrace(
            runID: runID,
            contextID: "test-context",
            events: []
        )
        let attestation = TraceAttestation(
            runID: runID,
            contextID: "test-context",
            eventCount: 0,
            edgeCount: 0,
            traceDigest: String(repeating: "a", count: 64),
            issuedAtUnixMicroseconds: 1_700_000_000_000_000,
            keyID: String(repeating: "b", count: 64),
            publicKeyBase64: "AQ==",
            signatureBase64: "Ag=="
        )
        let timestamp = RFC3161Timestamp(
            tsaURL: "https://tsa.example.test/timestamp",
            messageImprintSHA256: String(repeating: "c", count: 64),
            nonce: 42,
            genTimeUnixMicroseconds: 1_700_000_001_000_000,
            tokenBase64: "AQID"
        )

        let document = TraceAttestationDocument(
            trace: trace,
            attestation: attestation,
            externalTimestamp: timestamp
        )

        let decoded = try TraceAttestationDocument.decodeJSON(
            try document.jsonData(prettyPrinted: false)
        )

        XCTAssertEqual(decoded, document)
        XCTAssertEqual(decoded.externalTimestamp?.nonce, 42)
        XCTAssertEqual(decoded.attestation.traceDigest, attestation.traceDigest)
    }

    func testLegacyDocumentDecodesWithoutTimestamp() throws {
        let json = """
        {
          "attestation": {
            "algorithm": "P256-SHA256",
            "canonicalization": "DPK-BINARY-V1",
            "contextID": "legacy",
            "edgeCount": 0,
            "eventCount": 0,
            "issuedAtUnixMicroseconds": 1700000000000000,
            "keyID": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            "publicKeyBase64": "AQ==",
            "runID": "00000000-0000-0000-0000-000000000001",
            "signatureBase64": "Ag==",
            "traceDigest": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "version": 1
          },
          "trace": {
            "contextID": "legacy",
            "edges": [],
            "events": [],
            "runID": "00000000-0000-0000-0000-000000000001"
          }
        }
        """.data(using: .utf8)!

        let document = try TraceAttestationDocument.decodeJSON(json)

        XCTAssertNil(document.externalTimestamp)
        XCTAssertEqual(document.trace.contextID, "legacy")
        XCTAssertEqual(document.attestation.version, 1)
    }
}
