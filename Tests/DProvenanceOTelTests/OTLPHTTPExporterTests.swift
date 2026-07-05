import Foundation
import XCTest
import DProvenanceKit
@testable import DProvenanceOTel

final class OTLPHTTPExporterTests: XCTestCase {

    private func makeExporter(
        _ configuration: OTLPHTTPExporter<StubEvent>.Configuration,
        responses: [StubURLProtocol.StubResponse]
    ) -> OTLPHTTPExporter<StubEvent> {
        StubURLProtocol.reset(responses)
        return OTLPHTTPExporter(configuration: configuration, session: StubURLProtocol.makeSession())
    }

    private func sampleRun(seed: UInt64 = 0) -> TraceRun<StubEvent> {
        let runID = UUID()
        return makeRun([
            makeEvent(run: runID, seq: seed, payload: StubEvent("step")),
        ], run: runID)
    }

    // MARK: - Factories

    func testLangfuseFactory() {
        let configuration = OTLPHTTPExporter<StubEvent>.Configuration.langfuse(
            publicKey: "pk-lf-1", secretKey: "sk-lf-2"
        )
        XCTAssertEqual(configuration.endpoint.absoluteString,
                       "https://cloud.langfuse.com/api/public/otel/v1/traces")
        let expected = "Basic " + Data("pk-lf-1:sk-lf-2".utf8).base64EncodedString()
        XCTAssertEqual(configuration.headers["Authorization"], expected)
    }

    func testCollectorFactory() {
        let configuration = OTLPHTTPExporter<StubEvent>.Configuration.collector(
            endpoint: URL(string: "http://localhost:4318")!,
            headers: ["x-team": "dpk"]
        )
        XCTAssertEqual(configuration.endpoint.absoluteString, "http://localhost:4318")
        XCTAssertEqual(configuration.headers, ["x-team": "dpk"])
        XCTAssertEqual(configuration.retryAttempts, 0)
        XCTAssertEqual(configuration.maxRunsPerRequest, 50)
        XCTAssertEqual(configuration.timeout, 30)
    }

    // MARK: - Endpoint normalization (M10, F15)

    func testTrailingSlashDoesNotDoubleSlash() async throws {
        let configuration = OTLPHTTPExporter<StubEvent>.Configuration(
            endpoint: URL(string: "http://collector.local:4318/")!
        )
        let exporter = makeExporter(configuration, responses: [.init(statusCode: 200)])
        _ = try await exporter.export([sampleRun()])
        XCTAssertEqual(StubURLProtocol.requests.first?.url?.absoluteString,
                       "http://collector.local:4318/v1/traces")
    }

    func testExistingV1TracesSuffixNotAppendedTwice() async throws {
        let configuration = OTLPHTTPExporter<StubEvent>.Configuration(
            endpoint: URL(string: "http://collector.local:4318/custom/v1/traces/")!
        )
        let exporter = makeExporter(configuration, responses: [.init(statusCode: 200)])
        _ = try await exporter.export([sampleRun()])
        XCTAssertEqual(StubURLProtocol.requests.first?.url?.absoluteString,
                       "http://collector.local:4318/custom/v1/traces")
    }

    func testContentTypeIsOwnedByExporter() async throws {
        var configuration = OTLPHTTPExporter<StubEvent>.Configuration(
            endpoint: URL(string: "http://collector.local:4318")!
        )
        configuration.headers["Content-Type"] = "application/x-protobuf"
        configuration.headers["x-custom"] = "yes"
        let exporter = makeExporter(configuration, responses: [.init(statusCode: 200)])
        _ = try await exporter.export([sampleRun()])

        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-custom"), "yes")
    }

    // MARK: - Partial success (M10, F7)

    /// A 200 whose body admits rejected spans is not a full success; the
    /// receipt must say so.
    func testPartialSuccessBodySurfacesInReceipt() async throws {
        let body = #"{"partialSuccess":{"rejectedSpans":"3","errorMessage":"span too old"}}"#
        let configuration = OTLPHTTPExporter<StubEvent>.Configuration(
            endpoint: URL(string: "http://collector.local:4318")!
        )
        let exporter = makeExporter(configuration, responses: [
            .init(statusCode: 200, body: Data(body.utf8)),
        ])
        let receipt = try await exporter.export([sampleRun()])
        XCTAssertEqual(receipt.rejectedSpans, 3)
        XCTAssertEqual(receipt.partialSuccessMessages, ["span too old"])
    }

    /// Lenient decode: some servers emit rejectedSpans as a bare number.
    func testPartialSuccessNumberFormAccepted() async throws {
        let body = #"{"partialSuccess":{"rejectedSpans":2}}"#
        let configuration = OTLPHTTPExporter<StubEvent>.Configuration(
            endpoint: URL(string: "http://collector.local:4318")!
        )
        let exporter = makeExporter(configuration, responses: [
            .init(statusCode: 200, body: Data(body.utf8)),
        ])
        let receipt = try await exporter.export([sampleRun()])
        XCTAssertEqual(receipt.rejectedSpans, 2)
        XCTAssertEqual(receipt.partialSuccessMessages, [])
    }

    /// Proto3 JSON also permits the original proto field names (e.g.
    /// protojson UseProtoNames): a snake_case partial-success body must not
    /// silently read as full success.
    func testPartialSuccessSnakeCaseKeysAccepted() async throws {
        let body = #"{"partial_success":{"rejected_spans":"4","error_message":"span too old"}}"#
        let configuration = OTLPHTTPExporter<StubEvent>.Configuration(
            endpoint: URL(string: "http://collector.local:4318")!
        )
        let exporter = makeExporter(configuration, responses: [
            .init(statusCode: 200, body: Data(body.utf8)),
        ])
        let receipt = try await exporter.export([sampleRun()])
        XCTAssertEqual(receipt.rejectedSpans, 4)
        XCTAssertEqual(receipt.partialSuccessMessages, ["span too old"])
    }

    /// Non-finite doubles encode per the proto3 JSON mapping ("NaN",
    /// "Infinity") instead of failing the whole export as encodingFailed.
    func testNonFiniteDoubleAttributeEncodesInsteadOfThrowing() async throws {
        var options = OTelExportOptions<StubEvent>()
        options.resourceAttributes = [
            .double("dpk.test.nan", Double.nan),
            .double("dpk.test.inf", .infinity),
        ]
        let configuration = OTLPHTTPExporter<StubEvent>.Configuration(
            endpoint: URL(string: "http://collector.local:4318")!
        )
        StubURLProtocol.reset([.init(statusCode: 200)])
        let exporter = OTLPHTTPExporter(
            configuration: configuration, options: options, session: StubURLProtocol.makeSession()
        )
        _ = try await exporter.export([sampleRun()])
        let sent = try XCTUnwrap(StubURLProtocol.bodies.first)
        let json = String(decoding: sent, as: UTF8.self)
        XCTAssertTrue(json.contains(#""NaN""#), "NaN must encode as the proto3 JSON string")
        XCTAssertTrue(json.contains(#""Infinity""#), "Infinity must encode as the proto3 JSON string")
    }

    func testEmptyResponseBodyMeansFullSuccess() async throws {
        let configuration = OTLPHTTPExporter<StubEvent>.Configuration(
            endpoint: URL(string: "http://collector.local:4318")!
        )
        let exporter = makeExporter(configuration, responses: [.init(statusCode: 200)])
        let receipt = try await exporter.export([sampleRun()])
        XCTAssertEqual(receipt.rejectedSpans, 0)
        XCTAssertEqual(receipt.runsExported, 1)
        XCTAssertGreaterThan(receipt.encodedBytes, 0)
    }

    // MARK: - Retry matrix (M10, F8)

    func test503IsRetriedThenSucceeds() async throws {
        var configuration = OTLPHTTPExporter<StubEvent>.Configuration(
            endpoint: URL(string: "http://collector.local:4318")!
        )
        configuration.retryAttempts = 1
        let exporter = makeExporter(configuration, responses: [
            .init(statusCode: 503),
            .init(statusCode: 200),
        ])
        let receipt = try await exporter.export([sampleRun()])
        XCTAssertEqual(receipt.runsExported, 1)
        XCTAssertEqual(StubURLProtocol.requests.count, 2)
    }

    func test429HonorsRetryAfter() async throws {
        var configuration = OTLPHTTPExporter<StubEvent>.Configuration(
            endpoint: URL(string: "http://collector.local:4318")!
        )
        configuration.retryAttempts = 1
        let exporter = makeExporter(configuration, responses: [
            .init(statusCode: 429, headers: ["Retry-After": "0"]),
            .init(statusCode: 200),
        ])
        let start = Date()
        let receipt = try await exporter.export([sampleRun()])
        XCTAssertEqual(receipt.runsExported, 1)
        XCTAssertEqual(StubURLProtocol.requests.count, 2)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.25,
                          "Retry-After: 0 must preempt the exponential backoff")
    }

    func testTransportErrorIsRetried() async throws {
        var configuration = OTLPHTTPExporter<StubEvent>.Configuration(
            endpoint: URL(string: "http://collector.local:4318")!
        )
        configuration.retryAttempts = 1
        let exporter = makeExporter(configuration, responses: [
            .init(statusCode: -1),      // simulated connection loss
            .init(statusCode: 200),
        ])
        let receipt = try await exporter.export([sampleRun()])
        XCTAssertEqual(receipt.runsExported, 1)
        XCTAssertEqual(StubURLProtocol.requests.count, 2)
    }

    /// 500 is NOT in the OTLP retryable set: the server may have partially
    /// ingested the document, and re-POSTing duplicates spans on
    /// non-upserting backends.
    func test500FailsFastDespiteRetryBudget() async throws {
        var configuration = OTLPHTTPExporter<StubEvent>.Configuration(
            endpoint: URL(string: "http://collector.local:4318")!
        )
        configuration.retryAttempts = 3
        let exporter = makeExporter(configuration, responses: [
            .init(statusCode: 500, body: Data("boom".utf8)),
        ])
        do {
            _ = try await exporter.export([sampleRun()])
            XCTFail("expected httpFailure")
        } catch let OTelExportError.httpFailure(statusCode, body, completed) {
            XCTAssertEqual(statusCode, 500)
            XCTAssertEqual(body, "boom")
            XCTAssertNil(completed)
        }
        XCTAssertEqual(StubURLProtocol.requests.count, 1, "no retry on 500")
    }

    func test400FailsFast() async throws {
        var configuration = OTLPHTTPExporter<StubEvent>.Configuration(
            endpoint: URL(string: "http://collector.local:4318")!
        )
        configuration.retryAttempts = 3
        let exporter = makeExporter(configuration, responses: [
            .init(statusCode: 400),
        ])
        do {
            _ = try await exporter.export([sampleRun()])
            XCTFail("expected httpFailure")
        } catch let OTelExportError.httpFailure(statusCode, _, completed) {
            XCTAssertEqual(statusCode, 400)
            XCTAssertNil(completed)
        }
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
    }

    func testRetryExhaustionThrowsLastRetryableFailure() async throws {
        var configuration = OTLPHTTPExporter<StubEvent>.Configuration(
            endpoint: URL(string: "http://collector.local:4318")!
        )
        configuration.retryAttempts = 1
        let exporter = makeExporter(configuration, responses: [
            .init(statusCode: 503),
            .init(statusCode: 503),
        ])
        do {
            _ = try await exporter.export([sampleRun()])
            XCTFail("expected httpFailure")
        } catch let OTelExportError.httpFailure(statusCode, _, completed) {
            XCTAssertEqual(statusCode, 503)
            XCTAssertNil(completed)
        }
        XCTAssertEqual(StubURLProtocol.requests.count, 2)
    }

    // MARK: - Chunking (M10, F9)

    /// A mid-chunk failure must not discard the fact that earlier chunks
    /// landed: the thrown error carries their aggregate receipt.
    func testMidChunkFailureCarriesCompletedReceipt() async throws {
        var configuration = OTLPHTTPExporter<StubEvent>.Configuration(
            endpoint: URL(string: "http://collector.local:4318")!
        )
        configuration.maxRunsPerRequest = 1
        let runA = sampleRun()
        let runB = sampleRun()
        let exporter = makeExporter(configuration, responses: [
            .init(statusCode: 200),
            .init(statusCode: 400),
        ])
        do {
            _ = try await exporter.export([runA, runB])
            XCTFail("expected httpFailure")
        } catch let OTelExportError.httpFailure(statusCode, _, completed) {
            XCTAssertEqual(statusCode, 400)
            let delivered = try XCTUnwrap(completed)
            XCTAssertEqual(delivered.runsExported, 1)
            XCTAssertEqual(Array(delivered.traceIDsByRun.keys), [runA.runID])
        }
        XCTAssertEqual(StubURLProtocol.requests.count, 2)
    }

    func testChunkingSplitsRequestsAndAggregatesReceipt() async throws {
        var configuration = OTLPHTTPExporter<StubEvent>.Configuration(
            endpoint: URL(string: "http://collector.local:4318")!
        )
        configuration.maxRunsPerRequest = 2
        let runs = (0..<5).map { _ in sampleRun() }
        let emptyRun = TraceRun<StubEvent>(runID: UUID(), contextID: "empty", events: [])
        let exporter = makeExporter(configuration, responses: [
            .init(statusCode: 200), .init(statusCode: 200), .init(statusCode: 200),
        ])
        let receipt = try await exporter.export(runs + [emptyRun])
        XCTAssertEqual(StubURLProtocol.requests.count, 3, "5 runs / 2 per request = 3 chunks")
        XCTAssertEqual(receipt.runsExported, 5)
        XCTAssertEqual(receipt.runsSkipped, 1)
        XCTAssertEqual(receipt.spanCount, 5)
        XCTAssertEqual(receipt.traceIDsByRun.count, 5)

        for body in StubURLProtocol.bodies {
            XCTAssertNoThrow(try JSONDecoder().decode(OTLPTraceDocument.self, from: body),
                             "each chunk is an independent, well-formed document")
        }
    }

    func testInvalidEndpointThrows() async {
        let configuration = OTLPHTTPExporter<StubEvent>.Configuration(
            endpoint: URL(string: "notaurl")!
        )
        let exporter = OTLPHTTPExporter<StubEvent>(configuration: configuration,
                                                   session: StubURLProtocol.makeSession())
        do {
            _ = try await exporter.export([sampleRun()])
            XCTFail("expected invalidEndpoint")
        } catch let OTelExportError.invalidEndpoint(endpoint) {
            XCTAssertTrue(endpoint.hasSuffix("/v1/traces"))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}
