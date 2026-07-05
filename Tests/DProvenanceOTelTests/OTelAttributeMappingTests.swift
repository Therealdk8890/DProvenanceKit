import Foundation
import XCTest
import DProvenanceKit
@testable import DProvenanceOTel

final class OTelAttributeMappingTests: XCTestCase {

    // MARK: - dpk.* envelope on span events (M8)

    func testSpanEventEnvelopeFixedOrder() throws {
        let run = makeRun([
            makeEvent(seq: 3, payload: StubEvent("decision.made", priority: .critical, detail: "x")),
        ])
        let spans = try documentSpans(try mapperDocumentJSON([run]))
        let event = try XCTUnwrap(spanEvents(spans[0]).first)
        XCTAssertEqual(event["name"] as? String, "decision.made")

        let attributes = try XCTUnwrap(event["attributes"] as? [[String: Any]])
        XCTAssertEqual(attributeKeyList(attributes),
                       ["dpk.type_identifier", "dpk.sequence", "dpk.priority", "dpk.engine", "dpk.payload"])
        XCTAssertEqual(stringAttribute(attributes, "dpk.type_identifier"), "decision.made")
        XCTAssertEqual(attributeValue(attributes, "dpk.sequence")?["intValue"] as? String, "3")
        XCTAssertEqual(stringAttribute(attributes, "dpk.priority"), "critical")
        XCTAssertEqual(stringAttribute(attributes, "dpk.engine"), "TestEngine")
    }

    func testPriorityCaseNames() throws {
        let run = makeRun([
            makeEvent(seq: 0, payload: StubEvent("t", priority: .telemetry)),
            makeEvent(seq: 1, payload: StubEvent("d", priority: .diagnostic)),
            makeEvent(seq: 2, payload: StubEvent("s", priority: .structural)),
            makeEvent(seq: 3, payload: StubEvent("c", priority: .critical)),
        ])
        let spans = try documentSpans(try mapperDocumentJSON([run]))
        let names = spanEvents(spans[0]).map {
            stringAttribute(($0["attributes"] as? [[String: Any]]) ?? [], "dpk.priority")
        }
        XCTAssertEqual(names, ["telemetry", "diagnostic", "structural", "critical"])
    }

    // MARK: - Child span identity (F15)

    /// `childSpanName` overrides the display name; the original DPK span
    /// identity must survive in dpk.span_id / dpk.parent_span_id.
    func testChildSpanCarriesOriginalDPKIdentityUnderNameOverride() throws {
        var options = OTelExportOptions<StubEvent>()
        options.childSpanName = { "renamed:" + $0 }
        let run = makeRun([
            makeEvent(seq: 0, span: "outer", payload: StubEvent("o")),
            makeEvent(seq: 1, span: "inner", parent: "outer", payload: StubEvent("i")),
        ])
        let spans = try documentSpans(try mapperDocumentJSON([run], options: options))
        let inner = try spanNamed(spans, "renamed:inner")
        let attributes = spanAttributes(inner)
        XCTAssertEqual(stringAttribute(attributes, "dpk.span_id"), "inner")
        XCTAssertEqual(stringAttribute(attributes, "dpk.parent_span_id"), "outer")
    }

    func testChildSpanEngineOnlyWhenAllMembersAgree() throws {
        let run = makeRun([
            makeEvent(engine: "A", seq: 0, span: "same", payload: StubEvent("x")),
            makeEvent(engine: "A", seq: 1, span: "same", payload: StubEvent("y")),
            makeEvent(engine: "A", seq: 2, span: "mixed", payload: StubEvent("x")),
            makeEvent(engine: "B", seq: 3, span: "mixed", payload: StubEvent("y")),
        ])
        let spans = try documentSpans(try mapperDocumentJSON([run]))
        XCTAssertEqual(stringAttribute(spanAttributes(try spanNamed(spans, "same")), "dpk.engine"), "A")
        XCTAssertNil(attributeValue(spanAttributes(try spanNamed(spans, "mixed")), "dpk.engine"))
    }

    // MARK: - Root span attributes (M8)

    func testRootSpanAttributes() throws {
        var options = OTelExportOptions<StubEvent>()
        options.dropStats = TraceDropStats(telemetry: 7, structural: 2)
        let run = makeRun([
            makeEvent(seq: 0, payload: StubEvent("start")),
            makeEvent(seq: 1, payload: StubEvent("end")),
        ])
        let spans = try documentSpans(try mapperDocumentJSON([run], options: options))
        let root = spans[0]
        XCTAssertEqual(root["name"] as? String, "ctx")

        let attributes = spanAttributes(root)
        XCTAssertEqual(attributeKeyList(attributes),
                       ["dpk.run_id", "dpk.context_id", "dpk.schema_version",
                        "dpk.event_count", "dpk.drop_stats.preserved_integrity"])
        XCTAssertEqual(stringAttribute(attributes, "dpk.run_id"), fixedRunID.uuidString,
                       "dpk.run_id is the canonical uppercase uuidString, matching DPK tooling display")
        XCTAssertEqual(stringAttribute(attributes, "dpk.context_id"), "ctx")
        XCTAssertEqual(attributeValue(attributes, "dpk.schema_version")?["intValue"] as? String, "1")
        XCTAssertEqual(attributeValue(attributes, "dpk.event_count")?["intValue"] as? String, "2")
        XCTAssertEqual(attributeValue(attributes, "dpk.drop_stats.preserved_integrity")?["boolValue"] as? Bool,
                       false, "structural drops break integrity")
    }

    func testRootNameFallbackWhenContextIDEmpty() throws {
        let run = makeRun([makeEvent(context: "", seq: 0, payload: StubEvent("x"))], context: "")
        let spans = try documentSpans(try mapperDocumentJSON([run]))
        let traceId = OTelTraceIdentity.traceID(forRun: fixedRunID)
        XCTAssertEqual(spans[0]["name"] as? String, "run " + traceId.prefix(8))
    }

    func testRootStatusClosureAndDefault() throws {
        let run = makeRun([makeEvent(seq: 0, payload: StubEvent("x"))])
        var options = OTelExportOptions<StubEvent>()
        options.rootStatus = { _ in .error("failed run") }
        let spans = try documentSpans(try mapperDocumentJSON([run], options: options))
        let status = try XCTUnwrap(spans[0]["status"] as? [String: Any])
        XCTAssertEqual(status["code"] as? Int, 2)
        XCTAssertEqual(status["message"] as? String, "failed run")

        let defaultSpans = try documentSpans(try mapperDocumentJSON([run]))
        XCTAssertEqual((defaultSpans[0]["status"] as? [String: Any])?["code"] as? Int, 0)
    }

    // MARK: - Resource drop stats (M9)

    func testResourceAttributesFixedOrderWithDropStats() throws {
        var options = OTelExportOptions<StubEvent>()
        options.dropStats = TraceDropStats(telemetry: 5, diagnostic: 4, structural: 0, critical: 0)
        options.resourceAttributes = [.string("deployment.environment", "test")]
        let run = makeRun([makeEvent(seq: 0, payload: StubEvent("x"))])
        let attributes = try documentResourceAttributes(try mapperDocumentJSON([run], options: options))

        XCTAssertEqual(attributeKeyList(attributes), [
            "service.name", "telemetry.sdk.name", "telemetry.sdk.language", "telemetry.sdk.version",
            "dpk.drop_stats.telemetry", "dpk.drop_stats.diagnostic", "dpk.drop_stats.structural",
            "dpk.drop_stats.critical", "dpk.drop_stats.total", "dpk.drop_stats.preserved_integrity",
            "deployment.environment",
        ])
        XCTAssertEqual(stringAttribute(attributes, "service.name"), "dprovenancekit")
        XCTAssertEqual(attributeValue(attributes, "dpk.drop_stats.telemetry")?["intValue"] as? String, "5")
        XCTAssertEqual(attributeValue(attributes, "dpk.drop_stats.total")?["intValue"] as? String, "9")
        XCTAssertEqual(attributeValue(attributes, "dpk.drop_stats.preserved_integrity")?["boolValue"] as? Bool, true)
    }

    func testResourceOmitsDropStatsWhenNotProvided() throws {
        let run = makeRun([makeEvent(seq: 0, payload: StubEvent("x"))])
        let attributes = try documentResourceAttributes(try mapperDocumentJSON([run]))
        XCTAssertEqual(attributeKeyList(attributes),
                       ["service.name", "telemetry.sdk.name", "telemetry.sdk.language", "telemetry.sdk.version"])
    }

    // MARK: - Payload policy (M8)

    func testPayloadFullOmittedAndTruncated() throws {
        let longDetail = String(repeating: "é", count: 4_000)
        let run = makeRun([makeEvent(seq: 0, payload: StubEvent("big", detail: longDetail))])

        var full = OTelExportOptions<StubEvent>()
        full.payloadInclusion = .full
        let fullAttrs = try firstSpanEventAttributes([run], options: full)
        let fullPayload = try XCTUnwrap(stringAttribute(fullAttrs, "dpk.payload"))
        XCTAssertTrue(fullPayload.contains("big"))
        XCTAssertNil(attributeValue(fullAttrs, "dpk.payload_truncated"))

        var omitted = OTelExportOptions<StubEvent>()
        omitted.payloadInclusion = .omitted
        let omittedAttrs = try firstSpanEventAttributes([run], options: omitted)
        XCTAssertNil(attributeValue(omittedAttrs, "dpk.payload"))
        XCTAssertNil(attributeValue(omittedAttrs, "dpk.payload_truncated"))

        var truncated = OTelExportOptions<StubEvent>()
        truncated.payloadInclusion = .truncated(maxBytes: 101)
        let truncatedAttrs = try firstSpanEventAttributes([run], options: truncated)
        let cut = try XCTUnwrap(stringAttribute(truncatedAttrs, "dpk.payload"))
        XCTAssertLessThanOrEqual(cut.utf8.count, 101)
        XCTAssertEqual(attributeValue(truncatedAttrs, "dpk.payload_truncated")?["boolValue"] as? Bool, true)
        // "é" is 2 UTF-8 bytes: an odd budget must back off to a character
        // boundary, never split one.
        XCTAssertNotNil(String(data: Data(cut.utf8), encoding: .utf8))
    }

    func testTruncationFlagAbsentWhenPayloadFits() throws {
        let run = makeRun([makeEvent(seq: 0, payload: StubEvent("small"))])
        let attrs = try firstSpanEventAttributes([run], options: .init())
        XCTAssertNotNil(attributeValue(attrs, "dpk.payload"))
        XCTAssertNil(attributeValue(attrs, "dpk.payload_truncated"))
    }

    /// M8/F10: re-encoding can throw inside the non-throwing mapper; the event
    /// keeps its envelope and gains dpk.payload_error instead.
    func testPayloadEncodeFailureEmitsErrorAttributeWithoutThrowing() throws {
        let run = makeRun([makeEvent(seq: 0, payload: UnencodableStubEvent())])
        let attrs = try firstSpanEventAttributes([run], options: .init())
        XCTAssertNil(attributeValue(attrs, "dpk.payload"))
        XCTAssertEqual(stringAttribute(attrs, "dpk.payload_error"), "encoding_failed")
    }

    /// AnyTraceableEvent's rawJSON is inlined one level so backends show the
    /// real object, not an escaped string.
    func testAnyTraceableEventRawJSONInlinedOneLevel() throws {
        let erased = AnyTraceableEvent(typeIdentifier: "wrapped", priorityValue: 2,
                                       rawJSON: #"{"answer":42}"#)
        let run = makeRun([makeEvent(seq: 0, payload: erased)])
        var options = OTelExportOptions<AnyTraceableEvent>()
        options.payloadInclusion = .full
        let attrs = try firstSpanEventAttributes([run], options: options)
        let payload = try XCTUnwrap(stringAttribute(attrs, "dpk.payload"))
        XCTAssertEqual(payload, #"{"typeIdentifier":"wrapped","priorityValue":2,"rawJSON":{"answer":42}}"#)

        let reparsed = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        XCTAssertEqual((reparsed["rawJSON"] as? [String: Any])?["answer"] as? Int, 42)
    }

    func testAnyTraceableEventInvalidRawJSONStaysEscaped() throws {
        let erased = AnyTraceableEvent(typeIdentifier: "wrapped", priorityValue: 1,
                                       rawJSON: "not json {")
        let run = makeRun([makeEvent(seq: 0, payload: erased)])
        var options = OTelExportOptions<AnyTraceableEvent>()
        options.payloadInclusion = .full
        let attrs = try firstSpanEventAttributes([run], options: options)
        let payload = try XCTUnwrap(stringAttribute(attrs, "dpk.payload"))
        let reparsed = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        XCTAssertEqual(reparsed["rawJSON"] as? String, "not json {")
    }

    // MARK: - GenAI promotion (M6, F2)

    func testGenAIPromotionCreatesDedicatedChildSpan() throws {
        let run = makeRun([
            makeEvent(seq: 0, span: "phase", payload: StubOrGenEvent.plain(StubEvent("setup"))),
            makeEvent(seq: 1, span: "phase", payload: StubOrGenEvent.gen(GenAIStubEvent())),
        ])
        let spans = try documentSpans(try mapperDocumentJSON([run]))

        let promoted = try spanNamed(spans, "chat claude-sonnet")
        let phase = try spanNamed(spans, "phase")
        XCTAssertEqual(promoted["parentSpanId"] as? String, phase["spanId"] as? String,
                       "promoted span parents to the event's containing span")
        XCTAssertEqual(promoted["spanId"] as? String,
                       OTelTraceIdentity.eventSpanID(forRun: fixedRunID, sequence: 1))
        XCTAssertEqual(promoted["kind"] as? Int, 3, "inference ops are CLIENT")
        XCTAssertEqual(promoted["startTimeUnixNano"] as? String, promoted["endTimeUnixNano"] as? String)

        let attributes = spanAttributes(promoted)
        XCTAssertEqual(stringAttribute(attributes, "gen_ai.operation.name"), "chat")
        XCTAssertEqual(stringAttribute(attributes, "gen_ai.request.model"), "claude-sonnet")
        XCTAssertEqual(stringAttribute(attributes, "gen_ai.provider.name"), "anthropic")
        XCTAssertEqual(attributeValue(attributes, "gen_ai.usage.input_tokens")?["intValue"] as? String, "11")
        XCTAssertEqual(attributeValue(attributes, "gen_ai.usage.output_tokens")?["intValue"] as? String, "29")
        XCTAssertEqual(stringAttribute(attributes, "dpk.type_identifier"), "llm.call",
                       "the dpk envelope follows the gen_ai set")

        // Moved, not copied: the containing span keeps only the plain event.
        let phaseEventNames = spanEvents(phase).compactMap { $0["name"] as? String }
        XCTAssertEqual(phaseEventNames, ["setup"])
    }

    func testExecuteToolPromotionIsInternalKindWithSemconvName() throws {
        let payload = GenAIStubEvent(typeIdentifier: "tool.exec", operation: "execute_tool",
                                     model: nil, tool: "search_statutes",
                                     inputTokens: nil, outputTokens: nil)
        let run = makeRun([makeEvent(seq: 0, payload: StubOrGenEvent.gen(payload))])
        let spans = try documentSpans(try mapperDocumentJSON([run]))
        let promoted = try spanNamed(spans, "execute_tool search_statutes")
        XCTAssertEqual(promoted["kind"] as? Int, 1, "execute_tool is INTERNAL")
        XCTAssertEqual(promoted["parentSpanId"] as? String,
                       OTelTraceIdentity.rootSpanID(forRun: fixedRunID),
                       "spanless promoted events parent to root")
    }

    func testExplicitOTelEventNameWinsForPromotedSpan() throws {
        let payload = GenAIStubEvent(explicitName: "my custom generation")
        let run = makeRun([makeEvent(seq: 0, payload: StubOrGenEvent.gen(payload))])
        let spans = try documentSpans(try mapperDocumentJSON([run]))
        XCTAssertNoThrow(try spanNamed(spans, "my custom generation"))
    }

    /// `.attachedToEventOnly` keeps the event as a span event with gen_ai.*
    /// merged on — the documented escape hatch that does NOT produce Langfuse
    /// generations.
    func testAttachedToEventOnlyKeepsSpanEventWithGenAIAttributes() throws {
        var options = OTelExportOptions<StubOrGenEvent>()
        options.genAIPromotion = .attachedToEventOnly
        let run = makeRun([
            makeEvent(seq: 0, span: "phase", payload: StubOrGenEvent.gen(GenAIStubEvent())),
        ])
        let spans = try documentSpans(try mapperDocumentJSON([run], options: options))
        XCTAssertEqual(spans.count, 2, "no promoted span")

        let phase = try spanNamed(spans, "phase")
        let event = try XCTUnwrap(spanEvents(phase).first)
        let attributes = try XCTUnwrap(event["attributes"] as? [[String: Any]])
        XCTAssertEqual(stringAttribute(attributes, "gen_ai.operation.name"), "chat")
        XCTAssertEqual(stringAttribute(attributes, "dpk.type_identifier"), "llm.call")
    }

    /// M6 precedence: a payload's own conformance beats the options closure;
    /// the closure serves payloads that cannot adopt the protocol.
    func testConformanceBeatsSemanticAttributesClosure() throws {
        var options = OTelExportOptions<StubOrGenEvent>()
        options.semanticAttributes = { _ in GenAIAttributes(operationName: "closure-op") }

        let run = makeRun([
            makeEvent(seq: 0, payload: StubOrGenEvent.gen(GenAIStubEvent())),
            makeEvent(seq: 1, payload: StubOrGenEvent.plain(StubEvent("plain.step"))),
        ])
        let spans = try documentSpans(try mapperDocumentJSON([run], options: options))

        let conformancePromoted = try spanNamed(spans, "chat claude-sonnet")
        XCTAssertEqual(stringAttribute(spanAttributes(conformancePromoted), "gen_ai.operation.name"), "chat",
                       "conformance semantics win")

        let closurePromoted = try spanNamed(spans, "closure-op")
        XCTAssertEqual(stringAttribute(spanAttributes(closurePromoted), "gen_ai.operation.name"), "closure-op",
                       "closure fills in for non-conforming payloads")
    }

    // MARK: - Helpers

    private func firstSpanEventAttributes<T: TraceableEvent>(
        _ runs: [TraceRun<T>], options: OTelExportOptions<T>
    ) throws -> [[String: Any]] {
        let spans = try documentSpans(try mapperDocumentJSON(runs, options: options))
        let event = try XCTUnwrap(spanEvents(spans[0]).first)
        return try XCTUnwrap(event["attributes"] as? [[String: Any]])
    }
}

/// Mixed-payload fixture: one run whose events are sometimes plain and
/// sometimes GenAI-bearing, mirroring a real agent loop. The enum forwards
/// `OTelSemanticsProviding` only for the gen case, so the same run exercises
/// both the conformance and the closure path.
enum StubOrGenEvent: TraceableEvent, OTelSemanticsProviding {
    case plain(StubEvent)
    case gen(GenAIStubEvent)

    var typeIdentifier: String {
        switch self {
        case .plain(let e): return e.typeIdentifier
        case .gen(let e): return e.typeIdentifier
        }
    }

    var priority: TracePriority {
        switch self {
        case .plain(let e): return e.priority
        case .gen(let e): return e.priority
        }
    }

    var otelSemantics: GenAIAttributes? {
        switch self {
        case .plain: return nil
        case .gen(let e): return e.otelSemantics
        }
    }

    var otelEventName: String? {
        switch self {
        case .plain: return nil
        case .gen(let e): return e.otelEventName
        }
    }
}
