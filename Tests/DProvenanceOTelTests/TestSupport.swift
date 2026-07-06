import Foundation
import XCTest
import DProvenanceKit
@testable import DProvenanceOTel

// MARK: - Payload fixtures

/// Plain payload with no OTel semantics.
struct StubEvent: TraceableEvent {
    var typeIdentifier: String
    var priority: TracePriority
    var detail: String

    init(_ typeIdentifier: String, priority: TracePriority = .structural, detail: String = "") {
        self.typeIdentifier = typeIdentifier
        self.priority = priority
        self.detail = detail
    }
}

/// Payload that adopts `OTelSemanticsProviding` (conformance path of M6).
struct GenAIStubEvent: TraceableEvent, OTelSemanticsProviding {
    var typeIdentifier: String = "llm.call"
    var priority: TracePriority = .structural
    var operation: String = "chat"
    var model: String? = "claude-sonnet"
    var tool: String? = nil
    var inputTokens: Int64? = 11
    var outputTokens: Int64? = 29
    var errorType: String? = nil
    var explicitName: String? = nil

    var otelSemantics: GenAIAttributes? {
        GenAIAttributes(
            operationName: operation,
            requestModel: model,
            toolName: tool,
            providerName: "anthropic",
            usageInputTokens: inputTokens,
            usageOutputTokens: outputTokens,
            errorType: errorType
        )
    }
    var otelEventName: String? { explicitName }
}

/// Default `JSONEncoder` rejects non-finite doubles, so this payload exercises
/// the M8 never-throw path (`dpk.payload_error`).
struct UnencodableStubEvent: TraceableEvent {
    var typeIdentifier: String = "unencodable"
    var priority: TracePriority = .diagnostic
    var value: Double = .infinity
}

// MARK: - Event/run builders

let fixedRunID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
let fixedBase: TimeInterval = 1_719_936_000

func makeEvent<T: TraceableEvent>(
    run: UUID = fixedRunID,
    context: String = "ctx",
    engine: String = "TestEngine",
    seq: UInt64,
    span: String? = nil,
    parent: String? = nil,
    payload: T,
    time: TimeInterval? = nil
) -> TraceEvent<T> {
    TraceEvent(
        runID: run,
        contextID: context,
        engineName: engine,
        schemaVersion: 1,
        sequence: seq,
        spanID: span,
        parentSpanID: parent,
        payload: payload,
        timestamp: Date(timeIntervalSince1970: time ?? (fixedBase + Double(seq)))
    )
}

func makeRun<T: TraceableEvent>(_ events: [TraceEvent<T>],
                                run: UUID = fixedRunID,
                                context: String = "ctx") -> TraceRun<T> {
    TraceRun(runID: run, contextID: context, events: events)
}

// MARK: - JSON shape helpers (JSONSerialization keeps NSString/NSNumber distinct)

func decodeJSONObject(_ data: Data) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

func documentSpans(_ document: [String: Any]) throws -> [[String: Any]] {
    let resourceSpans = try XCTUnwrap(document["resourceSpans"] as? [[String: Any]])
    let scopeSpans = try XCTUnwrap(resourceSpans.first?["scopeSpans"] as? [[String: Any]])
    return try XCTUnwrap(scopeSpans.first?["spans"] as? [[String: Any]])
}

func documentResourceAttributes(_ document: [String: Any]) throws -> [[String: Any]] {
    let resourceSpans = try XCTUnwrap(document["resourceSpans"] as? [[String: Any]])
    let resource = try XCTUnwrap(resourceSpans.first?["resource"] as? [String: Any])
    return try XCTUnwrap(resource["attributes"] as? [[String: Any]])
}

func attributeValue(_ attributes: [[String: Any]], _ key: String) -> [String: Any]? {
    attributes.first { $0["key"] as? String == key }?["value"] as? [String: Any]
}

func stringAttribute(_ attributes: [[String: Any]], _ key: String) -> String? {
    attributeValue(attributes, key)?["stringValue"] as? String
}

/// Named to avoid NSObject's KVC `attributeKeys`, which shadows unqualified
/// global lookups inside XCTestCase methods.
func attributeKeyList(_ attributes: [[String: Any]]) -> [String] {
    attributes.compactMap { $0["key"] as? String }
}

func spanNamed(_ spans: [[String: Any]], _ name: String) throws -> [String: Any] {
    try XCTUnwrap(spans.first { $0["name"] as? String == name }, "no span named \(name)")
}

func spanAttributes(_ span: [String: Any]) -> [[String: Any]] {
    span["attributes"] as? [[String: Any]] ?? []
}

func spanEvents(_ span: [String: Any]) -> [[String: Any]] {
    span["events"] as? [[String: Any]] ?? []
}

func isLowercaseHex(_ value: String, count: Int) -> Bool {
    value.count == count && value.allSatisfy { "0123456789abcdef".contains($0) }
}

func mapperDocumentJSON<T: TraceableEvent>(
    _ runs: [TraceRun<T>],
    options: OTelExportOptions<T> = .init()
) throws -> [String: Any] {
    let mapper = OTelSpanMapper(options: options)
    let data = try OTLPJSON.encode(mapper.document(for: runs))
    return try decodeJSONObject(data)
}

// MARK: - HTTP stubbing

/// URLProtocol-based transport stub. State is static because URLSession
/// instantiates the protocol itself; guarded by a lock and reset per test
/// (XCTest runs a class's tests serially).
final class StubURLProtocol: URLProtocol {
    struct StubResponse {
        var statusCode: Int          // negative = simulate a transport error
        var headers: [String: String] = [:]
        var body: Data = Data()
    }

    nonisolated(unsafe) private static var queue: [StubResponse] = []
    nonisolated(unsafe) private static var seenRequests: [URLRequest] = []
    nonisolated(unsafe) private static var seenBodies: [Data] = []
    private static let lock = NSLock()

    static func reset(_ responses: [StubResponse]) {
        lock.withLock {
            queue = responses
            seenRequests = []
            seenBodies = []
        }
    }

    static var requests: [URLRequest] { lock.withLock { seenRequests } }
    static var bodies: [Data] { lock.withLock { seenBodies } }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let stub: StubResponse = Self.lock.withLock {
            Self.seenRequests.append(request)
            Self.seenBodies.append(Self.bodyData(of: request))
            return Self.queue.isEmpty
                ? StubResponse(statusCode: 200)
                : Self.queue.removeFirst()
        }

        if stub.statusCode < 0 {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession delivers POST bodies to protocols as a stream, not `httpBody`.
    private static func bodyData(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
