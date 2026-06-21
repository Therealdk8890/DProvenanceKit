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
                if let dict = try? JSONSerialization.jsonObject(with: bodyData) as? [[String: Any]] {
                    Task {
                        await actorCounts.add(dict.count)
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
}

actor CounterActor {
    var count = 0
    func add(_ val: Int) { count += val }
}
