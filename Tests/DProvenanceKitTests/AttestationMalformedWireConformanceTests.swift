import Foundation
import XCTest
@testable import DProvenanceKit

/// Executes the same versioned malformed-wire recipe corpus as the Python SDK.
/// The immutable signed attestation-v1.json golden vector remains unchanged.
final class AttestationMalformedWireConformanceTests: XCTestCase {
    func testSharedMalformedWireCorpus() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let vectors = root.appendingPathComponent("docs").appendingPathComponent("test-vectors")
        let corpusData = try Data(contentsOf: vectors.appendingPathComponent("attestation-malformed-v1.json"))
        let corpus = try XCTUnwrap(JSONSerialization.jsonObject(with: corpusData) as? [String: Any])
        XCTAssertEqual(corpus["schema"] as? String, "dpk.attestation-malformed-v1")
        let baseName = try XCTUnwrap(corpus["base"] as? String)
        XCTAssertEqual(baseName, "attestation-v1.json")
        let baseData = try Data(contentsOf: vectors.appendingPathComponent(baseName))
        let base = try TraceAttestationDocument.decodeJSON(baseData)
        XCTAssertTrue(base.verify().isValid, "Original signed vector must remain valid")

        let cases = try XCTUnwrap(corpus["cases"] as? [[String: String]])
        XCTAssertEqual(cases.count, 14)
        XCTAssertEqual(Set(cases.compactMap { $0["id"] }).count, cases.count)
        XCTAssertEqual(Set(cases.compactMap { $0["mutation"] }).count, cases.count)

        for fixture in cases {
            let identifier = try XCTUnwrap(fixture["id"])
            let mutation = try XCTUnwrap(fixture["mutation"])
            let expected = try XCTUnwrap(fixture["expected"])
            var document = try XCTUnwrap(
                JSONSerialization.jsonObject(with: baseData) as? [String: Any]
            )
            try apply(mutation, to: &document)
            let altered = try JSONSerialization.data(
                withJSONObject: document, options: [.sortedKeys]
            )
            switch expected {
            case "decodeRejected":
                XCTAssertThrowsError(
                    try TraceAttestationDocument.decodeJSON(altered),
                    identifier
                )
            case "malformedDigest":
                let result = try TraceAttestationDocument.decodeJSON(altered).verify()
                XCTAssertFalse(result.isValid, identifier)
                XCTAssertEqual(result.failure, .malformedDigest, identifier)
            default:
                XCTFail("Unknown shared expected outcome: \(expected)")
            }
        }
    }

    private func apply(_ mutation: String, to document: inout [String: Any]) throws {
        switch mutation {
        case "uppercase_digest", "envelope_version_bool",
             "envelope_eventcount_string", "envelope_edgecount_bool",
             "envelope_issued_string":
            var envelope = try XCTUnwrap(document["attestation"] as? [String: Any])
            switch mutation {
            case "uppercase_digest":
                let digest = try XCTUnwrap(envelope["traceDigest"] as? String)
                envelope["traceDigest"] = digest.uppercased()
            case "envelope_version_bool":
                envelope["version"] = true
            case "envelope_eventcount_string":
                envelope["eventCount"] = "5"
            case "envelope_edgecount_bool":
                envelope["edgeCount"] = true
            default:
                envelope["issuedAtUnixMicroseconds"] = "1"
            }
            document["attestation"] = envelope

        case "remove_edges", "null_edges", "object_edges", "string_edges",
             "null_events", "event_schema_bool", "event_sequence_string",
             "event_priority_bool", "event_timestamp_string":
            var trace = try XCTUnwrap(document["trace"] as? [String: Any])
            switch mutation {
            case "remove_edges":
                trace.removeValue(forKey: "edges")
            case "null_edges":
                trace["edges"] = NSNull()
            case "object_edges":
                trace["edges"] = [String: Any]()
            case "string_edges":
                trace["edges"] = "[]"
            case "null_events":
                trace["events"] = NSNull()
            default:
                var events = try XCTUnwrap(trace["events"] as? [[String: Any]])
                XCTAssertFalse(events.isEmpty)
                switch mutation {
                case "event_schema_bool":
                    events[0]["schemaVersion"] = true
                case "event_sequence_string":
                    events[0]["sequence"] = "1"
                case "event_priority_bool":
                    events[0]["priority"] = true
                default:
                    events[0]["timestampUnixMicroseconds"] = "1"
                }
                trace["events"] = events
            }
            document["trace"] = trace

        default:
            XCTFail("Unknown malformed-wire mutation: \(mutation)")
        }
    }
}
