import Foundation
import XCTest
import DProvenanceKit
@testable import DProvenanceOTel

final class OTelSpanMapperTests: XCTestCase {

    // MARK: - Synthesis (F3): eventless wrapper spans are structure, not orphans

    /// `withSpan(named:"outer") { withSpan(named:"inner") { record } }` with
    /// nothing recorded directly in outer: "outer" exists only in inner's
    /// parentSpanID stamps. It must be synthesized and keep the nesting —
    /// NOT flattened onto root, NO orphan attribute.
    func testEventlessParentSpanIsSynthesizedNotFlattened() throws {
        let run = makeRun([
            makeEvent(seq: 0, span: "inner", parent: "outer", payload: StubEvent("step.a")),
            makeEvent(seq: 1, span: "inner", parent: "outer", payload: StubEvent("step.b")),
        ])
        let spans = try documentSpans(try mapperDocumentJSON([run]))
        XCTAssertEqual(spans.count, 3)

        let outer = try spanNamed(spans, "outer")
        let inner = try spanNamed(spans, "inner")
        let rootSpanId = OTelTraceIdentity.rootSpanID(forRun: fixedRunID)

        XCTAssertEqual(outer["parentSpanId"] as? String, rootSpanId)
        XCTAssertEqual(inner["parentSpanId"] as? String, outer["spanId"] as? String)

        let outerAttributes = spanAttributes(outer)
        XCTAssertEqual(attributeValue(outerAttributes, "dpk.synthesized")?["boolValue"] as? Bool, true)
        XCTAssertEqual(stringAttribute(outerAttributes, "dpk.span_id"), "outer")
        XCTAssertEqual(spanEvents(outer).count, 0)

        for span in spans {
            XCTAssertNil(attributeValue(spanAttributes(span), "dpk.orphaned_parent_span_id"),
                         "the orphan case no longer exists (F3)")
        }
    }

    /// If the once-eventless span gains events in a later export, its id must
    /// not move: synthesized spans share the real-span derivation.
    func testSynthesizedSpanIDMatchesRealSpanDerivation() throws {
        let run = makeRun([
            makeEvent(seq: 0, span: "inner", parent: "outer", payload: StubEvent("step")),
        ])
        let spans = try documentSpans(try mapperDocumentJSON([run]))
        let outer = try spanNamed(spans, "outer")
        XCTAssertEqual(outer["spanId"] as? String,
                       OTelTraceIdentity.spanID(forRun: fixedRunID, dpkSpanID: "outer"))
    }

    // MARK: - Parent conflicts (M4)

    /// Re-entrant `withSpan(named:)` with the same name yields
    /// spanID == parentSpanID; a self-loop is invalid, so the span reparents
    /// to root and is flagged.
    func testSelfParentReparentsToRootWithConflict() throws {
        let run = makeRun([
            makeEvent(seq: 0, span: "A", parent: "A", payload: StubEvent("step")),
        ])
        let spans = try documentSpans(try mapperDocumentJSON([run]))
        let spanA = try spanNamed(spans, "A")
        XCTAssertEqual(spanA["parentSpanId"] as? String,
                       OTelTraceIdentity.rootSpanID(forRun: fixedRunID))
        let attributes = spanAttributes(spanA)
        XCTAssertEqual(attributeValue(attributes, "dpk.parent_conflict")?["boolValue"] as? Bool, true)
        XCTAssertEqual(stringAttribute(attributes, "dpk.parent_span_id"), "A",
                       "original claim survives in dpk.parent_span_id")
    }

    func testMemberDisagreementKeepsLowestSequenceWinner() throws {
        let run = makeRun([
            makeEvent(seq: 0, span: "P1", payload: StubEvent("p1")),
            makeEvent(seq: 1, span: "P2", payload: StubEvent("p2")),
            makeEvent(seq: 2, span: "X", parent: "P1", payload: StubEvent("x1")),
            makeEvent(seq: 3, span: "X", parent: "P2", payload: StubEvent("x2")),
        ])
        let spans = try documentSpans(try mapperDocumentJSON([run]))
        let spanX = try spanNamed(spans, "X")
        XCTAssertEqual(spanX["parentSpanId"] as? String,
                       OTelTraceIdentity.spanID(forRun: fixedRunID, dpkSpanID: "P1"))
        XCTAssertEqual(attributeValue(spanAttributes(spanX), "dpk.parent_conflict")?["boolValue"] as? Bool, true)
    }

    /// A -> B -> A can only be hand-assembled, but it would hang the bottom-up
    /// time pass; the cycle member with the lowest min-sequence roots.
    func testHandAssembledCycleTerminatesAndRootsDeterministically() throws {
        let run = makeRun([
            makeEvent(seq: 0, span: "A", parent: "B", payload: StubEvent("a")),
            makeEvent(seq: 1, span: "B", parent: "A", payload: StubEvent("b")),
        ])
        let spans = try documentSpans(try mapperDocumentJSON([run]))
        XCTAssertEqual(spans.count, 3)

        let spanA = try spanNamed(spans, "A")
        let spanB = try spanNamed(spans, "B")
        XCTAssertEqual(spanA["parentSpanId"] as? String,
                       OTelTraceIdentity.rootSpanID(forRun: fixedRunID),
                       "A has the lowest min-sequence, so A roots")
        XCTAssertEqual(spanB["parentSpanId"] as? String, spanA["spanId"] as? String)
        XCTAssertEqual(attributeValue(spanAttributes(spanA), "dpk.parent_conflict")?["boolValue"] as? Bool, true)
        XCTAssertNil(attributeValue(spanAttributes(spanB), "dpk.parent_conflict"))
    }

    // MARK: - Time bounds (M5)

    /// Root bounds cover ALL events even when every event lives inside spans
    /// (the root then has zero direct members).
    func testRootBoundsCoverAllEventsWithoutDirectMembers() throws {
        let run = makeRun([
            makeEvent(seq: 0, span: "S", payload: StubEvent("a"), time: fixedBase + 5),
            makeEvent(seq: 1, span: "S", payload: StubEvent("b"), time: fixedBase + 1),
            makeEvent(seq: 2, span: "S", payload: StubEvent("c"), time: fixedBase + 9),
        ])
        let spans = try documentSpans(try mapperDocumentJSON([run]))
        let root = spans[0]
        XCTAssertEqual(spanEvents(root).count, 0)
        XCTAssertEqual(root["startTimeUnixNano"] as? String,
                       OTLPTimestamp.unixNano(Date(timeIntervalSince1970: fixedBase + 1)))
        XCTAssertEqual(root["endTimeUnixNano"] as? String,
                       OTLPTimestamp.unixNano(Date(timeIntervalSince1970: fixedBase + 9)))
    }

    /// Child bounds envelope member events UNION descendants: a wall-clock
    /// skew that puts a child event before the parent's own events must not
    /// make the parent start after its child.
    func testChildBoundsCoverDescendants() throws {
        let run = makeRun([
            makeEvent(seq: 0, span: "outer", payload: StubEvent("o"), time: fixedBase + 100),
            makeEvent(seq: 1, span: "inner", parent: "outer", payload: StubEvent("i1"), time: fixedBase + 50),
            makeEvent(seq: 2, span: "inner", parent: "outer", payload: StubEvent("i2"), time: fixedBase + 200),
        ])
        let spans = try documentSpans(try mapperDocumentJSON([run]))
        let outer = try spanNamed(spans, "outer")
        XCTAssertEqual(outer["startTimeUnixNano"] as? String,
                       OTLPTimestamp.unixNano(Date(timeIntervalSince1970: fixedBase + 50)))
        XCTAssertEqual(outer["endTimeUnixNano"] as? String,
                       OTLPTimestamp.unixNano(Date(timeIntervalSince1970: fixedBase + 200)))
    }

    func testSingleEventChildlessSpanHasStartEqualEnd() throws {
        let run = makeRun([
            makeEvent(seq: 0, span: "solo", payload: StubEvent("only")),
        ])
        let spans = try documentSpans(try mapperDocumentJSON([run]))
        let solo = try spanNamed(spans, "solo")
        XCTAssertEqual(solo["startTimeUnixNano"] as? String, solo["endTimeUnixNano"] as? String)
    }

    // MARK: - Timestamp conversion (M5, F14)

    /// KAT pins truncation-not-rounding. A `.rounded()` implementation fails
    /// the SQLite-consistency companion below.
    func testTimestampKnownAnswer() {
        let date = Date(timeIntervalSince1970: 1_719_936_000.123456)
        XCTAssertEqual(OTLPTimestamp.unixNano(date), "1719936000123456000")
    }

    func testPre1970TimestampClampsToZeroWithoutTrapping() {
        XCTAssertEqual(OTLPTimestamp.unixNano(Date(timeIntervalSince1970: -1)), "0")
        XCTAssertEqual(OTLPTimestamp.unixNano(Date.distantPast), "0")
    }

    /// Companion: the mapped value must equal the stored microseconds x 1000
    /// after DPK's SQLite write/read round trip (`Int64(t * 1e6)` write,
    /// `Double(us) / 1e6` read) — the property that keeps InMemory- and
    /// SQLite-backed exports of the same event in agreement.
    func testSQLiteRoundTripConsistency() {
        for i in 0..<50_000 {
            let t = 1_719_936_000.0 + Double(i) * 0.000_037_1
            let storedMicros = Int64(t * 1_000_000)                       // SQLite write path
            let readBack = Date(timeIntervalSince1970: Double(storedMicros) / 1_000_000.0)
            XCTAssertEqual(OTLPTimestamp.unixNano(readBack), String(storedMicros * 1_000),
                           "desync at t=\(t)")
        }
    }

    // MARK: - Determinism (M7, F4)

    /// Same events fed to the mapper in shuffled array order must produce
    /// identical bytes — this catches Dictionary-order leaks without
    /// depending on same-process hash seeding.
    func testByteIdenticalOutputUnderShuffledEventOrder() throws {
        var events: [TraceEvent<StubEvent>] = []
        for seq in 0..<24 {
            let span: String? = seq % 3 == 0 ? nil : "span-\(seq % 5)"
            let parent: String? = (seq % 5 == 1) ? "wrapper" : nil
            events.append(makeEvent(seq: UInt64(seq), span: span, parent: parent,
                                    payload: StubEvent("step.\(seq % 7)")))
        }

        let baseline = try OTLPJSON.encode(OTelSpanMapper<StubEvent>().document(for: [makeRun(events)]))
        for attempt in 0..<5 {
            var shuffled = events
            shuffled.shuffle()
            let mapper = OTelSpanMapper<StubEvent>()
            let data = try OTLPJSON.encode(mapper.document(for: [makeRun(shuffled)]))
            XCTAssertEqual(data, baseline, "shuffle #\(attempt) changed the bytes")
        }
    }

    func testSpansOrderedRootFirstThenByMinSequence() throws {
        let run = makeRun([
            makeEvent(seq: 0, span: "late-name-z", payload: StubEvent("a")),
            makeEvent(seq: 1, span: "early-name-a", payload: StubEvent("b")),
            makeEvent(seq: 2, payload: StubEvent("c")),
        ])
        let spans = try documentSpans(try mapperDocumentJSON([run]))
        XCTAssertNil(spans[0]["parentSpanId"], "root first")
        XCTAssertEqual(spans[1]["name"] as? String, "late-name-z", "min sequence orders spans, not names")
        XCTAssertEqual(spans[2]["name"] as? String, "early-name-a")
    }

    // MARK: - Zero-event runs (M1)

    func testZeroEventRunProducesNoSpans() {
        let run = TraceRun<StubEvent>(runID: UUID(), contextID: "empty", events: [])
        XCTAssertTrue(OTelSpanMapper<StubEvent>().spans(for: run).isEmpty)
        let mapped = OTelSpanMapper<StubEvent>().mapped(for: [run])
        XCTAssertEqual(mapped.runsSkipped, 1)
        XCTAssertEqual(mapped.runsExported, 0)
    }

    func testMultipleRunsShareResourceAndScopeButDifferByTraceID() throws {
        let runA = makeRun([makeEvent(run: fixedRunID, seq: 0, payload: StubEvent("a"))], run: fixedRunID)
        let otherID = UUID(uuidString: "DEADBEEF-DEAD-BEEF-DEAD-BEEFDEADBEEF")!
        let runB = makeRun([makeEvent(run: otherID, seq: 0, payload: StubEvent("b"))], run: otherID)

        let json = try mapperDocumentJSON([runA, runB])
        let resourceSpans = try XCTUnwrap(json["resourceSpans"] as? [[String: Any]])
        XCTAssertEqual(resourceSpans.count, 1, "runs share one resource")
        let spans = try documentSpans(json)
        let traceIDs = Set(spans.compactMap { $0["traceId"] as? String })
        XCTAssertEqual(traceIDs.count, 2)
    }

    // MARK: - Error status (M6 error path)

    private func stringAttr(_ span: OTLPSpan, _ key: String) -> String? {
        for kv in span.attributes where kv.key == key {
            if case .string(let s) = kv.value { return s }
        }
        return nil
    }

    /// A promoted gen_ai span whose semantics carry an errorType must be marked
    /// OTLP status ERROR (code 2) and carry `error.type`, so error-rate dashboards
    /// can see the failure.
    func testErrorSemanticsMarkPromotedSpanError() throws {
        var event = GenAIStubEvent()
        event.errorType = "guardrail_violation"
        let run = makeRun([makeEvent(seq: 0, payload: event)])

        let spans = OTelSpanMapper<GenAIStubEvent>().spans(for: run)
        let errored = try XCTUnwrap(spans.first { stringAttr($0, "error.type") == "guardrail_violation" })
        XCTAssertEqual(errored.status.code, 2, "an errored generation span must be ERROR")
    }

    /// A successful gen_ai span (no errorType) stays UNSET — the error path must not
    /// bleed onto healthy spans.
    func testSuccessfulSemanticsLeaveSpanUnset() throws {
        let run = makeRun([makeEvent(seq: 0, payload: GenAIStubEvent())])
        let spans = OTelSpanMapper<GenAIStubEvent>().spans(for: run)
        let promoted = try XCTUnwrap(spans.first { stringAttr($0, "gen_ai.operation.name") == "chat" })
        XCTAssertEqual(promoted.status.code, 0)
        XCTAssertNil(stringAttr(promoted, "error.type"))
    }
}
