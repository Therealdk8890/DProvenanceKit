import XCTest
@testable import DProvenanceKit
import Foundation

/// The experimental cloud store's documented promise is that ingestion "never lies":
/// what reaches the wire is what was recorded, and anything that can't reach the wire
/// is either retrievable (quarantine) or counted (dropStats). Three violations lived
/// here: `record` reminted event IDs, encode failures vanished without touching
/// `dropStats`, and lineage edges were queued but never drained or transmitted.
final class CloudIngestHonestyTests: XCTestCase {
    /// A payload whose encoding always fails, to exercise encode-failure accounting.
    private struct UnencodableCloudPayload: TraceableEvent {
        var typeIdentifier: String { "unencodable" }
        var priority: TracePriority { .critical }

        func encode(to encoder: Encoder) throws {
            throw EncodingError.invalidValue(
                0, EncodingError.Context(codingPath: [], debugDescription: "deliberately unencodable")
            )
        }

        init() {}
        init(from decoder: Decoder) throws {}
    }

    private enum WireEvent: TraceableEvent {
        case step

        var typeIdentifier: String { "step" }
        var priority: TracePriority { .structural }
    }

    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    private static func slurpBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        var data = Data()
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }

    /// Collects every /ingest envelope the mock endpoint receives.
    private final class EnvelopeCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var envelopes: [[String: Any]] = []

        func record(_ request: URLRequest) {
            let body = CloudIngestHonestyTests.slurpBody(request)
            guard let envelope = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return }
            lock.withLock { envelopes.append(envelope) }
        }

        var allEvents: [[String: Any]] {
            lock.withLock { envelopes.compactMap { $0["events"] as? [[String: Any]] }.flatMap { $0 } }
        }

        var allEdges: [[String: Any]] {
            lock.withLock { envelopes.compactMap { $0["edges"] as? [[String: Any]] }.flatMap { $0 } }
        }
    }

    func testRecordedEventIDAndSchemaVersionReachTheWireUnchanged() async throws {
        let collector = EnvelopeCollector()
        MockURLProtocol.requestHandler = { request in
            collector.record(request)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }

        let store = CloudTraceStore<WireEvent>(
            endpoint: URL(string: "https://api.dprovenance.cloud")!, apiKey: "test", session: session
        )
        let eventID = UUID()
        store.record(TraceEvent<WireEvent>(
            id: eventID, runID: UUID(), contextID: "ctx", engineName: "engine",
            schemaVersion: 3, sequence: 1, spanID: nil, parentSpanID: nil,
            payload: .step, timestamp: Date()
        ))
        try await store.flush()

        let wireEvent = try XCTUnwrap(collector.allEvents.first)
        XCTAssertEqual(wireEvent["id"] as? String, eventID.uuidString,
                       "the recorded TraceEvent.id must reach the server — a reminted UUID breaks all ID-based correlation")
        XCTAssertEqual(wireEvent["schema_version"] as? Int, 3)
    }

    func testLineageEdgesAreDrainedAndTransmitted() async throws {
        let collector = EnvelopeCollector()
        MockURLProtocol.requestHandler = { request in
            collector.record(request)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }

        let store = CloudTraceStore<WireEvent>(
            endpoint: URL(string: "https://api.dprovenance.cloud")!, apiKey: "test", session: session
        )
        let source = UUID(), target = UUID()
        store.link(source: source, target: target, type: .derivedFrom)
        // No events at all: flush must still drain and deliver the edge, and must
        // return (rather than believing the backlog is empty and leaving it queued).
        try await store.flush(timeout: 5.0)

        let wireEdge = try XCTUnwrap(collector.allEdges.first, "a linked edge must be transmitted, not queued forever")
        XCTAssertEqual(wireEdge["source_id"] as? String, source.uuidString)
        XCTAssertEqual(wireEdge["target_id"] as? String, target.uuidString)
        XCTAssertEqual(wireEdge["edge_type"] as? String, TraceEdgeType.derivedFrom.rawValue)
    }

    func testEncodeFailureIsCountedInDropStats() {
        let store = CloudTraceStore<UnencodableCloudPayload>(
            endpoint: URL(string: "https://api.dprovenance.cloud")!, apiKey: "test", session: session
        )
        XCTAssertTrue(store.dropStats.preservedIntegrity)

        store.record(TraceEvent<UnencodableCloudPayload>(
            runID: UUID(), contextID: "ctx", engineName: "engine",
            schemaVersion: 1, sequence: 0, spanID: nil, parentSpanID: nil,
            payload: UnencodableCloudPayload()
        ))

        XCTAssertEqual(store.dropStats.critical, 1,
                       "an unencodable payload must be counted in its tier, not silently vanish")
        XCTAssertFalse(store.dropStats.preservedIntegrity)
    }

    func testQueryQuarantinedEventsRoundTripsIdentityAndSchemaVersion() async throws {
        // The consumer-facing quarantine read path: a 400-rejected event must come
        // back through queryQuarantinedEvents with the id and schemaVersion it was
        // recorded with — this is what lets the replay engine match it to the run.
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!, Data())
        }
        let store = CloudTraceStore<WireEvent>(
            endpoint: URL(string: "https://api.dprovenance.cloud")!, apiKey: "test", session: session
        )
        let eventID = UUID()
        store.record(TraceEvent<WireEvent>(
            id: eventID, runID: UUID(), contextID: "ctx", engineName: "engine",
            schemaVersion: 4, sequence: 1, spanID: nil, parentSpanID: nil,
            payload: .step, timestamp: Date()
        ))
        try await store.flush(timeout: 5.0)

        let quarantined = try await store.queryQuarantinedEvents(TraceQueryDSL<WireEvent>())
        XCTAssertEqual(quarantined.map(\.id), [eventID])
        XCTAssertEqual(quarantined.first?.schemaVersion, 4)
    }

    func testQuarantinedBatchRetainsItsEdgesAndEventIdentity() async throws {
        // Drive CloudWriter directly (no background ticker) for determinism.
        let buffer = TraceWriteBuffer(config: OfflineConfig())
        let writer = CloudWriter(
            endpoint: URL(string: "https://api.dprovenance.cloud/ingest")!,
            apiKey: "test", buffer: buffer, session: session
        )
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!, Data())
        }

        let eventID = UUID()
        buffer.enqueue(TraceEventRow(
            id: eventID.uuidString, runID: UUID().uuidString, contextID: "ctx",
            priority: TracePriority.structural.rawValue, sequence: 0, engine: "engine",
            spanID: nil, parentSpanID: nil, type: "step", payload: Data("{}".utf8),
            timestamp: 0, schemaVersion: 2
        ))
        let edge = TraceEdge(sourceID: UUID(), targetID: UUID(), type: .verifiedBy)
        buffer.enqueueEdge(edge)

        try await writer.flush(timeout: 5.0)

        let quarantinedEvents = await writer.getQuarantinedEvents()
        XCTAssertEqual(quarantinedEvents.map(\.id), [eventID.uuidString],
                       "a quarantined event keeps the identity it was recorded with")
        XCTAssertEqual(quarantinedEvents.first?.schemaVersion, 2)
        let quarantinedEdges = await writer.getQuarantinedEdges()
        XCTAssertEqual(quarantinedEdges, [edge],
                       "edges drained with a poison batch must be quarantined with it, not lost")
    }
}
