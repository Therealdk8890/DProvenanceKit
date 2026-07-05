import Foundation
import XCTest
import DProvenanceKit
@testable import DProvenanceOTel

final class OTLPFileExporterTests: XCTestCase {
    private var destination: URL!

    override func setUp() {
        destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".otlp.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: destination)
    }

    private func fixtureEvents() -> [TraceEvent<StubEvent>] {
        [
            makeEvent(seq: 0, payload: StubEvent("start", priority: .critical)),
            makeEvent(seq: 1, span: "phase", payload: StubEvent("step.a")),
            makeEvent(seq: 2, span: "phase", payload: StubEvent("step.b")),
            makeEvent(seq: 3, span: "inner", parent: "wrapper", payload: StubEvent("deep")),
            makeEvent(seq: 4, payload: StubEvent("end", priority: .critical)),
        ]
    }

    func testWritesDocumentAndReceiptCountsMatchFile() async throws {
        let emptyRun = TraceRun<StubEvent>(runID: UUID(), contextID: "empty", events: [])
        let exporter = OTLPFileExporter<StubEvent>(destination: destination)
        let receipt = try await exporter.export([makeRun(fixtureEvents()), emptyRun])

        let data = try Data(contentsOf: destination)
        XCTAssertEqual(receipt.encodedBytes, data.count)
        XCTAssertEqual(receipt.runsExported, 1)
        XCTAssertEqual(receipt.runsSkipped, 1)
        XCTAssertEqual(receipt.rejectedSpans, 0)
        XCTAssertEqual(receipt.traceIDsByRun,
                       [fixedRunID: OTelTraceIdentity.traceID(forRun: fixedRunID)])

        let spans = try documentSpans(try decodeJSONObject(data))
        XCTAssertEqual(receipt.spanCount, spans.count)
        XCTAssertEqual(receipt.spanCount, 4, "root + phase + synthesized wrapper + inner")
        XCTAssertEqual(receipt.spanEventCount, spans.reduce(0) { $0 + spanEvents($1).count })
        XCTAssertEqual(receipt.spanEventCount, 5)
    }

    /// The headline determinism claim, tested the way production breaks it
    /// (F4): a NEW exporter instance over input CONSTRUCTED in a different
    /// order — same-process dictionary seeding cannot mask an ordering leak
    /// carried by the input array.
    func testByteIdenticalReExportAcrossInstancesWithShuffledInput() async throws {
        let events = fixtureEvents()
        _ = try await OTLPFileExporter<StubEvent>(destination: destination)
            .export([makeRun(events)])
        let first = try Data(contentsOf: destination)

        for _ in 0..<3 {
            let shuffled = makeRun(events.shuffled())
            let second = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".otlp.json")
            defer { try? FileManager.default.removeItem(at: second) }

            _ = try await OTLPFileExporter<StubEvent>(destination: second)
                .export([shuffled])
            XCTAssertEqual(try Data(contentsOf: second), first,
                           "re-export must be byte-identical")
        }
    }

    func testNonDeterministicModeStillDecodes() async throws {
        let exporter = OTLPFileExporter<StubEvent>(destination: destination, deterministic: false)
        _ = try await exporter.export([makeRun(fixtureEvents())])
        let data = try Data(contentsOf: destination)
        XCTAssertNoThrow(try JSONDecoder().decode(OTLPTraceDocument.self, from: data))
    }

    func testFileWriteFailureThrowsWithPath() async {
        let bad = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/out.json")
        let exporter = OTLPFileExporter<StubEvent>(destination: bad)
        do {
            _ = try await exporter.export([makeRun(fixtureEvents())])
            XCTFail("expected fileWriteFailed")
        } catch let OTelExportError.fileWriteFailed(path, _) {
            XCTAssertEqual(path, bad.path)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}
