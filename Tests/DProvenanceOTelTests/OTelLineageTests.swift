import Foundation
import XCTest
import DProvenanceKit
@testable import DProvenanceOTel

/// Records what the store convenience handed it, so a test can assert which lineage
/// edges the convenience fetched/filtered without parsing exported JSON.
private final class CapturingExporter: OTelTraceExporter, @unchecked Sendable {
    typealias T = StubEvent
    var runs: [TraceRun<StubEvent>] = []
    var edges: [TraceEdge] = []

    func export(_ runs: [TraceRun<StubEvent>]) async throws -> OTelExportReceipt {
        try await export(runs, lineageEdges: [])
    }
    func export(_ runs: [TraceRun<StubEvent>], lineageEdges: [TraceEdge]) async throws -> OTelExportReceipt {
        self.runs = runs
        self.edges = lineageEdges
        return OTelExportReceipt(runsExported: runs.count, runsSkipped: 0, spanCount: 0,
                                 spanEventCount: 0, encodedBytes: 0, traceIDsByRun: [:])
    }
}

final class OTelLineageTests: XCTestCase {

    private func attr(_ kvs: [OTLPKeyValue], _ key: String) -> String? {
        for kv in kvs where kv.key == key { if case .string(let s) = kv.value { return s } }
        return nil
    }

    /// The one root span's span-event whose dpk.event_id is `id`.
    private func spanEventAttrs(_ spans: [OTLPSpan], forEventID id: UUID) -> [OTLPKeyValue]? {
        for span in spans {
            for event in span.events where attr(event.attributes, DPKOTelAttribute.eventID) == id.uuidString {
                return event.attributes
            }
        }
        return nil
    }

    // MARK: - Mapper: attributes

    func testDirectEdgeSurfacesDerivedFromOnTarget() throws {
        let parent = makeEvent(seq: 0, payload: StubEvent("parent"))
        let child = makeEvent(seq: 1, payload: StubEvent("child"))
        let run = makeRun([parent, child])
        let edges = [TraceEdge(sourceID: parent.id, targetID: child.id, type: .derivedFrom)]

        let spans = OTelSpanMapper<StubEvent>().spans(for: run, lineageEdges: edges)

        let childAttrs = try XCTUnwrap(spanEventAttrs(spans, forEventID: child.id))
        XCTAssertEqual(attr(childAttrs, DPKOTelAttribute.derivedFrom), parent.id.uuidString)
        XCTAssertEqual(attr(childAttrs, DPKOTelAttribute.derivedFromType), "derivedFrom")

        // The parent has no inbound edge → event_id but no derived_from.
        let parentAttrs = try XCTUnwrap(spanEventAttrs(spans, forEventID: parent.id))
        XCTAssertNil(attr(parentAttrs, DPKOTelAttribute.derivedFrom))
    }

    func testEveryEventCarriesEventID() throws {
        let e = makeEvent(seq: 0, payload: StubEvent("solo"))
        let spans = OTelSpanMapper<StubEvent>().spans(for: makeRun([e]))   // no edges
        let attrs = try XCTUnwrap(spanEventAttrs(spans, forEventID: e.id))
        XCTAssertEqual(attr(attrs, DPKOTelAttribute.eventID), e.id.uuidString)
        XCTAssertNil(attr(attrs, DPKOTelAttribute.derivedFrom), "no edges → no derived_from")
    }

    func testMultipleParentsAreSortedAndTypeAligned() throws {
        let a = makeEvent(seq: 0, payload: StubEvent("a"))
        let b = makeEvent(seq: 1, payload: StubEvent("b"))
        let child = makeEvent(seq: 2, payload: StubEvent("child"))
        let run = makeRun([a, b, child])
        // Feed edges in a deliberately unsorted order.
        let edges = [
            TraceEdge(sourceID: b.id, targetID: child.id, type: .correctedBy),
            TraceEdge(sourceID: a.id, targetID: child.id, type: .derivedFrom),
        ]

        let spans = OTelSpanMapper<StubEvent>().spans(for: run, lineageEdges: edges)
        let childAttrs = try XCTUnwrap(spanEventAttrs(spans, forEventID: child.id))

        let sources = [a.id, b.id].sorted { $0.uuidString.lowercased() < $1.uuidString.lowercased() }
        let expectedIDs = sources.map { $0.uuidString }.joined(separator: ",")
        let expectedTypes = sources.map { $0 == a.id ? "derivedFrom" : "correctedBy" }.joined(separator: ",")
        XCTAssertEqual(attr(childAttrs, DPKOTelAttribute.derivedFrom), expectedIDs)
        XCTAssertEqual(attr(childAttrs, DPKOTelAttribute.derivedFromType), expectedTypes,
                       "type list is index-aligned to the sorted id list")
    }

    // MARK: - Mapper: determinism (M7)

    func testExportIsByteStableAndEdgeOrderInsensitive() throws {
        let a = makeEvent(seq: 0, payload: StubEvent("a"))
        let b = makeEvent(seq: 1, payload: StubEvent("b"))
        let child = makeEvent(seq: 2, payload: StubEvent("child"))
        let run = makeRun([a, b, child])
        let mapper = OTelSpanMapper<StubEvent>()

        let edges1 = [TraceEdge(sourceID: a.id, targetID: child.id, type: .derivedFrom),
                      TraceEdge(sourceID: b.id, targetID: child.id, type: .informed)]
        let edges2 = Array(edges1.reversed())

        let d1 = try OTLPJSON.encode(mapper.document(for: [run], lineageEdges: edges1), deterministic: true)
        let d2 = try OTLPJSON.encode(mapper.document(for: [run], lineageEdges: edges2), deterministic: true)
        XCTAssertEqual(d1, d2, "output must not depend on input edge order")
    }

    // MARK: - Store convenience

    func testConvenienceFetchesDirectEdges() async throws {
        let store = InMemoryTraceStore<StubEvent>()
        let (parent, child) = await DProvenanceKit<StubEvent>.run(contextID: "c", store: store) { () -> (UUID, UUID) in
            let p = DProvenanceKit<StubEvent>.record(StubEvent("parent"))!
            let c = DProvenanceKit<StubEvent>.record(StubEvent("child"))!
            DProvenanceKit<StubEvent>.link(source: p, target: c, type: .derivedFrom)
            return (p, c)
        }

        let exporter = CapturingExporter()
        _ = try await DProvenanceOTelExport.export(from: store, using: exporter)

        XCTAssertEqual(exporter.edges, [TraceEdge(sourceID: parent, targetID: child, type: .derivedFrom)])
    }
}
