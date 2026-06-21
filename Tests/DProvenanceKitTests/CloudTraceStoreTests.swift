import XCTest
@testable import DProvenanceKit

final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    
    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }
    
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }
    
    override func startLoading() {
        guard let handler = MockURLProtocol.requestHandler else {
            fatalError("Handler is unavailable.")
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

final class CloudTraceStoreTests: XCTestCase {
    
    enum TestEvent: TraceableEvent {
        case somethingHappened
        
        var typeIdentifier: String { "somethingHappened" }
        var priority: TracePriority { .telemetry }
    }
    
    var session: URLSession!
    
    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: configuration)
    }
    
    func testSuccessfulIngest() async throws {
        let endpoint = URL(string: "https://api.dprovenance.cloud")!
        let store = CloudTraceStore<TestEvent>(endpoint: endpoint, apiKey: "test-key", session: session)
        
        let expectation = XCTestExpectation(description: "Network request made")
        
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/ingest")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            expectation.fulfill()
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        
        let event = TraceEvent<TestEvent>(
            runID: UUID(),
            contextID: "ctx1",
            engineName: "test",
            schemaVersion: 1,
            sequence: 1,
            spanID: nil,
            parentSpanID: nil,
            payload: .somethingHappened,
            timestamp: Date()
        )
        
        store.record(event)
        try await store.flush()
        
        await fulfillment(of: [expectation], timeout: 2.0)
    }
    
    func testQueryDSLSerializationAndNotImplemented() async throws {
        let endpoint = URL(string: "https://api.dprovenance.cloud")!
        let store = CloudTraceStore<TestEvent>(endpoint: endpoint, apiKey: "test-key", session: session)
        
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/query")
            
            let response = HTTPURLResponse(url: request.url!, statusCode: 501, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        
        let dsl = TraceQueryDSL<TestEvent>().requiring(step: "somethingHappened")
        
        do {
            _ = try await store.queryRuns(dsl)
            XCTFail("Should have thrown notImplemented")
        } catch CloudTraceStoreError.notImplemented {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
    
    func testRetryAndBackoff() async throws {
        let endpoint = URL(string: "https://api.dprovenance.cloud")!
        let store = CloudTraceStore<TestEvent>(endpoint: endpoint, apiKey: "test-key", session: session)
        
        var attempts = 0
        let expectation = XCTestExpectation(description: "Successful retry")
        
        // This is safe because tests run sequentially and wait on flush.
        MockURLProtocol.requestHandler = { request in
            attempts += 1
            if attempts < 3 {
                let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
                return (response, Data())
            } else {
                expectation.fulfill()
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, Data())
            }
        }
        
        let event = TraceEvent<TestEvent>(
            runID: UUID(),
            contextID: "ctx1",
            engineName: "test",
            schemaVersion: 1,
            sequence: 1,
            spanID: nil,
            parentSpanID: nil,
            payload: .somethingHappened,
            timestamp: Date()
        )
        
        store.record(event)
        
        // flush will wait for processBatch
        try await store.flush()
        
        await fulfillment(of: [expectation], timeout: 5.0)
        XCTAssertEqual(attempts, 3)
    }
}
