import XCTest
@testable import DProvenanceKit

/// The API key travels as `Authorization: Bearer`. ATS does not cover CLIs, CI runners or
/// opted-out apps, so a mistyped `http://` endpoint used to leak the key in cleartext.
final class CloudTransportSecurityTests: XCTestCase {
    enum Event: TraceableEvent {
        case ping
        var typeIdentifier: String { "ping" }
        var priority: TracePriority { .structural }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    var session: URLSession!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    private func installCountingHandler() -> Counter {
        let counter = Counter()
        MockURLProtocol.requestHandler = { request in
            counter.increment()
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("{}".utf8))
        }
        return counter
    }

    private func row() -> TraceEventRow {
        TraceEventRow(
            id: UUID().uuidString, runID: UUID().uuidString, contextID: "1",
            priority: TracePriority.structural.rawValue, sequence: 1, engine: "test",
            spanID: nil, parentSpanID: nil, type: "ping", payload: Data("{}".utf8), timestamp: 0
        )
    }

    func testCredentialPolicyAllowsHTTPSAndLoopbackOnly() {
        let allowed = [
            "https://api.dprovenance.cloud", "HTTPS://example.com/x",
            "http://localhost:8080", "http://LOCALHOST", "http://dev.localhost:3000",
            "http://127.0.0.1:4318", "http://127.10.20.30", "http://[::1]:4318",
        ]
        let refused = [
            "http://api.dprovenance.cloud", "http://collector.local:4318",
            "http://127.0.0.1.attacker.example", "http://localhost.attacker.example",
            "http://10.0.0.5", "http://[::2]", "http://127.0.0.256",
            "ftp://localhost", "file:///tmp/x",
        ]
        for string in allowed {
            XCTAssertTrue(DPKTransportSecurity.allowsCredentials(to: URL(string: string)!), string)
        }
        for string in refused {
            XCTAssertFalse(DPKTransportSecurity.allowsCredentials(to: URL(string: string)!), string)
        }
    }

    func testWriterRefusesCleartextAndQuarantinesWithoutSending() async throws {
        let counter = installCountingHandler()
        let buffer = TraceWriteBuffer(config: OfflineConfig())
        buffer.enqueue(row())
        let writer = CloudWriter(
            endpoint: URL(string: "http://api.dprovenance.cloud/ingest")!,
            apiKey: "secret", buffer: buffer, session: session
        )
        try await writer.flush(timeout: 5.0)
        XCTAssertEqual(counter.count, 0, "no request may carry the key over cleartext http")
        let quarantined = await writer.getQuarantinedEvents()
        XCTAssertEqual(quarantined.count, 1, "the refused batch must surface, not vanish")
    }

    func testWriterAllowsLoopbackAndExplicitOptIn() async throws {
        let counter = installCountingHandler()
        for (endpoint, optIn) in [("http://127.0.0.1:8080/ingest", false),
                                  ("http://ingest.internal/ingest", true)] {
            let buffer = TraceWriteBuffer(config: OfflineConfig())
            buffer.enqueue(row())
            let writer = CloudWriter(
                endpoint: URL(string: endpoint)!, apiKey: "secret", buffer: buffer,
                session: session, allowInsecureTransport: optIn
            )
            try await writer.flush(timeout: 5.0)
            let quarantined = await writer.getQuarantinedEvents()
            XCTAssertTrue(quarantined.isEmpty, endpoint)
        }
        XCTAssertEqual(counter.count, 2)
    }

    func testStoreReadPathRefusesCleartextBeforeSending() async throws {
        let counter = installCountingHandler()
        let store = CloudTraceStore<Event>(
            endpoint: URL(string: "http://api.dprovenance.cloud")!, apiKey: "secret", session: session
        )
        do {
            _ = try await store.negotiateCapabilities()
            XCTFail("expected insecureEndpoint")
        } catch CloudTraceStoreError.insecureEndpoint(let url) {
            XCTAssertTrue(url.hasPrefix("http://api.dprovenance.cloud"))
        }
        XCTAssertEqual(counter.count, 0)
        try? await store.shutdown(timeout: 1)
    }
}
