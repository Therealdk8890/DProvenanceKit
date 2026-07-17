import XCTest
@testable import DProvenanceKit

final class CloudTraceStoreChaosTests: XCTestCase {
    
    enum ChaosEvent: TraceableEvent {
        case tiny
        case huge(Data)
        
        var typeIdentifier: String { "chaos" }
        var priority: TracePriority { .structural }
    }
    
    var session: URLSession!
    
    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: configuration)
    }
    
    func testWriteAmplificationDefense() async throws {
        // max bytes = 1MB, max event size = 500KB
        let config = OfflineConfig(
            capacity: BufferCapacity(maxItems: 1000, maxBytes: 1_000_000, maxEventSizeBytes: 500_000),
            eviction: .dropOldest
        )
        
        let endpoint = URL(string: "https://api.dprovenance.cloud")!
        let store = CloudTraceStore<ChaosEvent>(endpoint: endpoint, apiKey: "test", config: config, session: session)
        
        let small = TraceEvent<ChaosEvent>(
            runID: UUID(), contextID: "1", engineName: "test", schemaVersion: 1, sequence: 1,
            spanID: nil, parentSpanID: nil, payload: .tiny, timestamp: Date()
        )
        store.record(small)
        
        // 600KB
        let hugeData = Data(repeating: 0, count: 600_000)
        let huge = TraceEvent<ChaosEvent>(
            runID: UUID(), contextID: "1", engineName: "test", schemaVersion: 1, sequence: 2,
            spanID: nil, parentSpanID: nil, payload: .huge(hugeData), timestamp: Date()
        )
        store.record(huge)
        
        XCTAssertEqual(store.dropStats.structural, 1, "The huge event should have been instantly rejected")
        
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        try await store.flush()
    }
    
    func testPoisonBatchQuarantine() async throws {
        let config = OfflineConfig()
        let endpoint = URL(string: "https://api.dprovenance.cloud")!
        let store = CloudTraceStore<ChaosEvent>(endpoint: endpoint, apiKey: "test", config: config, session: session)
        
        var attempts = 0
        MockURLProtocol.requestHandler = { request in
            if request.url?.path == "/capabilities" {
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
            }
            
            attempts += 1
            if attempts == 1 {
                let response = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
                return (response, Data())
            } else {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, Data())
            }
        }
        
        let ev1 = TraceEvent<ChaosEvent>(runID: UUID(), contextID: "1", engineName: "test", schemaVersion: 1, sequence: 1, spanID: nil, parentSpanID: nil, payload: .tiny, timestamp: Date())
        store.record(ev1)
        
        try await store.flush()
        
        XCTAssertEqual(attempts, 1) // Failed 400 and was quarantined
        
        let ev2 = TraceEvent<ChaosEvent>(runID: UUID(), contextID: "1", engineName: "test", schemaVersion: 1, sequence: 2, spanID: nil, parentSpanID: nil, payload: .tiny, timestamp: Date())
        store.record(ev2)
        
        try await store.flush()
        XCTAssertEqual(attempts, 2) // Advanced and succeeded next batch
    }
    
    func testConcurrentEnqueueAndFlush() async throws {
        let config = OfflineConfig()
        let endpoint = URL(string: "https://api.dprovenance.cloud")!
        let store = CloudTraceStore<ChaosEvent>(endpoint: endpoint, apiKey: "test", config: config, session: session)
        
        let actorCounts = CounterActor()
        
        MockURLProtocol.requestHandler = { request in
            if request.url?.path == "/capabilities" {
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
            }
            
            let bodyData: Data
            if let body = request.httpBody {
                bodyData = body
            } else if let stream = request.httpBodyStream {
                stream.open()
                let bufferSize = 4096
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
                var data = Data()
                while stream.hasBytesAvailable {
                    let read = stream.read(buffer, maxLength: bufferSize)
                    if read > 0 {
                        data.append(buffer, count: read)
                    } else { break }
                }
                buffer.deallocate()
                stream.close()
                bodyData = data
            } else {
                bodyData = Data()
            }
            
            if !bodyData.isEmpty {
                if let envelope = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
                   let events = envelope["events"] as? [[String: Any]] {
                    Task {
                        await actorCounts.add(events.count)
                    }
                }
            }
            
            // Sim latency
            Thread.sleep(forTimeInterval: 0.01)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    for i in 0..<100 {
                        let ev = TraceEvent<ChaosEvent>(runID: UUID(), contextID: "1", engineName: "test", schemaVersion: 1, sequence: UInt64(i), spanID: nil, parentSpanID: nil, payload: .tiny, timestamp: Date())
                        store.record(ev)
                    }
                }
            }
        }
        
        try await store.flush()
        let count = await actorCounts.count
        XCTAssertEqual(count, 1000)
    }

    func testFlushTimesOutOnSustainedOutageInsteadOfHanging() async {
        // Drive CloudWriter directly without start(): no background ticker runs, so the
        // test is deterministic and leaves nothing alive to pollute other suites. We're
        // verifying flush()'s own deadline — which is where the hang lived.
        let buffer = TraceWriteBuffer(config: OfflineConfig())
        buffer.enqueue(TraceEventRow(
            id: UUID().uuidString, runID: UUID().uuidString, contextID: "1",
            priority: TracePriority.structural.rawValue, sequence: 1, engine: "test",
            spanID: nil, parentSpanID: nil, type: "chaos", payload: Data("x".utf8), timestamp: 0
        ))
        XCTAssertEqual(buffer.currentDepth, 1, "precondition: the event is buffered")

        let endpoint = URL(string: "https://api.dprovenance.cloud/ingest")!
        let writer = CloudWriter(endpoint: endpoint, apiKey: "test", buffer: buffer, session: session)

        // The endpoint is permanently unreachable: every request fails.
        MockURLProtocol.requestHandler = { _ in throw URLError(.cannotConnectToHost) }

        let start = Date()
        do {
            try await writer.flush(timeout: 1.0)
            XCTFail("flush must not hang — it should time out when the endpoint is unreachable")
        } catch let error as CloudWriterError {
            guard case .flushTimedOut = error else {
                return XCTFail("expected .flushTimedOut, got \(error)")
            }
            // expected: the backlog could not be delivered before the deadline.
        } catch {
            XCTFail("expected CloudWriterError.flushTimedOut, got \(error)")
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 8.0, "flush should give up promptly, not hang indefinitely")
    }

    func testWriterRecoversAfterOutageWhenBufferIdleDuringProbeWindow() async throws {
        // Regression: an empty drain must never consume the circuit breaker's single
        // half-open probe. The writer previously called allowRequest() BEFORE draining,
        // so an idle tick landing in the probe window (breaker .open and decayed, buffer
        // momentarily empty — exactly the recover-after-outage state) moved the breaker to
        // .halfOpen and returned with nothing sent. Because .halfOpen then refuses every
        // request and reports timeUntilAllowed == 0, the writer spun without ever sending
        // again for the process lifetime. Draining first keeps the probe for real work.
        let buffer = TraceWriteBuffer(config: OfflineConfig())
        let breaker = CircuitBreaker(maxFailures: 1, decayTimeout: 0.2)
        let endpoint = URL(string: "https://api.dprovenance.cloud/ingest")!
        let writer = CloudWriter(
            endpoint: endpoint, apiKey: "test", buffer: buffer, session: session,
            circuitBreaker: breaker
        )

        // Trip the breaker open, as a sustained outage would.
        await breaker.recordFailure()
        let openState = await breaker.state
        XCTAssertEqual(openState, .open, "precondition: breaker tripped open")

        // Wait past the decay window so the next probe would be granted.
        try await Task.sleep(nanoseconds: 250_000_000)

        // An idle tick with an empty buffer during the probe window. This must NOT
        // spend the probe — on the buggy ordering the breaker ends up stranded .halfOpen.
        await writer.processOnceForTesting()
        let afterIdle = await breaker.state
        XCTAssertNotEqual(
            afterIdle, .halfOpen,
            "an empty drain must not consume the half-open probe"
        )

        // Real work now arrives and the endpoint is healthy again: it must be delivered.
        var sent = 0
        MockURLProtocol.requestHandler = { request in
            sent += 1
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        buffer.enqueue(TraceEventRow(
            id: UUID().uuidString, runID: UUID().uuidString, contextID: "1",
            priority: TracePriority.structural.rawValue, sequence: 1, engine: "test",
            spanID: nil, parentSpanID: nil, type: "chaos", payload: Data("x".utf8), timestamp: 0
        ))

        try await writer.flush(timeout: 2.0)

        XCTAssertEqual(sent, 1, "writer must resume sending after the outage recovers")
        XCTAssertEqual(buffer.currentDepth, 0, "the event must be delivered, not stuck")
        let recovered = await breaker.state
        XCTAssertEqual(recovered, .closed, "a successful send should close the breaker")
    }
}

actor CounterActor {
    var count = 0
    func add(_ val: Int) { count += val }
}
