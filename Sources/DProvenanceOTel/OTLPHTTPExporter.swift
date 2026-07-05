import Foundation
import DProvenanceKit

/// OTLP/HTTP exporter, JSON encoding only — see the backend support matrix in
/// the module doc. Direct export is verified for Langfuse and the stock
/// otel-collector; protobuf-only backends (Arize Phoenix) need a collector
/// relay.
public struct OTLPHTTPExporter<T: TraceableEvent>: OTelTraceExporter, Sendable {

    public struct Configuration: Sendable {
        /// Trailing "/" trimmed; "/v1/traces" appended iff not already the
        /// suffix (a trailing slash would otherwise yield "//v1/traces").
        public var endpoint: URL

        /// Sent verbatim; Content-Type is owned by the exporter and always
        /// `application/json`.
        public var headers: [String: String]

        public var timeout: TimeInterval

        /// Each chunk is an independent document POSTed separately.
        public var maxRunsPerRequest: Int

        /// Extra attempts on 429/502/503/504/transport ONLY (the OTLP
        /// retryable set — never other 5xx or any 4xx: retrying a 500 re-POSTs
        /// documents that may have been partially ingested, which duplicates
        /// spans on non-upserting backends). Exponential backoff + jitter,
        /// honors Retry-After. Default 0.
        public var retryAttempts: Int

        public init(endpoint: URL) {
            self.endpoint = endpoint
            self.headers = [:]
            self.timeout = 30
            self.maxRunsPerRequest = 50
            self.retryAttempts = 0
        }

        /// Langfuse accepts OTLP HTTP/JSON directly (>= cloud / self-host v3.22.0).
        /// Default host cloud.langfuse.com == EU region.
        ///   US: https://us.cloud.langfuse.com   JP: https://jp.cloud.langfuse.com
        ///   HIPAA: https://hipaa.cloud.langfuse.com   Self-hosted: your base URL
        /// -> <host>/api/public/otel/v1/traces
        ///    Authorization: Basic base64("<publicKey>:<secretKey>")
        public static func langfuse(host: URL = URL(string: "https://cloud.langfuse.com")!,
                                    publicKey: String,
                                    secretKey: String) -> Configuration {
            var configuration = Configuration(
                endpoint: host.appendingPathComponent("api/public/otel/v1/traces")
            )
            let credentials = Data("\(publicKey):\(secretKey)".utf8).base64EncodedString()
            configuration.headers["Authorization"] = "Basic " + credentials
            return configuration
        }

        /// Generic OTLP/HTTP collector (otel-collector, Tempo w/ JSON, ...).
        /// NOTE: Arize Phoenix does NOT accept OTLP/JSON (its /v1/traces
        /// returns HTTP 415 for anything but application/x-protobuf). Reach
        /// Phoenix via an otel-collector relay; recipe in the module doc.
        public static func collector(endpoint: URL,
                                     headers: [String: String] = [:]) -> Configuration {
            var configuration = Configuration(endpoint: endpoint)
            configuration.headers = headers
            return configuration
        }
    }

    private let configuration: Configuration
    private let mapper: OTelSpanMapper<T>
    private let session: URLSession

    public init(configuration: Configuration,
                options: OTelExportOptions<T> = .init(),
                session: URLSession = .shared) {
        self.configuration = configuration
        self.mapper = OTelSpanMapper(options: options)
        self.session = session
    }

    public func export(_ runs: [TraceRun<T>]) async throws -> OTelExportReceipt {
        let url = try normalizedEndpoint()

        let nonEmptyRuns = runs.filter { !$0.events.isEmpty }
        let runsSkipped = runs.count - nonEmptyRuns.count
        let chunkSize = max(1, configuration.maxRunsPerRequest)

        var aggregate = Aggregate(runsSkipped: runsSkipped)

        var index = 0
        while index < nonEmptyRuns.count {
            let chunk = Array(nonEmptyRuns[index..<min(index + chunkSize, nonEmptyRuns.count)])
            index += chunkSize

            let mapped = mapper.mapped(for: chunk)
            let data: Data
            do {
                data = try OTLPJSON.encode(mapped.document, deterministic: true)
            } catch {
                throw OTelExportError.encodingFailed(description: String(describing: error))
            }

            // A mid-chunk failure carries the aggregate receipt of chunks
            // already delivered, so the caller can avoid re-sending them.
            let completed = aggregate.deliveredAnything ? aggregate.receipt() : nil
            let outcome: (rejectedSpans: Int64, messages: [String])
            do {
                outcome = try await send(data, to: url)
            } catch let failure as SendFailure {
                switch failure {
                case .transport(let description):
                    throw OTelExportError.transport(description: description, completed: completed)
                case .http(let statusCode, let body):
                    throw OTelExportError.httpFailure(statusCode: statusCode, body: body, completed: completed)
                }
            }

            aggregate.add(mapped: mapped, encodedBytes: data.count,
                          rejectedSpans: outcome.rejectedSpans, messages: outcome.messages)
        }

        return aggregate.receipt()
    }

    // MARK: - Endpoint normalization (M10)

    private func normalizedEndpoint() throws -> URL {
        var absolute = configuration.endpoint.absoluteString
        while absolute.hasSuffix("/") { absolute.removeLast() }
        if !absolute.hasSuffix("/v1/traces") { absolute += "/v1/traces" }
        guard let url = URL(string: absolute), url.scheme != nil, url.host != nil else {
            throw OTelExportError.invalidEndpoint(absolute)
        }
        return url
    }

    // MARK: - Transport

    private enum SendFailure: Error {
        case transport(String)
        case http(statusCode: Int, body: String?)
    }

    /// POSTs one chunk. Retries ONLY the OTLP retryable set (429/502/503/504)
    /// and URLSession transport errors; everything else fails fast. 2xx
    /// response bodies are parsed for `partialSuccess` — a 200 whose body
    /// admits rejected spans is not a full success and must reach the receipt.
    private func send(_ body: Data, to url: URL) async throws -> (rejectedSpans: Int64, messages: [String]) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = configuration.timeout
        for (field, value) in configuration.headers.sorted(by: { $0.key < $1.key }) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let attempts = max(0, configuration.retryAttempts) + 1
        var lastFailure = SendFailure.transport("no attempt made")
        var retryAfter: TimeInterval? = nil

        for attempt in 0..<attempts {
            if attempt > 0 {
                let backoff = min(30, 0.25 * pow(2, Double(attempt - 1)))
                let jitter = Double.random(in: 0...(backoff * 0.25))
                let delay = retryAfter ?? (backoff + jitter)
                if delay > 0 {
                    // Not `try?`: a cancelled export must propagate cooperative
                    // cancellation, not burn the remaining attempts in a hot loop.
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
            retryAfter = nil

            let responseBody: Data
            let response: URLResponse
            do {
                (responseBody, response) = try await session.data(for: request)
            } catch {
                // Cancellation is not a transport failure: rethrow so the caller
                // can distinguish teardown from a network outage, and so no
                // further already-cancelled attempts fire.
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    throw error
                }
                lastFailure = .transport(String(describing: error))
                continue
            }

            guard let http = response as? HTTPURLResponse else {
                lastFailure = .transport("non-HTTP response for \(url.absoluteString)")
                continue
            }

            switch http.statusCode {
            case 200..<300:
                return parsePartialSuccess(from: responseBody)
            case 429, 502, 503, 504:
                lastFailure = .http(statusCode: http.statusCode,
                                    body: String(data: responseBody, encoding: .utf8))
                retryAfter = http.value(forHTTPHeaderField: "Retry-After")
                    .flatMap(TimeInterval.init)
                continue
            default:
                throw SendFailure.http(statusCode: http.statusCode,
                                       body: String(data: responseBody, encoding: .utf8))
            }
        }

        throw lastFailure
    }

    /// OTLP/HTTP signals rejected spans via a 200 whose body carries
    /// `partialSuccess { rejectedSpans, errorMessage }`. `rejectedSpans` is an
    /// int64, so proto3 JSON emits it as a string — but decode leniently from
    /// string or number, same as `OTLPAnyValue.intValue`.
    /// Proto3 JSON emitters may use either lowerCamelCase (the canonical form,
    /// what the stock collector sends) or the original proto field names
    /// (e.g. protojson's UseProtoNames), so both spellings are accepted —
    /// otherwise a rejected-spans body from a snake_case server would read as
    /// full success, the exact dishonesty the receipt exists to prevent.
    private func parsePartialSuccess(from body: Data) -> (rejectedSpans: Int64, messages: [String]) {
        guard !body.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let partial = (object["partialSuccess"] ?? object["partial_success"]) as? [String: Any] else {
            return (0, [])
        }
        let rejectedField = partial["rejectedSpans"] ?? partial["rejected_spans"]
        var rejectedSpans: Int64 = 0
        if let string = rejectedField as? String, let value = Int64(string) {
            rejectedSpans = value
        } else if let number = rejectedField as? NSNumber {
            rejectedSpans = number.int64Value
        }
        var messages: [String] = []
        if let message = (partial["errorMessage"] ?? partial["error_message"]) as? String, !message.isEmpty {
            messages.append(message)
        }
        return (rejectedSpans, messages)
    }

    // MARK: - Receipt aggregation across chunks

    private struct Aggregate {
        let runsSkipped: Int
        var runsExported = 0
        var spanCount = 0
        var spanEventCount = 0
        var encodedBytes = 0
        var traceIDsByRun: [UUID: String] = [:]
        var rejectedSpans: Int64 = 0
        var partialSuccessMessages: [String] = []
        var deliveredAnything = false

        init(runsSkipped: Int) {
            self.runsSkipped = runsSkipped
        }

        mutating func add(mapped: OTelSpanMapper<T>.MappedRuns, encodedBytes: Int,
                          rejectedSpans: Int64, messages: [String]) {
            deliveredAnything = true
            runsExported += mapped.runsExported
            spanCount += mapped.spanCount
            spanEventCount += mapped.spanEventCount
            self.encodedBytes += encodedBytes
            traceIDsByRun.merge(mapped.traceIDsByRun) { current, _ in current }
            self.rejectedSpans += rejectedSpans
            partialSuccessMessages.append(contentsOf: messages)
        }

        func receipt() -> OTelExportReceipt {
            OTelExportReceipt(
                runsExported: runsExported,
                runsSkipped: runsSkipped,
                spanCount: spanCount,
                spanEventCount: spanEventCount,
                encodedBytes: encodedBytes,
                traceIDsByRun: traceIDsByRun,
                rejectedSpans: rejectedSpans,
                partialSuccessMessages: partialSuccessMessages
            )
        }
    }
}
