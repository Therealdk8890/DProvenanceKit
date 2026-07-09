import Foundation
import XCTest
import DProvenanceKit
@testable import DProvenanceOTel

/// End-to-end coverage over real stores and the real `withSpan` recorder:
/// the mapper's structural rules must hold for what DPK actually records,
/// not just hand-assembled fixtures.
final class StoreExportIntegrationTests: XCTestCase {
    private var destination: URL!

    override func setUp() {
        destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".otlp.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: destination)
    }

    // MARK: - Nested withSpan trees (the parent-linkage contract)

    func testNestedWithSpanTreeParentLinkage() async throws {
        let store = InMemoryTraceStore<StubEvent>()
        _ = await DProvenanceKit<StubEvent>.run(contextID: "case-42", store: store) {
            DProvenanceKit<StubEvent>.record(StubEvent("run.start", priority: .critical))
            _ = await DProvenanceKit<StubEvent>.withSpan(named: "outer") {
                DProvenanceKit<StubEvent>.record(StubEvent("outer.step"))
                _ = await DProvenanceKit<StubEvent>.withSpan(named: "inner") {
                    DProvenanceKit<StubEvent>.record(StubEvent("inner.step"))
                    _ = await DProvenanceKit<StubEvent>.withSpan(named: "leaf") {
                        DProvenanceKit<StubEvent>.record(StubEvent("leaf.step"))
                    }
                }
            }
            DProvenanceKit<StubEvent>.record(StubEvent("run.end", priority: .critical))
        }

        let receipt = try await DProvenanceOTelExport.export(
            from: store,
            using: OTLPFileExporter<StubEvent>(destination: destination)
        )
        XCTAssertEqual(receipt.runsExported, 1)
        XCTAssertEqual(receipt.spanCount, 4)
        XCTAssertEqual(receipt.spanEventCount, 5)

        let runID = try XCTUnwrap(receipt.traceIDsByRun.keys.first)
        let spans = try documentSpans(try decodeJSONObject(try Data(contentsOf: destination)))

        let root = spans[0]
        let outer = try spanNamed(spans, "outer")
        let inner = try spanNamed(spans, "inner")
        let leaf = try spanNamed(spans, "leaf")

        XCTAssertNil(root["parentSpanId"])
        XCTAssertEqual(root["spanId"] as? String, OTelTraceIdentity.rootSpanID(forRun: runID))
        XCTAssertEqual(outer["parentSpanId"] as? String, root["spanId"] as? String)
        XCTAssertEqual(inner["parentSpanId"] as? String, outer["spanId"] as? String)
        XCTAssertEqual(leaf["parentSpanId"] as? String, inner["spanId"] as? String)

        for span in spans {
            XCTAssertEqual(span["traceId"] as? String, OTelTraceIdentity.traceID(forRun: runID))
            XCTAssertTrue(isLowercaseHex(try XCTUnwrap(span["spanId"] as? String), count: 16))
        }
        XCTAssertEqual(root["name"] as? String, "case-42")
    }

    /// The wrapper pattern that used to produce "orphans" (F3): nothing is
    /// recorded directly in outer, so outer must be synthesized — and the
    /// recorded nesting preserved.
    func testWrapperOnlySpanViaRealRecorder() async throws {
        let store = InMemoryTraceStore<StubEvent>()
        _ = await DProvenanceKit<StubEvent>.run(contextID: "wrapper-case", store: store) {
            _ = await DProvenanceKit<StubEvent>.withSpan(named: "outer") {
                _ = await DProvenanceKit<StubEvent>.withSpan(named: "inner") {
                    DProvenanceKit<StubEvent>.record(StubEvent("only.step"))
                }
            }
        }

        _ = try await DProvenanceOTelExport.export(
            from: store,
            using: OTLPFileExporter<StubEvent>(destination: destination)
        )
        let spans = try documentSpans(try decodeJSONObject(try Data(contentsOf: destination)))

        let outer = try spanNamed(spans, "outer")
        let inner = try spanNamed(spans, "inner")
        XCTAssertEqual(attributeValue(spanAttributes(outer), "dpk.synthesized")?["boolValue"] as? Bool, true)
        XCTAssertEqual(inner["parentSpanId"] as? String, outer["spanId"] as? String,
                       "nesting preserved — not flattened onto root")
    }

    // MARK: - Store convenience: query + deterministic run ordering

    func testEmptyQueryExportsAllRunsInDeterministicOrder() async throws {
        let store = InMemoryTraceStore<StubEvent>()
        let runIDs = (0..<4).map { _ in UUID() }
        // Record in an order unrelated to timestamps; the exporter must sort
        // by (first-event timestamp, runID) regardless of Set iteration.
        for (offset, runID) in runIDs.enumerated().shuffled() {
            store.record(makeEvent(run: runID, seq: 0, payload: StubEvent("start"),
                                   time: fixedBase + Double(offset) * 100))
        }

        _ = try await DProvenanceOTelExport.export(
            from: store,
            using: OTLPFileExporter<StubEvent>(destination: destination)
        )
        let spans = try documentSpans(try decodeJSONObject(try Data(contentsOf: destination)))
        let rootRunIDs = spans.compactMap { span in
            stringAttribute(spanAttributes(span), "dpk.run_id")
        }
        XCTAssertEqual(rootRunIDs, runIDs.map(\.uuidString),
                       "runs ordered by first-event timestamp")
    }

    func testFilteredQueryExportsMatchingRunsOnly() async throws {
        let store = InMemoryTraceStore<StubEvent>()
        let wanted = UUID()
        store.record(makeEvent(run: wanted, context: "keep", seq: 0, payload: StubEvent("a")))
        store.record(makeEvent(run: UUID(), context: "drop", seq: 0, payload: StubEvent("b")))

        let receipt = try await DProvenanceOTelExport.export(
            from: store,
            matching: TraceQueryDSL<StubEvent>().filter(contextID: "keep"),
            using: OTLPFileExporter<StubEvent>(destination: destination)
        )
        XCTAssertEqual(receipt.runsExported, 1)
        XCTAssertEqual(Array(receipt.traceIDsByRun.keys), [wanted])
    }

    // MARK: - Drop-stats surfacing

    func testDropStatsSnapshotSurfacesOnResourceAndRoot() async throws {
        let store = InMemoryTraceStore<StubEvent>()
        store.record(makeEvent(seq: 0, payload: StubEvent("only")))

        var options = OTelExportOptions<StubEvent>()
        // InMemory never sheds; simulate a congested SQLite store's tally to
        // pin the wiring (the field is a snapshot the caller passes in).
        options.dropStats = TraceDropStats(telemetry: 12, diagnostic: 0, structural: 1, critical: 0)

        _ = try await DProvenanceOTelExport.export(
            from: store,
            using: OTLPFileExporter<StubEvent>(destination: destination, options: options)
        )
        let json = try decodeJSONObject(try Data(contentsOf: destination))

        let resource = try documentResourceAttributes(json)
        XCTAssertEqual(attributeValue(resource, "dpk.drop_stats.telemetry")?["intValue"] as? String, "12")
        XCTAssertEqual(attributeValue(resource, "dpk.drop_stats.structural")?["intValue"] as? String, "1")
        XCTAssertEqual(attributeValue(resource, "dpk.drop_stats.total")?["intValue"] as? String, "13")
        XCTAssertEqual(attributeValue(resource, "dpk.drop_stats.preserved_integrity")?["boolValue"] as? Bool, false)

        let root = try documentSpans(json)[0]
        XCTAssertEqual(attributeValue(spanAttributes(root), "dpk.drop_stats.preserved_integrity")?["boolValue"] as? Bool,
                       false, "root mirrors the integrity bit")
    }

    func testInMemoryStoreDropStatsAreZero() async throws {
        let store = InMemoryTraceStore<StubEvent>()
        store.record(makeEvent(seq: 0, payload: StubEvent("only")))

        var options = OTelExportOptions<StubEvent>()
        options.dropStats = store.dropStats
        _ = try await DProvenanceOTelExport.export(
            from: store,
            using: OTLPFileExporter<StubEvent>(destination: destination, options: options)
        )
        let resource = try documentResourceAttributes(try decodeJSONObject(try Data(contentsOf: destination)))
        XCTAssertEqual(attributeValue(resource, "dpk.drop_stats.total")?["intValue"] as? String, "0")
        XCTAssertEqual(attributeValue(resource, "dpk.drop_stats.preserved_integrity")?["boolValue"] as? Bool, true)
    }

    // MARK: - SQLite consistency (M5's reason to truncate)

    /// The same events exported from an InMemory store and after a SQLite
    /// write/read round trip must produce identical documents: timestamps
    /// truncate identically (M5), engine/context/sequence survive, and the
    /// re-encoded payload matches. (SQLite regenerates `event.id` and pins
    /// `schemaVersion` to 1 on read — neither appears in the output.)
    func testSQLiteBackedExportIsByteIdenticalToInMemory() async throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: storeURL) }

        let runID = UUID()
        let events: [TraceEvent<StubEvent>] = [
            makeEvent(run: runID, seq: 0, payload: StubEvent("start", priority: .critical),
                      time: 1_719_936_000.123456),
            makeEvent(run: runID, seq: 1, span: "phase", payload: StubEvent("mid", detail: "précis"),
                      time: 1_719_936_000.999999),
            makeEvent(run: runID, seq: 2, span: "inner", parent: "phase", payload: StubEvent("deep"),
                      time: 1_719_936_001.000001),
        ]

        let memoryStore = InMemoryTraceStore<StubEvent>()
        let sqliteStore = try SQLiteTraceStore<StubEvent>(fileURL: storeURL)
        for event in events {
            memoryStore.record(event)
            sqliteStore.record(event)
        }

        let mapper = OTelSpanMapper<StubEvent>()
        let memoryRuns = try await memoryStore.queryRuns(TraceQueryDSL<StubEvent>())
        let sqliteRuns = try await sqliteStore.queryRuns(TraceQueryDSL<StubEvent>())
        XCTAssertEqual(memoryRuns.count, 1)
        XCTAssertEqual(sqliteRuns.count, 1)

        let memoryData = try OTLPJSON.encode(mapper.document(for: memoryRuns))
        let sqliteData = try OTLPJSON.encode(mapper.document(for: sqliteRuns))
        XCTAssertEqual(memoryData, sqliteData,
                       "truncation (never rounding) keeps the two store paths in agreement")
    }
}
