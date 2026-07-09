import Foundation
import XCTest
import DProvenanceKit
@testable import DProvenanceOTel

/// Env-gated live smoke against a real OTLP/HTTP collector. Skipped unless
/// `DPK_OTEL_SMOKE_ENDPOINT` is set (e.g. `http://localhost:4318` for a local
/// stock otel-collector).
final class LiveCollectorSmokeTests: XCTestCase {

    func testExportToLiveCollector() async throws {
        guard let raw = ProcessInfo.processInfo.environment["DPK_OTEL_SMOKE_ENDPOINT"],
              let endpoint = URL(string: raw) else {
            throw XCTSkip("set DPK_OTEL_SMOKE_ENDPOINT to run the live collector smoke test")
        }

        let store = InMemoryTraceStore<StubEvent>()
        _ = await DProvenanceKit<StubEvent>.run(contextID: "smoke", store: store) {
            DProvenanceKit<StubEvent>.record(StubEvent("smoke.start", priority: .critical))
            _ = await DProvenanceKit<StubEvent>.withSpan(named: "smoke-span") {
                DProvenanceKit<StubEvent>.record(StubEvent("smoke.step"))
            }
            DProvenanceKit<StubEvent>.record(StubEvent("smoke.end", priority: .critical))
        }

        var configuration = OTLPHTTPExporter<StubEvent>.Configuration.collector(endpoint: endpoint)
        configuration.retryAttempts = 1
        let receipt = try await DProvenanceOTelExport.export(
            from: store,
            using: OTLPHTTPExporter<StubEvent>(configuration: configuration)
        )
        XCTAssertEqual(receipt.runsExported, 1)
        XCTAssertEqual(receipt.rejectedSpans, 0, receipt.partialSuccessMessages.joined(separator: "; "))
    }
}
