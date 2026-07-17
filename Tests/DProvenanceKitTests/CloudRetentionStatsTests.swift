import XCTest
@testable import DProvenanceKit
import Foundation

/// Regression coverage for the quarantine-visibility gap: a poison batch (400) or a
/// retry-exhausted batch moved to the in-memory quarantine, `flush()` returned
/// success, and `dropStats.preservedIntegrity` stayed `true` — the documented trust
/// pattern reported full delivery while (possibly critical) events sat undelivered
/// in RAM, to be lost uncounted on process exit. `retentionStats()` is the surface
/// that makes that state visible; these tests pin it.
final class CloudRetentionStatsTests: XCTestCase {

    private struct TieredEvent: TraceableEvent {
        let tierRaw: Int

        var typeIdentifier: String { "tiered" }
        var priority: TracePriority { TracePriority(rawValue: tierRaw) ?? .telemetry }

        init(tier: TracePriority) { self.tierRaw = tier.rawValue }
    }

    /// Encodes freely; decodes only when `kind == "good"` — models a quarantined row
    /// whose payload type has drifted by the time it is queried back.
    private struct DriftingEvent: TraceableEvent {
        let kind: String

        var typeIdentifier: String { "drifting" }
        var priority: TracePriority { .structural }

        init(kind: String) { self.kind = kind }

        private enum CodingKeys: String, CodingKey { case kind }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let kind = try container.decode(String.self, forKey: .kind)
            guard kind == "good" else {
                throw DecodingError.dataCorruptedError(
                    forKey: .kind, in: container,
                    debugDescription: "drifted variant no longer decodes"
                )
            }
            self.kind = kind
        }
    }

    /// Encoding always fails, to drive the encode-failure drop path.
    private struct UnencodableEvent: TraceableEvent {
        var typeIdentifier: String { "unencodable" }
        var priority: TracePriority { .critical }

        init() {}
        init(from decoder: Decoder) throws {}

        func encode(to encoder: Encoder) throws {
            throw EncodingError.invalidValue(
                0, EncodingError.Context(codingPath: [], debugDescription: "deliberately unencodable")
            )
        }
    }

    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    private func makeStore() -> CloudTraceStore<TieredEvent> {
        CloudTraceStore(
            endpoint: URL(string: "https://api.dprovenance.cloud")!,
            apiKey: "test",
            config: OfflineConfig(),
            session: session
        )
    }

    private func record(_ tier: TracePriority, sequence: UInt64, on store: CloudTraceStore<TieredEvent>) {
        store.record(TraceEvent(
            runID: UUID(), contextID: "ctx", engineName: "test",
            schemaVersion: 1, sequence: sequence, spanID: nil, parentSpanID: nil,
            payload: TieredEvent(tier: tier)
        ))
    }

    func testQuarantinedCriticalEventsFlipRetentionIntegrityWhileDropStatsStaysClean() async throws {
        let store = makeStore()
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!, Data())
        }

        record(.critical, sequence: 1, on: store)
        record(.structural, sequence: 2, on: store)

        // The documented contract: a poison batch resolves the flush successfully.
        try await store.flush()

        // The old dishonesty, now pinned as the *documented* narrow meaning:
        // nothing was destroyed on-device, so dropStats stays clean...
        XCTAssertEqual(store.dropStats.total, 0)
        XCTAssertTrue(store.dropStats.preservedIntegrity)

        // ...but the delivery-trust surface must tell the truth.
        let retention = await store.retentionStats()
        XCTAssertEqual(retention.quarantined.critical, 1)
        XCTAssertEqual(retention.quarantined.structural, 1)
        XCTAssertEqual(retention.dropped, .zero)
        XCTAssertFalse(
            retention.preservedIntegrity,
            "critical events sitting undelivered in quarantine must not read as intact"
        )
    }

    func testTelemetryOnlyQuarantineKeepsIntegrity() async throws {
        let store = makeStore()
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!, Data())
        }

        record(.telemetry, sequence: 1, on: store)
        try await store.flush()

        let retention = await store.retentionStats()
        XCTAssertEqual(retention.quarantined.telemetry, 1)
        XCTAssertTrue(
            retention.preservedIntegrity,
            "telemetry never participates in a structural diff — quarantining it is not an integrity loss"
        )
    }

    func testQuarantinedEdgesCountAsStructural() async throws {
        let store = makeStore()
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!, Data())
        }

        store.link(source: UUID(), target: UUID(), type: .derivedFrom)
        try await store.flush()

        let retention = await store.retentionStats()
        XCTAssertEqual(
            retention.quarantined.structural, 1,
            "an undelivered lineage edge changes what traversal contains — structural, like a lost edge"
        )
        XCTAssertFalse(retention.preservedIntegrity)
    }

    func testDropsAloneFlipRetentionIntegrity() async throws {
        // Kills the mutation where the combined bit ignores `dropped`: an encode
        // failure is a critical drop with an EMPTY quarantine, so only the
        // `dropped.preservedIntegrity` term can flip the report.
        let store = CloudTraceStore<UnencodableEvent>(
            endpoint: URL(string: "https://api.dprovenance.cloud")!,
            apiKey: "test",
            config: OfflineConfig(),
            session: session
        )
        store.record(TraceEvent(
            runID: UUID(), contextID: "ctx", engineName: "test",
            schemaVersion: 1, sequence: 1, spanID: nil, parentSpanID: nil,
            payload: UnencodableEvent()
        ))

        let retention = await store.retentionStats()
        XCTAssertEqual(retention.dropped.critical, 1)
        XCTAssertEqual(retention.quarantined, .zero)
        XCTAssertFalse(
            retention.preservedIntegrity,
            "a critical drop must flip the combined bit even with an empty quarantine"
        )
    }

    func testQuarantineQueryOmitsUndecodableRowsButRetentionStillCountsThem() async throws {
        // The one retrieval path must not silently shrink: a quarantined row whose
        // payload no longer decodes as T is omitted from the query result (and
        // logged), but it remains quarantined — and retentionStats still counts it.
        let store = CloudTraceStore<DriftingEvent>(
            endpoint: URL(string: "https://api.dprovenance.cloud")!,
            apiKey: "test",
            config: OfflineConfig(),
            session: session
        )
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!, Data())
        }

        for (i, kind) in ["good", "drifted"].enumerated() {
            store.record(TraceEvent(
                runID: UUID(), contextID: "ctx", engineName: "test",
                schemaVersion: 1, sequence: UInt64(i + 1), spanID: nil, parentSpanID: nil,
                payload: DriftingEvent(kind: kind)
            ))
        }
        try await store.flush()

        let retrieved = try await store.queryQuarantinedEvents(TraceQueryDSL<DriftingEvent>())
        XCTAssertEqual(retrieved.count, 1, "only the decodable row can come back as DriftingEvent")
        XCTAssertEqual(retrieved.first?.payload.kind, "good")

        let retention = await store.retentionStats()
        XCTAssertEqual(
            retention.quarantined.structural, 2,
            "the undecodable row stays quarantined and counted, not silently gone"
        )
    }

    func testCleanDeliveryReportsFullIntegrity() async throws {
        let store = makeStore()
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }

        record(.critical, sequence: 1, on: store)
        try await store.flush()

        let retention = await store.retentionStats()
        XCTAssertEqual(retention.quarantined, .zero)
        XCTAssertEqual(retention.dropped, .zero)
        XCTAssertTrue(retention.preservedIntegrity)
    }
}
