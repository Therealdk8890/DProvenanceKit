import Foundation
import XCTest
@testable import DProvenanceOTel

/// Cross-SDK contract: the Swift verdict mapping must reproduce the Python
/// oracle's `otel_verdict_attributes.json` exactly (key order not significant).
final class DPKGateVerdictTests: XCTestCase {

    private func vector() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // DProvenanceOTelTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // repository root
            .appendingPathComponent("ConformanceHarness/vectors/otel_verdict_attributes.json")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Canonical JSON bytes, so Bool/number/string distinctions are compared the
    /// way a backend parser sees them.
    private func canonical(_ value: Any) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        let reparsed = try JSONSerialization.jsonObject(with: data)
        return try JSONSerialization.data(withJSONObject: reparsed, options: [.sortedKeys])
    }

    private func plain(_ value: OTLPAnyValue) -> Any {
        switch value {
        case .string(let s): return s
        case .bool(let b): return b
        case .int(let i): return NSNumber(value: i)
        case .double(let d): return d
        case .array(let values): return values.map(plain)
        }
    }

    private func plainMap(_ attributes: [OTLPKeyValue]) -> [String: Any] {
        var map: [String: Any] = [:]
        for kv in attributes { map[kv.key] = plain(kv.value) }
        return map
    }

    func testReproducesSharedVector() throws {
        let root = try vector()
        XCTAssertEqual(root["schema"] as? String, DPKGateVerdict.schema)
        let excluded = Set(try XCTUnwrap(root["excluded_keys"] as? [String]))
        let cases = try XCTUnwrap(root["cases"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)
        for raw in cases {
            let description = raw["description"] as? String ?? "?"
            let verdict: DPKGateVerdict
            if let gate = raw["gate_json"] as? [String: Any] {
                verdict = try DPKGateVerdict(gateJSON: gate)
            } else {
                verdict = try DPKGateVerdict(verdictObject: try XCTUnwrap(raw["verdict"] as? [String: Any]))
            }
            var attributes = verdict.attributes()
            XCTAssertEqual(Set(attributes.map(\.key)).count, attributes.count, "duplicate keys: \(description)")
            // SDK identity must be present, but is not pinned by the vector.
            XCTAssertEqual(attributes.filter { excluded.contains($0.key) }.count, excluded.count, description)
            XCTAssertTrue(attributes.contains(.string("dpk.sdk.name", DPKGateVerdict.sdkName)), description)
            attributes.removeAll { excluded.contains($0.key) }

            XCTAssertEqual(try canonical(plainMap(attributes)),
                           try canonical(try XCTUnwrap(raw["attributes"])), description)
            if let otlp = raw["otlp_attributes"] as? [[String: Any]] {
                let encoded = try JSONSerialization.jsonObject(
                    with: JSONEncoder().encode(attributes.sorted { $0.key < $1.key }))
                let expected = otlp.sorted { ($0["key"] as? String ?? "") < ($1["key"] as? String ?? "") }
                XCTAssertEqual(try canonical(encoded), try canonical(expected), description)
            }
            if let evaluation = raw["evaluation_result"] {
                XCTAssertEqual(try canonical(plainMap(verdict.evaluationResultAttributes())),
                               try canonical(evaluation), description)
            }
            XCTAssertEqual(verdict.label, raw["label"] as? String, description)
            XCTAssertEqual(verdict.score, (raw["score"] as? NSNumber)?.doubleValue, description)
        }
    }

    func testEvaluationEventAndBounds() throws {
        let verdict = try DPKGateVerdict(passed: false, regressionLevel: "high",
                                         removedSteps: ["verify"],
                                         reasoning: String(repeating: "é", count: 2000))
        let event = verdict.evaluationResultEvent(timeUnixNano: "1")
        XCTAssertEqual(event.name, "gen_ai.evaluation.result")
        XCTAssertTrue(event.attributes.contains(.string("gen_ai.evaluation.score.label", "fail")))
        XCTAssertTrue(event.attributes.contains(.double("gen_ai.evaluation.score.value", 0)))
        guard case .string(let reasoning)? = verdict.attributes()
            .first(where: { $0.key == "dpk.gate.reasoning" })?.value else {
            return XCTFail("reasoning attribute missing")
        }
        XCTAssertEqual(reasoning.unicodeScalars.count, DPKGateVerdict.maxTextLength)
        XCTAssertTrue(reasoning.hasSuffix("\u{2026}"))
    }

    func testRejectsInvalidInput() {
        XCTAssertThrowsError(try DPKGateVerdict(passed: true, evidence: ["bad key": "x"])) { error in
            XCTAssertEqual(error as? DPKGateVerdict.Error, .invalidEvidenceKey("bad key"))
        }
        XCTAssertThrowsError(try DPKGateVerdict(gateJSON: ["regression_level": "high"])) { error in
            XCTAssertEqual(error as? DPKGateVerdict.Error, .missingPassed)
        }
    }

    func testArrayValueWireShape() throws {
        let kv = OTLPKeyValue.stringArray("dpk.gate.steps.removed", ["a", "b"])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(kv)) as? [String: Any])
        let value = try XCTUnwrap(json["value"] as? [String: Any])
        let array = try XCTUnwrap(value["arrayValue"] as? [String: Any])
        let values = try XCTUnwrap(array["values"] as? [[String: Any]])
        XCTAssertEqual(values.compactMap { $0["stringValue"] as? String }, ["a", "b"])
        XCTAssertEqual(try JSONDecoder().decode(OTLPKeyValue.self, from: JSONEncoder().encode(kv)), kv)
        // proto3 JSON omits empty repeated fields.
        let empty = try JSONDecoder().decode(OTLPAnyValue.self, from: Data(#"{"arrayValue":{}}"#.utf8))
        XCTAssertEqual(empty, .array([]))
    }
}
