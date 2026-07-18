import XCTest
@testable import DProvenanceKit

private final class CloudReadURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _handler:
        ((URLRequest) throws -> (HTTPURLResponse, Data))?

    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { lock.withLock { _handler } }
        set { lock.withLock { _handler = newValue } }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.withLock {
            defer { value += 1 }
            return value
        }
    }

    var current: Int {
        lock.withLock { value }
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value?

    var value: Value? {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

final class CloudTraceStoreReadTests: XCTestCase {
    private struct ReadEvent: TraceableEvent {
        let name: String
        let priority: TracePriority

        var typeIdentifier: String { name }
    }

    /// Encodes as a bare JSON string fragment — the simplest legal `TraceableEvent`
    /// conformance and the shape that used to fall into the ingest base64 fallback.
    private enum FragmentEvent: String, TraceableEvent {
        case started

        var priority: TracePriority { .structural }
        var typeIdentifier: String { rawValue }
    }

    private var session: URLSession!
    /// Unique per test. The URLProtocol handler is a class-level static shared by
    /// every session in the process; scoping each handler to its own bearer key is
    /// what keeps a request leaked from an earlier test's writer (an in-flight
    /// ingest retry can outlive its test) from reaching this test's assertions.
    private var testAPIKey: String!
    private let endpoint = URL(string: "https://self-hosted.example/v1")!

    override func setUp() {
        super.setUp()
        testAPIKey = UUID().uuidString
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudReadURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    /// Installs the shared handler scoped to this test's stores: foreign requests
    /// (any other bearer key) fail inertly instead of running this test's closure.
    private func install(_ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) {
        let expectedAuthorization = "Bearer \(testAPIKey!)"
        CloudReadURLProtocol.handler = { request in
            guard request.value(forHTTPHeaderField: "Authorization") == expectedAuthorization else {
                throw URLError(.cancelled)
            }
            return try handler(request)
        }
    }

    override func tearDown() {
        CloudReadURLProtocol.handler = nil
        session.invalidateAndCancel()
        session = nil
        super.tearDown()
    }

    func testQueryRunsDecodesPagesAndPushesRemainingLimit() async throws {
        let run1 = UUID()
        let run2 = UUID()
        let event1 = UUID()
        let event2 = UUID()
        let counter = LockedCounter()

        install { [endpoint] request in
            XCTAssertEqual(request.url?.path, "/v1/query")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

            let body = try Self.bodyData(from: request)
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            XCTAssertEqual(object["schemaVersion"] as? String, "1.0")

            let page = counter.next()
            let responseObject: [String: Any]
            if page == 0 {
                XCTAssertEqual(object["limit"] as? Int, 2)
                XCTAssertNil(object["cursor"])
                responseObject = [
                    "schemaVersion": "1.0",
                    "runs": [
                        Self.runObject(
                            runID: run1,
                            contextID: "ctx-1",
                            events: [
                                Self.eventObject(
                                    id: event1,
                                    runID: run1,
                                    contextID: "ctx-1",
                                    sequence: 0
                                )
                            ]
                        )
                    ],
                    "nextCursor": "opaque-page-2"
                ]
            } else {
                XCTAssertEqual(object["limit"] as? Int, 1)
                XCTAssertEqual(object["cursor"] as? String, "opaque-page-2")
                responseObject = [
                    "schemaVersion": "1.0",
                    "runs": [
                        Self.runObject(
                            runID: run2,
                            contextID: "ctx-2",
                            events: [
                                Self.eventObject(
                                    id: event2,
                                    runID: run2,
                                    contextID: "ctx-2",
                                    sequence: 0
                                )
                            ]
                        )
                    ],
                    "nextCursor": NSNull()
                ]
            }

            return (
                Self.response(url: request.url ?? endpoint, status: 200),
                try JSONSerialization.data(withJSONObject: responseObject)
            )
        }

        let store = CloudTraceStore<ReadEvent>(
            endpoint: endpoint,
            apiKey: testAPIKey,
            session: session
        )
        let runs = try await store.queryRuns(
            TraceQueryDSL<ReadEvent>().requiring(step: "step"),
            limit: 2
        )

        XCTAssertEqual(runs.map(\.runID), [run1, run2])
        XCTAssertEqual(runs.flatMap(\.events).map(\.id), [event1, event2])
        XCTAssertTrue(runs.allSatisfy { $0.undecodedEventCount == 0 })
    }

    func testUnboundedQueryUsesNullLimit() async throws {
        install { request in
            let body = try Self.bodyData(from: request)
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            XCTAssertTrue(object["limit"] is NSNull)
            return (
                Self.response(url: request.url!, status: 200),
                try JSONSerialization.data(withJSONObject: [
                    "schemaVersion": "1.0",
                    "runs": [],
                    "nextCursor": NSNull()
                ])
            )
        }

        let store = CloudTraceStore<ReadEvent>(
            endpoint: endpoint,
            apiKey: testAPIKey,
            session: session
        )
        let runs = try await store.queryRuns(TraceQueryDSL<ReadEvent>())
        XCTAssertTrue(runs.isEmpty)
    }

    func testPayloadDriftKeepsRunVisibleAndCountsUndecodedEvent() async throws {
        let runID = UUID()
        let eventID = UUID()
        var drifted = Self.eventObject(
            id: eventID,
            runID: runID,
            contextID: "ctx",
            sequence: 0
        )
        drifted["payload"] = ["new_server_shape": true]

        install { request in
            (
                Self.response(url: request.url!, status: 200),
                try JSONSerialization.data(withJSONObject: [
                    "schemaVersion": "1.0",
                    "runs": [
                        Self.runObject(
                            runID: runID,
                            contextID: "ctx",
                            events: [drifted]
                        )
                    ],
                    "nextCursor": NSNull()
                ])
            )
        }

        let store = CloudTraceStore<ReadEvent>(
            endpoint: endpoint,
            apiKey: testAPIKey,
            session: session
        )
        // A partial run must not disappear merely because the typed client cannot
        // evaluate this predicate authoritatively.
        let runs = try await store.queryRuns(
            TraceQueryDSL<ReadEvent>().requiring(step: "not-present")
        )

        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].runID, runID)
        XCTAssertTrue(runs[0].events.isEmpty)
        XCTAssertEqual(runs[0].undecodedEventCount, 1)
    }

    func testGetRunEventsAndGraphReadsUseStrictEnvelopes() async throws {
        let source = UUID()
        let middle = UUID()
        let target = UUID()
        let runID = UUID()

        install { request in
            let object: [String: Any]
            switch request.url?.path {
            case "/v1/runs/\(runID.uuidString)":
                object = [
                    "schemaVersion": "1.0",
                    "run": Self.runObject(
                        runID: runID,
                        contextID: "ctx",
                        events: [
                            Self.eventObject(
                                id: target,
                                runID: runID,
                                contextID: "ctx",
                                sequence: 0
                            )
                        ]
                    )
                ]
            case "/v1/runs/\(UUID.nilUUID.uuidString)":
                object = ["schemaVersion": "1.0", "run": NSNull()]
            case "/v1/lineage/\(target.uuidString)":
                // Deliberately reverse topological order; connectivity validation
                // must be order-independent.
                object = [
                    "schemaVersion": "1.0",
                    "edges": [
                        Self.edgeObject(source: source, target: middle),
                        Self.edgeObject(source: middle, target: target)
                    ]
                ]
            case "/v1/impact/\(source.uuidString)":
                object = [
                    "schemaVersion": "1.0",
                    "edges": [
                        Self.edgeObject(source: source, target: middle),
                        Self.edgeObject(source: middle, target: target)
                    ]
                ]
            case "/v1/events":
                let body = try Self.bodyData(from: request)
                let requestObject = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: body) as? [String: Any]
                )
                XCTAssertEqual(
                    Set(try XCTUnwrap(requestObject["ids"] as? [String])),
                    Set([source.uuidString, target.uuidString])
                )
                object = [
                    "schemaVersion": "1.0",
                    "events": [
                        Self.eventObject(
                            id: source,
                            runID: runID,
                            contextID: "ctx",
                            sequence: 0
                        ),
                        Self.eventObject(
                            id: target,
                            runID: runID,
                            contextID: "ctx",
                            sequence: 1
                        )
                    ]
                ]
            default:
                XCTFail("unexpected path \(request.url?.path ?? "nil")")
                object = [:]
            }
            return (
                Self.response(url: request.url!, status: 200),
                try JSONSerialization.data(withJSONObject: object)
            )
        }

        let store = CloudTraceStore<ReadEvent>(
            endpoint: endpoint,
            apiKey: testAPIKey,
            session: session
        )
        let fetchedRun = try await store.getRun(id: runID)
        let missingRun = try await store.getRun(id: .nilUUID)
        let lineage = try await store.lineageEdges(of: target)
        let impact = try await store.impactEdges(of: source)
        let events = try await store.getEvents(ids: [source, target])
        XCTAssertEqual(fetchedRun?.events.first?.id, target)
        XCTAssertNil(missingRun)
        XCTAssertEqual(lineage.count, 2)
        XCTAssertEqual(impact.count, 2)
        XCTAssertEqual(Set(events.keys), Set([source, target]))
    }

    func testMalformedIdentityAndDecodedTypeMismatchFailLoudly() async throws {
        let requestedID = UUID()
        let runID = UUID()
        var malformed = Self.eventObject(
            id: requestedID,
            runID: runID,
            contextID: "ctx",
            sequence: 0
        )
        malformed["id"] = "not-a-uuid"

        install { request in
            (
                Self.response(url: request.url!, status: 200),
                try JSONSerialization.data(withJSONObject: [
                    "schemaVersion": "1.0",
                    "events": [malformed]
                ])
            )
        }

        let store = CloudTraceStore<ReadEvent>(
            endpoint: endpoint,
            apiKey: testAPIKey,
            session: session
        )
        do {
            _ = try await store.getEvents(ids: [requestedID])
            XCTFail("invalid UUID must fail the read")
        } catch CloudTraceStoreError.invalidResponse {
            // Expected.
        }

        var mismatched = Self.eventObject(
            id: requestedID,
            runID: runID,
            contextID: "ctx",
            sequence: 0
        )
        mismatched["type"] = "server-lied-about-type"
        install { request in
            (
                Self.response(url: request.url!, status: 200),
                try JSONSerialization.data(withJSONObject: [
                    "schemaVersion": "1.0",
                    "events": [mismatched]
                ])
            )
        }

        do {
            _ = try await store.getEvents(ids: [requestedID])
            XCTFail("decoded payload/type disagreement must fail the read")
        } catch CloudTraceStoreError.invalidResponse {
            // Expected.
        }
    }

    func testCapabilitiesDecodeTypedOperationsAndValidateShape() async throws {
        install { request in
            XCTAssertEqual(request.url?.path, "/v1/capabilities")
            XCTAssertEqual(request.httpMethod, "GET")
            return (
                Self.response(url: request.url!, status: 200),
                try JSONSerialization.data(withJSONObject: [
                    "schemaVersions": ["1.0"],
                    "operations": [
                        "query", "get_run", "get_events", "lineage", "impact", "future_read"
                    ],
                    "maxQueryLimit": NSNull(),
                    "maxPageSize": 100
                ])
            )
        }

        let store = CloudTraceStore<ReadEvent>(
            endpoint: endpoint,
            apiKey: testAPIKey,
            session: session
        )
        let capabilities = try await store.negotiateCapabilities()
        XCTAssertEqual(capabilities.schemaVersions, ["1.0"])
        XCTAssertNil(capabilities.maxQueryLimit)
        XCTAssertEqual(capabilities.maxPageSize, 100)
        XCTAssertTrue(capabilities.operations.contains(.query))
        XCTAssertTrue(capabilities.operations.contains(.other("future_read")))

        install { request in
            (
                Self.response(url: request.url!, status: 200),
                try JSONSerialization.data(withJSONObject: [
                    "schemaVersions": ["1.0", "1.0"],
                    "operations": [],
                    "maxQueryLimit": 1
                ])
            )
        }
        do {
            _ = try await store.negotiateCapabilities()
            XCTFail("duplicate capability schema versions must fail")
        } catch CloudTraceStoreError.invalidResponse {
            // Expected.
        }
    }

    func testAllReadEndpointsShareSchemaAndHTTPErrorHandling() async throws {
        install { request in
            (
                Self.response(url: request.url!, status: 422),
                try JSONSerialization.data(withJSONObject: [
                    "error": "UNSUPPORTED_SCHEMA",
                    "expected": "2.0",
                    "received": "1.0"
                ])
            )
        }
        let store = CloudTraceStore<ReadEvent>(
            endpoint: endpoint,
            apiKey: testAPIKey,
            session: session
        )
        do {
            _ = try await store.queryRuns(TraceQueryDSL<ReadEvent>())
            XCTFail("schema error must surface")
        } catch CloudTraceStoreError.unsupportedSchema(
            expected: "2.0",
            received: "1.0"
        ) {
            // Expected.
        }

        install { request in
            (Self.response(url: request.url!, status: 503), Data())
        }
        do {
            _ = try await store.impactEdges(of: UUID())
            XCTFail("non-2xx must surface")
        } catch CloudTraceStoreError.serverError(503) {
            // Expected.
        }

        install { request in
            (
                Self.response(url: request.url!, status: 200),
                try JSONSerialization.data(withJSONObject: [
                    "schemaVersion": "9.9",
                    "edges": []
                ])
            )
        }
        do {
            _ = try await store.lineageEdges(of: UUID())
            XCTFail("mismatched success schema must fail")
        } catch CloudTraceStoreError.invalidResponse {
            // Expected.
        }
    }

    func testConcurrentRepeatedShutdownClosesIntakeAndCountsLaterLosses() async throws {
        let delivered = XCTestExpectation(description: "pre-close event delivered")
        install { request in
            XCTAssertEqual(request.url?.path, "/v1/ingest")
            delivered.fulfill()
            return (Self.response(url: request.url!, status: 200), Data())
        }

        let store = CloudTraceStore<ReadEvent>(
            endpoint: endpoint,
            apiKey: testAPIKey,
            session: session
        )
        store.record(
            TraceEvent(
                runID: UUID(),
                contextID: "before-close",
                engineName: "engine",
                schemaVersion: 1,
                sequence: 0,
                spanID: nil,
                parentSpanID: nil,
                payload: ReadEvent(name: "step", priority: .structural)
            )
        )

        async let first: Void = store.shutdown(timeout: 2)
        async let second: Void = store.shutdown(timeout: 2)
        _ = try await (first, second)
        try await store.shutdown(timeout: 2)
        await fulfillment(of: [delivered], timeout: 2)

        store.record(
            TraceEvent(
                runID: UUID(),
                contextID: "after-close",
                engineName: "engine",
                schemaVersion: 1,
                sequence: 0,
                spanID: nil,
                parentSpanID: nil,
                payload: ReadEvent(name: "critical", priority: .critical)
            )
        )
        store.link(source: UUID(), target: UUID(), type: .derivedFrom)

        XCTAssertEqual(store.dropStats.critical, 1)
        XCTAssertEqual(store.dropStats.structural, 1)
        XCTAssertFalse(store.dropStats.preservedIntegrity)
    }

    func testAllTraceEdgeTypesDecodeWithoutCoercion() async throws {
        let types: [TraceEdgeType] = [
            .derivedFrom, .influencedBy, .generatedFrom,
            .verifiedBy, .correctedBy, .informed
        ]
        let nodes = (0...types.count).map { _ in UUID() }
        let edgeObjects = types.enumerated().map { index, type in
            [
                "source_id": nodes[index + 1].uuidString,
                "target_id": nodes[index].uuidString,
                "edge_type": type.rawValue
            ]
        }

        install { request in
            (
                Self.response(url: request.url!, status: 200),
                try JSONSerialization.data(withJSONObject: [
                    "schemaVersion": "1.0",
                    "edges": edgeObjects
                ])
            )
        }
        let store = CloudTraceStore<ReadEvent>(
            endpoint: endpoint,
            apiKey: testAPIKey,
            session: session
        )

        let edges = try await store.lineageEdges(of: nodes[0])
        XCTAssertEqual(edges.map(\.type), types)
    }

    func testMalformedGraphClosuresFailClosed() async throws {
        let root = UUID()
        let source = UUID()
        let counter = LockedCounter()

        install { request in
            let edgeObjects: [[String: Any]]
            switch counter.next() {
            case 0:
                edgeObjects = [
                    Self.edgeObject(source: UUID(), target: UUID())
                ]
            case 1:
                let edge = Self.edgeObject(source: source, target: root)
                edgeObjects = [edge, edge]
            default:
                edgeObjects = [
                    Self.edgeObject(source: root, target: root)
                ]
            }
            return (
                Self.response(url: request.url!, status: 200),
                try JSONSerialization.data(withJSONObject: [
                    "schemaVersion": "1.0",
                    "edges": edgeObjects
                ])
            )
        }
        let store = CloudTraceStore<ReadEvent>(
            endpoint: endpoint,
            apiKey: testAPIKey,
            session: session
        )

        for description in ["disconnected", "duplicate", "self-referential"] {
            do {
                _ = try await store.lineageEdges(of: root)
                XCTFail("\(description) edge response must fail")
            } catch CloudTraceStoreError.invalidResponse {
                // Expected.
            }
        }
    }

    func testEmptyPaginationPageWithCursorFailsInsteadOfLooping() async throws {
        let counter = LockedCounter()
        install { request in
            let page = counter.next()
            return (
                Self.response(url: request.url!, status: 200),
                try JSONSerialization.data(withJSONObject: [
                    "schemaVersion": "1.0",
                    "runs": [],
                    // A malicious server can mint a unique cursor forever; the client
                    // must reject the first no-progress page, not just repeats.
                    "nextCursor": "unique-cursor-\(page)"
                ])
            )
        }
        let store = CloudTraceStore<ReadEvent>(
            endpoint: endpoint,
            apiKey: testAPIKey,
            session: session
        )

        do {
            _ = try await store.queryRuns(TraceQueryDSL<ReadEvent>())
            XCTFail("an empty cursor page must fail instead of looping forever")
        } catch CloudTraceStoreError.invalidResponse {
            // Expected.
        }
        XCTAssertEqual(counter.current, 1)
    }

    func testGetEventsRejectsEventOutsideRequestedIDs() async throws {
        let requestedID = UUID()
        let returnedID = UUID()
        let runID = UUID()
        install { request in
            (
                Self.response(url: request.url!, status: 200),
                try JSONSerialization.data(withJSONObject: [
                    "schemaVersion": "1.0",
                    "events": [
                        Self.eventObject(
                            id: returnedID,
                            runID: runID,
                            contextID: "ctx",
                            sequence: 0
                        )
                    ]
                ])
            )
        }
        let store = CloudTraceStore<ReadEvent>(
            endpoint: endpoint,
            apiKey: testAPIKey,
            session: session
        )

        do {
            _ = try await store.getEvents(ids: [requestedID])
            XCTFail("overbroad event response must fail")
        } catch CloudTraceStoreError.invalidResponse {
            // Expected.
        }
    }

    func testGetRunRejectsRunAndContextIdentityMismatches() async throws {
        let requestedRunID = UUID()
        let differentRunID = UUID()
        let counter = LockedCounter()
        install { request in
            let runObject: [String: Any]
            if counter.next() == 0 {
                runObject = Self.runObject(
                    runID: differentRunID,
                    contextID: "ctx",
                    events: [
                        Self.eventObject(
                            id: UUID(),
                            runID: differentRunID,
                            contextID: "ctx",
                            sequence: 0
                        )
                    ]
                )
            } else {
                runObject = Self.runObject(
                    runID: requestedRunID,
                    contextID: "envelope-context",
                    events: [
                        Self.eventObject(
                            id: UUID(),
                            runID: requestedRunID,
                            contextID: "different-event-context",
                            sequence: 0
                        )
                    ]
                )
            }
            return (
                Self.response(url: request.url!, status: 200),
                try JSONSerialization.data(withJSONObject: [
                    "schemaVersion": "1.0",
                    "run": runObject
                ])
            )
        }
        let store = CloudTraceStore<ReadEvent>(
            endpoint: endpoint,
            apiKey: testAPIKey,
            session: session
        )

        for description in ["run id", "context id"] {
            do {
                _ = try await store.getRun(id: requestedRunID)
                XCTFail("\(description) mismatch must fail")
            } catch CloudTraceStoreError.invalidResponse {
                // Expected.
            }
        }
    }

    func testShutdownTimeoutReportsRetainedUndeliveredCount() async throws {
        install { request in
            // The delay caps how many failures the background ticker can record
            // before shutdown cancels it: if 5 instant 500s landed first, the open
            // breaker (30s decay) would outlive the recovery drain below.
            Thread.sleep(forTimeInterval: 0.25)
            return (Self.response(url: request.url!, status: 500), Data())
        }
        let store = CloudTraceStore<ReadEvent>(
            endpoint: endpoint,
            apiKey: testAPIKey,
            session: session
        )
        store.record(
            TraceEvent(
                runID: UUID(),
                contextID: "ctx",
                engineName: "engine",
                schemaVersion: 1,
                sequence: 0,
                spanID: nil,
                parentSpanID: nil,
                payload: ReadEvent(name: "critical", priority: .critical)
            )
        )

        do {
            try await store.shutdown(timeout: 0)
            XCTFail("shutdown must not hide an incomplete drain")
        } catch CloudWriterError.flushTimedOut(undelivered: 1) {
            // Expected: the event remains buffered or inflight.
        }

        // Quiesce before the test ends: the writer's cancelled ticker can still have
        // an ingest send in flight, and a request that starts after the next test
        // installs its handler would otherwise leak into that test. Let the retained
        // event deliver, proving timeout kept it (and that a poisoned breaker never
        // blocks the recovery drain), then stop the writer for real.
        install { request in
            (Self.response(url: request.url!, status: 200), Data())
        }
        try await store.shutdown(timeout: 5)
    }

    func testRemoteReadRefusesQuarantinedWriteAndNeverSendsQuery() async throws {
        let requestCount = LockedCounter()
        install { request in
            _ = requestCount.next()
            if request.url?.path == "/v1/ingest" {
                return (Self.response(url: request.url!, status: 400), Data())
            }
            XCTFail("hosted read must not run after an undelivered batch was quarantined")
            return (
                Self.response(url: request.url!, status: 200),
                try JSONSerialization.data(withJSONObject: [
                    "schemaVersion": "1.0",
                    "runs": [],
                    "nextCursor": NSNull()
                ])
            )
        }
        let store = CloudTraceStore<ReadEvent>(
            endpoint: endpoint,
            apiKey: testAPIKey,
            session: session
        )
        store.record(
            TraceEvent(
                runID: UUID(),
                contextID: "ctx",
                engineName: "engine",
                schemaVersion: 1,
                sequence: 0,
                spanID: nil,
                parentSpanID: nil,
                payload: ReadEvent(name: "critical", priority: .critical)
            )
        )

        do {
            _ = try await store.queryRuns(TraceQueryDSL<ReadEvent>())
            XCTFail("quarantine must break the remote read barrier")
        } catch CloudTraceStoreError.undeliveredQuarantine(count: 1) {
            // Expected.
        }
        XCTAssertEqual(requestCount.current, 1, "only ingest may reach the server")
    }

    func testShutdownTimeoutIncludesNonCooperativeTickerWait() async throws {
        let buffer = TraceWriteBuffer()
        buffer.enqueue(
            TraceEventRow(
                id: UUID().uuidString,
                runID: UUID().uuidString,
                contextID: "ctx",
                priority: TracePriority.critical.rawValue,
                sequence: 0,
                engine: "engine",
                spanID: nil,
                parentSpanID: nil,
                type: "critical",
                payload: Data("{}".utf8),
                timestamp: 0
            )
        )
        let writer = CloudWriter(
            endpoint: endpoint.appendingPathComponent("ingest"),
            apiKey: testAPIKey,
            buffer: buffer,
            session: session
        )
        await writer.startNonCooperativeTaskForShutdownTesting(duration: 1.0)

        let started = Date()
        do {
            try await writer.shutdown(timeout: 0.05)
            XCTFail("shutdown must time out while a ticker ignores cancellation")
        } catch CloudWriterError.flushTimedOut(undelivered: 1) {
            // Expected.
        }
        // The claim under test is only that shutdown honors its own deadline instead
        // of waiting out the full 1.0s non-cooperative task. The bound leaves a wide
        // margin over the 0.05s timeout so scheduler noise on a saturated CI runner
        // can't fail a correct implementation, while an implementation that awaits
        // the task would need the full second and still trips it.
        XCTAssertLessThan(
            Date().timeIntervalSince(started),
            0.6,
            "the task wait must share the caller's shutdown deadline"
        )
    }

    func testZeroQueryLimitReturnsNoRuns() async throws {
        install { request in
            XCTFail("zero-limit query must not flush or touch the network")
            return (Self.response(url: request.url!, status: 500), Data())
        }
        let store = CloudTraceStore<ReadEvent>(
            endpoint: endpoint,
            apiKey: testAPIKey,
            session: session
        )

        let runs = try await store.queryRuns(
            TraceQueryDSL<ReadEvent>(),
            limit: 0
        )
        XCTAssertTrue(runs.isEmpty)
    }

    func testFragmentPayloadRidesTheWireAsJSONAndReadsBackTyped() async throws {
        let captured = LockedBox<Data>()
        install { request in
            XCTAssertEqual(request.url?.path, "/v1/ingest")
            captured.value = try Self.bodyData(from: request)
            return (Self.response(url: request.url!, status: 200), Data())
        }

        let store = CloudTraceStore<FragmentEvent>(
            endpoint: endpoint,
            apiKey: testAPIKey,
            session: session
        )
        let runID = UUID()
        store.record(
            TraceEvent(
                runID: runID,
                contextID: "ctx",
                engineName: "engine",
                schemaVersion: 1,
                sequence: 0,
                spanID: nil,
                parentSpanID: nil,
                payload: .started
            )
        )
        try await store.flush()

        let body = try XCTUnwrap(captured.value)
        let envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let wireEvents = try XCTUnwrap(envelope["events"] as? [[String: Any]])
        let wireEvent = try XCTUnwrap(wireEvents.first)
        XCTAssertEqual(
            wireEvent["payload"] as? String,
            "started",
            "a single-value payload must ride the wire as JSON, not the irreversible base64 fallback"
        )

        // Serve the EXACT ingested wire event back: the typed read must round-trip
        // instead of counting the simplest legal event type as undecodable drift.
        install { request in
            (
                Self.response(url: request.url!, status: 200),
                try JSONSerialization.data(withJSONObject: [
                    "schemaVersion": "1.0",
                    "run": [
                        "run_id": runID.uuidString,
                        "context_id": "ctx",
                        "events": [wireEvent]
                    ] as [String: Any]
                ])
            )
        }
        let run = try await store.getRun(id: runID)
        XCTAssertEqual(run?.events.first?.payload, .started)
        XCTAssertEqual(run?.undecodedEventCount, 0)
    }

    func testAllHostedReadsRefuseUndeliveredQuarantine() async throws {
        install { request in
            XCTAssertEqual(
                request.url?.path,
                "/v1/ingest",
                "no hosted read may reach the server over a quarantined write"
            )
            return (Self.response(url: request.url!, status: 400), Data())
        }
        let store = CloudTraceStore<ReadEvent>(
            endpoint: endpoint,
            apiKey: testAPIKey,
            session: session
        )
        store.record(
            TraceEvent(
                runID: UUID(),
                contextID: "ctx",
                engineName: "engine",
                schemaVersion: 1,
                sequence: 0,
                spanID: nil,
                parentSpanID: nil,
                payload: ReadEvent(name: "critical", priority: .critical)
            )
        )

        // Every hosted read shares the same delivery barrier; each call site is an
        // independent mutation point, so each is pinned independently.
        func expectRefused(
            _ name: String,
            _ read: () async throws -> Void
        ) async {
            do {
                try await read()
                XCTFail("\(name) must refuse to read over an undelivered quarantined write")
            } catch CloudTraceStoreError.undeliveredQuarantine(count: 1) {
                // Expected.
            } catch {
                XCTFail("\(name) threw \(error) instead of undeliveredQuarantine")
            }
        }
        await expectRefused("queryRuns") { _ = try await store.queryRuns(TraceQueryDSL<ReadEvent>()) }
        await expectRefused("getRun") { _ = try await store.getRun(id: UUID()) }
        await expectRefused("getEvents") { _ = try await store.getEvents(ids: [UUID()]) }
        await expectRefused("lineageEdges") { _ = try await store.lineageEdges(of: UUID()) }
        await expectRefused("impactEdges") { _ = try await store.impactEdges(of: UUID()) }
    }

    func testQueryRejectsDecodableRunThatDoesNotMatchTheQuery() async throws {
        let runID = UUID()
        install { request in
            (
                Self.response(url: request.url!, status: 200),
                try JSONSerialization.data(withJSONObject: [
                    "schemaVersion": "1.0",
                    "runs": [
                        Self.runObject(
                            runID: runID,
                            contextID: "ctx",
                            events: [
                                Self.eventObject(
                                    id: UUID(),
                                    runID: runID,
                                    contextID: "ctx",
                                    sequence: 0
                                )
                            ]
                        )
                    ],
                    "nextCursor": NSNull()
                ])
            )
        }
        let store = CloudTraceStore<ReadEvent>(
            endpoint: endpoint,
            apiKey: testAPIKey,
            session: session
        )

        do {
            _ = try await store.queryRuns(
                TraceQueryDSL<ReadEvent>().requiring(step: "absent-step")
            )
            XCTFail("a fully-decodable run that fails the query predicate must be rejected")
        } catch CloudTraceStoreError.invalidResponse(_, let reason) {
            XCTAssertTrue(
                reason.contains("does not match the query"),
                "unexpected rejection reason: \(reason)"
            )
        }
    }

    func testShutdownCancellationLeavesBreakerCleanAndBatchDeliverable() async throws {
        let buffer = TraceWriteBuffer()
        buffer.enqueue(
            TraceEventRow(
                id: UUID().uuidString,
                runID: UUID().uuidString,
                contextID: "ctx",
                priority: TracePriority.critical.rawValue,
                sequence: 0,
                engine: "engine",
                spanID: nil,
                parentSpanID: nil,
                type: "critical",
                payload: Data("{}".utf8),
                timestamp: 0
            )
        )
        let breaker = CircuitBreaker()
        let writer = CloudWriter(
            endpoint: endpoint.appendingPathComponent("ingest"),
            apiKey: testAPIKey,
            buffer: buffer,
            session: session,
            circuitBreaker: breaker
        )
        install { request in
            // Hold the send in flight long enough for cancellation to land mid-send.
            Thread.sleep(forTimeInterval: 0.4)
            return (Self.response(url: request.url!, status: 500), Data())
        }

        let sendTask = Task { await writer.processOnceForTesting(drainAll: true) }
        try await Task.sleep(nanoseconds: 100_000_000)
        sendTask.cancel()
        await sendTask.value

        // A cancelled send is caller intent, not endpoint feedback: it must not
        // open the breaker (which would stall the final drain for the breaker's
        // full recovery window) and must not consume the retry budget.
        let waitTime = await breaker.timeUntilAllowed()
        XCTAssertEqual(
            waitTime,
            0,
            "cancellation mid-send must not record circuit-breaker failures"
        )
        let quarantinedAfterCancel = await writer.quarantinedStats().total
        XCTAssertEqual(
            quarantinedAfterCancel,
            0,
            "a cancelled send must keep its batch inflight, not quarantine it"
        )

        // The retained batch must deliver on the caller's uncancelled drain.
        install { request in
            (Self.response(url: request.url!, status: 200), Data())
        }
        try await writer.flush(timeout: 5)
        let quarantinedAfterDrain = await writer.quarantinedStats().total
        XCTAssertEqual(quarantinedAfterDrain, 0)
    }

    private static func eventObject(
        id: UUID,
        runID: UUID,
        contextID: String,
        sequence: Int
    ) -> [String: Any] {
        [
            "id": id.uuidString,
            "run_id": runID.uuidString,
            "context_id": contextID,
            "priority": TracePriority.structural.rawValue,
            "sequence": sequence,
            "engine": "engine",
            "span_id": NSNull(),
            "parent_span_id": NSNull(),
            "type": "step",
            "payload": [
                "name": "step",
                "priority": TracePriority.structural.rawValue
            ],
            "timestamp": 1_767_225_600_000_000 as Int64,
            "schema_version": 3
        ]
    }

    private static func runObject(
        runID: UUID,
        contextID: String,
        events: [[String: Any]]
    ) -> [String: Any] {
        [
            "run_id": runID.uuidString,
            "context_id": contextID,
            "events": events
        ]
    }

    private static func edgeObject(
        source: UUID,
        target: UUID
    ) -> [String: Any] {
        [
            "source_id": source.uuidString,
            "target_id": target.uuidString,
            "edge_type": "derivedFrom"
        ]
    }

    private static func response(url: URL, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
    }

    private static func bodyData(from request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }

        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 {
                throw stream.streamError ?? URLError(.cannotDecodeRawData)
            }
            if count == 0 { break }
            result.append(buffer, count: count)
        }
        return result
    }
}

private extension UUID {
    static let nilUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
}
