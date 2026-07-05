import Foundation
import XCTest
import DProvenanceKit
@testable import DProvenanceOTel

/// Wire-shape conformance: assertions run over the decoded JSON (via
/// JSONSerialization) so string-vs-number distinctions are what a backend's
/// parser would actually see.
final class OTLPJSONShapeTests: XCTestCase {

    private func sampleDocumentJSON() throws -> [String: Any] {
        let run = makeRun([
            makeEvent(seq: 0, payload: StubEvent("start")),
            makeEvent(seq: 1, span: "phase", payload: StubEvent("step")),
        ])
        return try mapperDocumentJSON([run])
    }

    func testTraceAndSpanIDShapes() throws {
        let spans = try documentSpans(try sampleDocumentJSON())
        XCTAssertEqual(spans.count, 2)
        for span in spans {
            let traceId = try XCTUnwrap(span["traceId"] as? String)
            let spanId = try XCTUnwrap(span["spanId"] as? String)
            XCTAssertTrue(isLowercaseHex(traceId, count: 32), "traceId not 32 lowercase hex: \(traceId)")
            XCTAssertTrue(isLowercaseHex(spanId, count: 16), "spanId not 16 lowercase hex: \(spanId)")
        }
    }

    func testParentSpanIdKeyAbsentOnRootPresentOnChild() throws {
        let spans = try documentSpans(try sampleDocumentJSON())
        let root = spans[0]
        XCTAssertNil(root["parentSpanId"], "root span must OMIT parentSpanId, not emit empty/null")
        let child = spans[1]
        let parent = try XCTUnwrap(child["parentSpanId"] as? String)
        XCTAssertEqual(parent, root["spanId"] as? String)
    }

    /// uint64 nanos must arrive as JSON strings — an NSNumber here means a
    /// backend already lost precision.
    func testNanosecondTimestampsAreStrings() throws {
        let spans = try documentSpans(try sampleDocumentJSON())
        for span in spans {
            XCTAssertTrue(span["startTimeUnixNano"] is String)
            XCTAssertTrue(span["endTimeUnixNano"] is String)
            XCTAssertFalse(span["startTimeUnixNano"] is NSNumber)
            for event in spanEvents(span) {
                let nanos = try XCTUnwrap(event["timeUnixNano"] as? String)
                XCTAssertTrue(nanos.allSatisfy(\.isNumber))
            }
        }
    }

    func testKindAndStatusCodeAreNumbers() throws {
        let spans = try documentSpans(try sampleDocumentJSON())
        for span in spans {
            XCTAssertTrue(span["kind"] is NSNumber)
            XCTAssertFalse(span["kind"] is String)
            let status = try XCTUnwrap(span["status"] as? [String: Any])
            XCTAssertTrue(status["code"] is NSNumber)
            XCTAssertNil(status["message"], "unset status must omit message")
        }
    }

    func testAttributeValuesCarryExactlyOneVariantAndIntIsString() throws {
        let spans = try documentSpans(try sampleDocumentJSON())
        var sawIntValue = false
        for span in spans {
            for attribute in spanAttributes(span) + spanEvents(span).flatMap({ $0["attributes"] as? [[String: Any]] ?? [] }) {
                let value = try XCTUnwrap(attribute["value"] as? [String: Any])
                XCTAssertEqual(value.count, 1, "exactly one variant key per AnyValue: \(value)")
                if let intValue = value["intValue"] {
                    sawIntValue = true
                    XCTAssertTrue(intValue is String, "intValue must encode as a JSON string")
                }
            }
        }
        XCTAssertTrue(sawIntValue, "fixture should exercise intValue (dpk.sequence)")
    }

    func testAnyValueDecodesIntLenientlyFromStringOrNumber() throws {
        let fromString = try JSONDecoder().decode(OTLPAnyValue.self, from: Data(#"{"intValue":"42"}"#.utf8))
        let fromNumber = try JSONDecoder().decode(OTLPAnyValue.self, from: Data(#"{"intValue":42}"#.utf8))
        XCTAssertEqual(fromString, .int(42))
        XCTAssertEqual(fromNumber, .int(42))
    }

    func testDocumentRoundTripsThroughCodable() throws {
        let run = makeRun([
            makeEvent(seq: 0, span: "phase", payload: StubEvent("step")),
        ])
        let document = OTelSpanMapper<StubEvent>().document(for: [run])
        let data = try OTLPJSON.encode(document)
        let decoded = try JSONDecoder().decode(OTLPTraceDocument.self, from: data)
        XCTAssertEqual(decoded, document)
    }

    func testScopeIdentity() throws {
        let json = try sampleDocumentJSON()
        let resourceSpans = try XCTUnwrap(json["resourceSpans"] as? [[String: Any]])
        XCTAssertEqual(resourceSpans.count, 1)
        let scopeSpans = try XCTUnwrap(resourceSpans[0]["scopeSpans"] as? [[String: Any]])
        XCTAssertEqual(scopeSpans.count, 1)
        let scope = try XCTUnwrap(scopeSpans[0]["scope"] as? [String: Any])
        XCTAssertEqual(scope["name"] as? String, "dprovenancekit-otel")
        XCTAssertEqual(scope["version"] as? String, OTelBridge.version)
    }
}
