import Foundation

/// Failures reported by the hosted read surface.
///
/// Transport failures still surface as `URLError`. These cases describe HTTP or
/// application-wire failures after a response was received.
public enum CloudTraceStoreError: Error, Equatable {
    case notImplemented
    case serverError(Int)
    case unsupportedSchema(expected: String, received: String)
    /// A prior write resolved into in-memory quarantine instead of reaching the
    /// server, so a hosted read could only return a stale/incomplete view.
    case undeliveredQuarantine(count: Int)
    case invalidResponse(endpoint: String, reason: String)
}

/// A read operation advertised by `{baseEndpoint}/capabilities`.
///
/// Unknown values are retained rather than discarded so a newer self-hosted server
/// can advertise additions without making an older SDK reject the whole response.
public enum CloudReadOperation: Sendable, Hashable, Codable {
    case query
    case getRun
    case getEvents
    case lineage
    case impact
    case other(String)

    public var wireValue: String {
        switch self {
        case .query: "query"
        case .getRun: "get_run"
        case .getEvents: "get_events"
        case .lineage: "lineage"
        case .impact: "impact"
        case .other(let value): value
        }
    }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "query": self = .query
        case "get_run": self = .getRun
        case "get_events": self = .getEvents
        case "lineage": self = .lineage
        case "impact": self = .impact
        default: self = .other(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}

/// The typed result of cloud capability negotiation.
public struct CloudTraceStoreCapabilities: Sendable, Equatable {
    public let schemaVersions: [String]
    public let operations: Set<CloudReadOperation>
    /// Maximum total caller limit, or nil when total results are unbounded/paginated.
    public let maxQueryLimit: Int?
    /// Maximum runs returned in one response page.
    public let maxPageSize: Int?

    public init(
        schemaVersions: [String],
        operations: Set<CloudReadOperation>,
        maxQueryLimit: Int?,
        maxPageSize: Int?
    ) {
        self.schemaVersions = schemaVersions
        self.operations = operations
        self.maxQueryLimit = maxQueryLimit
        self.maxPageSize = maxPageSize
    }
}

public final class CloudTraceStore<T: TraceableEvent>: TraceStore, @unchecked Sendable {
    private let endpoint: URL
    private let apiKey: String
    private let buffer: TraceWriteBuffer
    private let writer: CloudWriter
    private let session: URLSession

    /// Events lost before they reach the buffer — payloads that fail to JSON-encode.
    /// Folded into `dropStats` so an unencodable payload can never vanish while the
    /// store still reports `preservedIntegrity == true`.
    private let dropTally = TraceDropTally()

    /// Reused across the concurrent `record` entrypoint: configured once and only read
    /// during `encode`, so concurrent calls are data-race-free while avoiding a fresh
    /// allocation per event. `.sortedKeys` produces the canonical payload bytes required
    /// by Trace Specification v1 §2 (sorted keys).
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    public init(
        endpoint: URL,
        apiKey: String,
        config: OfflineConfig = OfflineConfig(),
        session: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.buffer = TraceWriteBuffer(config: config)
        self.session = session

        let ingestionURL = endpoint.appendingPathComponent("ingest")
        self.writer = CloudWriter(
            endpoint: ingestionURL,
            apiKey: apiKey,
            buffer: buffer,
            session: session
        )

        Task {
            await self.writer.start()
        }
    }

    public func record(_ event: TraceEvent<T>) {
        guard let payloadData = try? encoder.encode(event.payload) else {
            // An unencodable payload can't be transmitted — but it must not vanish
            // silently. Count it in its own tier so the loss shows up in dropStats.
            dropTally.record(priority: event.payload.priority.rawValue)
            return
        }

        let row = TraceEventRow(
            // The recorded TraceEvent.id must survive the wire: a fresh UUID here would
            // break ID-based correlation (replay manifests, lineage joins, quarantine
            // round-trips) between the device and the server.
            id: event.id.uuidString,
            runID: event.runID.uuidString,
            contextID: event.contextID,
            priority: event.payload.priority.rawValue,
            sequence: Int64(event.sequence),
            engine: event.engineName,
            spanID: event.spanID,
            parentSpanID: event.parentSpanID,
            type: event.payload.typeIdentifier,
            payload: payloadData,
            timestamp: Int64(event.timestamp.timeIntervalSince1970 * 1_000_000),
            schemaVersion: event.schemaVersion
        )

        buffer.enqueue(row)
    }

    public func link(source: UUID, target: UUID, type: TraceEdgeType) {
        buffer.enqueueEdge(TraceEdge(sourceID: source, targetID: target, type: type))
    }

    public func flush() async throws {
        try await writer.flush()
    }

    /// Bounded variant of `flush()`: throws `CloudWriterError.flushTimedOut` instead of
    /// blocking indefinitely when the endpoint is unreachable.
    public func flush(timeout: TimeInterval) async throws {
        try await writer.flush(timeout: timeout)
    }

    /// Drains pending writes and stops the background writer.
    ///
    /// A timeout leaves the undelivered batch retained in memory and reports
    /// `CloudWriterError.flushTimedOut`; it never presents an incomplete shutdown as
    /// success. Records or links racing with/arriving after shutdown are rejected and
    /// counted in `dropStats`, never stranded in an undrained buffer.
    public func shutdown(timeout: TimeInterval = 30.0) async throws {
        // Close intake before the writer's final drain. `TraceWriteBuffer` guards
        // close/enqueue with one lock, so every concurrent record or link is either
        // admitted to this drain or rejected and counted in dropStats.
        buffer.close()
        try await writer.shutdown(timeout: timeout)
    }

    /// Buffer congestion drops plus payloads that failed to encode in `record`.
    /// Quarantined batches are NOT counted here — they remain retrievable via
    /// `queryQuarantinedEvents`. That deliberately makes this the wrong signal for
    /// "did everything reach the server?": a quarantined critical event leaves
    /// `preservedIntegrity` true here while the data sits undelivered in RAM. Check
    /// `retentionStats().preservedIntegrity` for the delivery-trust bit.
    public var dropStats: TraceDropStats { buffer.dropStats + dropTally.snapshot }

    /// Drops AND quarantine in one report. `flush()` returning normally means
    /// everything was delivered *or quarantined* — so a successful flush with
    /// `retentionStats().quarantined.total > 0` is the honest signal that recorded
    /// events did not reach the server and will not survive process exit.
    public func retentionStats() async -> CloudRetentionStats {
        CloudRetentionStats(
            dropped: dropStats,
            quarantined: await writer.quarantinedStats()
        )
    }

    // MARK: - Hosted read wire

    private struct QueryPayload: Encodable {
        let schemaVersion: String
        let dsl: TraceQueryDSL<T>
        let limit: Int?
        let cursor: String?

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, dsl, limit, cursor
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(schemaVersion, forKey: .schemaVersion)
            try container.encode(dsl, forKey: .dsl)
            // `null` is the documented unbounded form. Deliberately encode the key
            // rather than omitting it so server implementations see one stable shape.
            if let limit {
                try container.encode(limit, forKey: .limit)
            } else {
                try container.encodeNil(forKey: .limit)
            }
            try container.encodeIfPresent(cursor, forKey: .cursor)
        }
    }

    private struct EventIDsPayload: Encodable {
        let ids: [String]
    }

    private struct ErrorResponse: Decodable {
        let error: String
        let expected: String?
        let received: String?
    }

    private struct CapabilitiesResponse: Decodable {
        let schemaVersions: [String]
        let operations: [CloudReadOperation]
        let maxQueryLimit: Int?
        let maxPageSize: Int?
    }

    private struct QueryResponse: Decodable {
        let schemaVersion: String
        let runs: [WireRun]
        let nextCursor: String?
    }

    private struct RunResponse: Decodable {
        let schemaVersion: String
        let run: WireRun?

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, run
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
            guard container.contains(.run) else {
                throw DecodingError.keyNotFound(
                    CodingKeys.run,
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "The run envelope must contain a run key."
                    )
                )
            }
            run = try container.decodeIfPresent(WireRun.self, forKey: .run)
        }
    }

    private struct EdgesResponse: Decodable {
        let schemaVersion: String
        let edges: [WireEdge]
    }

    private struct EventsResponse: Decodable {
        let schemaVersion: String
        let events: [WireEvent]
    }

    private struct WireRun: Decodable {
        let runID: String
        let contextID: String
        let events: [WireEvent]

        private enum CodingKeys: String, CodingKey {
            case runID = "run_id"
            case contextID = "context_id"
            case events
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            runID = try container.decode(String.self, forKey: .runID)
            contextID = try container.decode(String.self, forKey: .contextID)
            events = try container.decode([WireEvent].self, forKey: .events)
        }
    }

    private struct WireEvent: Decodable {
        let id: String
        let runID: String
        let contextID: String
        let priority: Int
        let sequence: Int64
        let engine: String
        let spanID: String?
        let parentSpanID: String?
        let type: String
        let payload: JSONValue
        let timestamp: Int64
        let schemaVersion: Int

        private enum CodingKeys: String, CodingKey {
            case id
            case runID = "run_id"
            case contextID = "context_id"
            case priority, sequence, engine
            case spanID = "span_id"
            case parentSpanID = "parent_span_id"
            case type, payload, timestamp
            case schemaVersion = "schema_version"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            runID = try container.decode(String.self, forKey: .runID)
            contextID = try container.decode(String.self, forKey: .contextID)
            priority = try container.decode(Int.self, forKey: .priority)
            sequence = try container.decode(Int64.self, forKey: .sequence)
            engine = try container.decode(String.self, forKey: .engine)
            spanID = try container.decodeIfPresent(String.self, forKey: .spanID)
            parentSpanID = try container.decodeIfPresent(String.self, forKey: .parentSpanID)
            type = try container.decode(String.self, forKey: .type)
            payload = try container.decode(JSONValue.self, forKey: .payload)
            timestamp = try container.decode(Int64.self, forKey: .timestamp)
            // Pre-schema-version cloud rows are v1, matching the local-store migration.
            schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        }
    }

    /// Lossless-enough Codable JSON tree used to defer generic `T` decoding until
    /// after identity and envelope fields have been validated. Keeping the raw value
    /// separate lets payload schema drift increment `undecodedEventCount`, matching
    /// SQLiteTraceStore, instead of making the entire server response disappear.
    private indirect enum JSONValue: Codable {
        case null
        case bool(Bool)
        case string(String)
        case int(Int64)
        case uint(UInt64)
        case double(Double)
        case array([JSONValue])
        case object([String: JSONValue])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let value = try? container.decode(Bool.self) {
                self = .bool(value)
            } else if let value = try? container.decode(Int64.self) {
                self = .int(value)
            } else if let value = try? container.decode(UInt64.self) {
                self = .uint(value)
            } else if let value = try? container.decode(Double.self) {
                guard value.isFinite else {
                    throw DecodingError.dataCorruptedError(
                        in: container,
                        debugDescription: "JSON numbers must be finite."
                    )
                }
                self = .double(value)
            } else if let value = try? container.decode(String.self) {
                self = .string(value)
            } else if let value = try? container.decode([JSONValue].self) {
                self = .array(value)
            } else {
                self = .object(try container.decode([String: JSONValue].self))
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .null:
                try container.encodeNil()
            case .bool(let value):
                try container.encode(value)
            case .string(let value):
                try container.encode(value)
            case .int(let value):
                try container.encode(value)
            case .uint(let value):
                try container.encode(value)
            case .double(let value):
                try container.encode(value)
            case .array(let value):
                try container.encode(value)
            case .object(let value):
                try container.encode(value)
            }
        }
    }

    private struct WireEdge: Decodable {
        let sourceID: String
        let targetID: String
        let type: TraceEdgeType

        private enum CodingKeys: String, CodingKey {
            case sourceID = "source_id"
            case targetID = "target_id"
            case type = "edge_type"
        }
    }

    /// Fetches and validates the capabilities advertised by the configured endpoint.
    @discardableResult
    public func negotiateCapabilities() async throws -> CloudTraceStoreCapabilities {
        let path = "capabilities"
        let data = try await request(pathComponents: [path], method: "GET")
        let response: CapabilitiesResponse = try decodeResponse(
            CapabilitiesResponse.self,
            from: data,
            endpointName: path
        )

        guard !response.schemaVersions.isEmpty,
              response.schemaVersions.allSatisfy({ !$0.isEmpty }),
              Set(response.schemaVersions).count == response.schemaVersions.count else {
            throw invalid(path, "schemaVersions must be non-empty, unique strings")
        }
        guard Set(response.operations.map(\.wireValue)).count == response.operations.count,
              response.operations.allSatisfy({ !$0.wireValue.isEmpty }) else {
            throw invalid(path, "operations must contain unique, non-empty values")
        }
        if let maxQueryLimit = response.maxQueryLimit, maxQueryLimit < 0 {
            throw invalid(path, "maxQueryLimit cannot be negative")
        }
        if let maxPageSize = response.maxPageSize, maxPageSize <= 0 {
            throw invalid(path, "maxPageSize must be positive")
        }

        return CloudTraceStoreCapabilities(
            schemaVersions: response.schemaVersions,
            operations: Set(response.operations),
            maxQueryLimit: response.maxQueryLimit,
            maxPageSize: response.maxPageSize
        )
    }

    public func queryRuns(_ dsl: TraceQueryDSL<T>) async throws -> [TraceRun<T>] {
        try await queryRuns(dsl, limit: nil)
    }

    /// Pushes the caller's bound to the server. `nil` and negative values preserve the
    /// `TraceStore` unbounded-query contract and are encoded as JSON `null`.
    public func queryRuns(
        _ dsl: TraceQueryDSL<T>,
        limit: Int?
    ) async throws -> [TraceRun<T>] {
        let path = "query"
        let normalizedLimit = limit.flatMap { $0 >= 0 ? $0 : nil }
        // Match the local stores: asking for no runs has no read-your-writes side
        // effect and cannot fail because the network is unavailable.
        if normalizedLimit == 0 { return [] }
        // Read-your-writes: a run recorded immediately before this call must reach the
        // remote store before the query executes. Quarantine is NOT delivery, so the
        // barrier checks it explicitly after flush.
        try await remoteReadBarrier()

        var seenRunIDs = Set<UUID>()
        var seenCursors = Set<String>()
        var runs: [TraceRun<T>] = []
        var cursor: String?

        repeat {
            let remainingLimit = normalizedLimit.map { max(0, $0 - runs.count) }
            let payload = QueryPayload(
                schemaVersion: TraceQueryDSL<T>.schemaVersion,
                dsl: dsl,
                limit: remainingLimit,
                cursor: cursor
            )
            let body = try JSONEncoder().encode(payload)
            let data = try await request(pathComponents: [path], method: "POST", body: body)
            let response: QueryResponse = try decodeResponse(
                QueryResponse.self,
                from: data,
                endpointName: path
            )
            try validateSchemaVersion(response.schemaVersion, endpointName: path)

            if let remainingLimit, response.runs.count > remainingLimit {
                throw invalid(path, "server returned more runs than the requested limit")
            }

            for wireRun in response.runs {
                let run = try hydrateRun(wireRun, endpointName: path)
                guard seenRunIDs.insert(run.runID).inserted else {
                    throw invalid(path, "response contains a duplicate run_id")
                }
                // Cloud query parity is part of Trace Specification v1. Verify a
                // complete typed run locally. A run with payload drift must remain
                // visible with its non-zero count: evaluating a partial view could
                // incorrectly "prove" a missing/negated payload condition.
                guard run.undecodedEventCount > 0 || dsl.ast.evaluate(run: run) else {
                    throw invalid(path, "server returned a run that does not match the query")
                }
                runs.append(run)
            }

            if response.runs.isEmpty, response.nextCursor != nil {
                throw invalid(
                    path,
                    "an empty page may not supply nextCursor"
                )
            }

            if let normalizedLimit, runs.count == normalizedLimit {
                cursor = nil
            } else if let nextCursor = response.nextCursor {
                guard !nextCursor.isEmpty,
                      seenCursors.insert(nextCursor).inserted else {
                    throw invalid(path, "nextCursor must be non-empty and may not repeat")
                }
                cursor = nextCursor
            } else {
                cursor = nil
            }
        } while cursor != nil

        return runs
    }

    public func getRun(id: UUID) async throws -> TraceRun<T>? {
        try await remoteReadBarrier()
        let path = "runs"
        let endpointName = "runs/{id}"
        let data = try await request(
            pathComponents: [path, id.uuidString],
            method: "GET"
        )
        let response: RunResponse = try decodeResponse(
            RunResponse.self,
            from: data,
            endpointName: endpointName
        )
        try validateSchemaVersion(response.schemaVersion, endpointName: endpointName)
        guard let wireRun = response.run else { return nil }
        let run = try hydrateRun(wireRun, endpointName: endpointName)
        guard run.runID == id else {
            throw invalid(endpointName, "run_id does not match the requested id")
        }
        return run
    }

    public func queryQuarantinedEvents(
        _ dsl: TraceQueryDSL<T>
    ) async throws -> [TraceEvent<T>] {
        let rows = await writer.getQuarantinedEvents()

        var undecodedCount = 0
        let allEvents = rows.compactMap { row -> TraceEvent<T>? in
            guard let runID = UUID(uuidString: row.runID),
                  let payload = try? JSONDecoder().decode(T.self, from: row.payload),
                  let eventID = UUID(uuidString: row.id) else {
                // A quarantined row that no longer decodes as T must not vanish from
                // the ONE path that can retrieve it — the row stays in quarantine
                // (and in retentionStats); the log carries the omission.
                undecodedCount += 1
                return nil
            }

            return TraceEvent(
                id: eventID,
                runID: runID,
                contextID: row.contextID,
                engineName: row.engine ?? "Unknown",
                schemaVersion: row.schemaVersion,
                sequence: UInt64(row.sequence),
                spanID: row.spanID,
                parentSpanID: row.parentSpanID,
                payload: payload,
                timestamp: Date(
                    timeIntervalSince1970: TimeInterval(row.timestamp) / 1_000_000.0
                )
            )
        }

        if undecodedCount > 0 {
            DPKLog.cloud.error(
                "queryQuarantinedEvents: \(undecodedCount) of \(rows.count) quarantined rows failed to decode as \(String(describing: T.self), privacy: .public) and are omitted from the result; the rows remain quarantined"
            )
        }

        var runs: [UUID: [TraceEvent<T>]] = [:]
        for event in allEvents {
            runs[event.runID, default: []].append(event)
        }

        var matchedEvents: [TraceEvent<T>] = []
        for (runID, events) in runs {
            let sorted = events.sorted { $0.sequence < $1.sequence }
            let run = TraceRun(
                runID: runID,
                contextID: sorted[0].contextID,
                events: sorted
            )
            if dsl.ast.evaluate(run: run) {
                matchedEvents.append(contentsOf: events)
            }
        }

        return matchedEvents
    }

    public func lineageEdges(of id: UUID) async throws -> [TraceEdge] {
        try await fetchEdges(
            path: "lineage",
            rootID: id,
            direction: .lineage
        )
    }

    public func impactEdges(of id: UUID) async throws -> [TraceEdge] {
        try await fetchEdges(
            path: "impact",
            rootID: id,
            direction: .impact
        )
    }

    public func getEvents(ids: Set<UUID>) async throws -> [UUID: TraceEvent<T>] {
        guard !ids.isEmpty else { return [:] }
        try await remoteReadBarrier()

        let path = "events"
        let payload = EventIDsPayload(ids: ids.map(\.uuidString).sorted())
        let body = try JSONEncoder().encode(payload)
        let data = try await request(pathComponents: [path], method: "POST", body: body)
        let response: EventsResponse = try decodeResponse(
            EventsResponse.self,
            from: data,
            endpointName: path
        )
        try validateSchemaVersion(response.schemaVersion, endpointName: path)

        var events: [UUID: TraceEvent<T>] = [:]
        var seenEventIDs = Set<UUID>()
        var undecodedCount = 0
        for wireEvent in response.events {
            let result = try hydrateEvent(wireEvent, endpointName: path)
            guard ids.contains(result.id) else {
                throw invalid(path, "server returned an event id that was not requested")
            }
            guard seenEventIDs.insert(result.id).inserted else {
                throw invalid(path, "response contains a duplicate event id")
            }
            if let event = result.event {
                events[event.id] = event
            } else {
                undecodedCount += 1
            }
        }
        if undecodedCount > 0 {
            DPKLog.cloud.error(
                "getEvents: \(undecodedCount) of \(response.events.count) cloud events failed to decode as \(String(describing: T.self), privacy: .public) and are omitted from the result"
            )
        }
        return events
    }

    // MARK: - Request and validation helpers

    private enum TraversalDirection {
        case lineage
        case impact
    }

    private func fetchEdges(
        path: String,
        rootID: UUID,
        direction: TraversalDirection
    ) async throws -> [TraceEdge] {
        // Includes pending edge-only batches, not just events.
        try await remoteReadBarrier()
        let endpointName = "\(path)/{id}"
        let data = try await request(
            pathComponents: [path, rootID.uuidString],
            method: "GET"
        )
        let response: EdgesResponse = try decodeResponse(
            EdgesResponse.self,
            from: data,
            endpointName: endpointName
        )
        try validateSchemaVersion(response.schemaVersion, endpointName: endpointName)

        var seen = Set<TraceEdge>()
        var edges: [TraceEdge] = []
        edges.reserveCapacity(response.edges.count)
        for wireEdge in response.edges {
            guard let sourceID = UUID(uuidString: wireEdge.sourceID),
                  let targetID = UUID(uuidString: wireEdge.targetID) else {
                throw invalid(endpointName, "edge contains an invalid UUID")
            }
            guard sourceID != targetID else {
                throw invalid(endpointName, "edge contains a self-reference")
            }
            let edge = TraceEdge(sourceID: sourceID, targetID: targetID, type: wireEdge.type)
            guard seen.insert(edge).inserted else {
                throw invalid(endpointName, "response contains a duplicate edge")
            }
            edges.append(edge)
        }

        // The endpoint promises a transitive closure rooted at the requested event.
        // Reject unrelated edges rather than letting them contaminate an explanation.
        var reachable: Set<UUID> = [rootID]
        var remaining = edges
        var madeProgress = true
        while madeProgress && !remaining.isEmpty {
            madeProgress = false
            remaining.removeAll { edge in
                let isConnected: Bool
                switch direction {
                case .lineage:
                    isConnected = reachable.contains(edge.targetID)
                    if isConnected { reachable.insert(edge.sourceID) }
                case .impact:
                    isConnected = reachable.contains(edge.sourceID)
                    if isConnected { reachable.insert(edge.targetID) }
                }
                if isConnected { madeProgress = true }
                return isConnected
            }
        }
        guard remaining.isEmpty else {
            throw invalid(endpointName, "response contains an edge disconnected from the requested id")
        }

        return edges
    }

    private func hydrateRun(
        _ wireRun: WireRun,
        endpointName: String
    ) throws -> TraceRun<T> {
        guard let runID = UUID(uuidString: wireRun.runID) else {
            throw invalid(endpointName, "run_id is not a UUID")
        }
        var seenIDs = Set<UUID>()
        var seenSequences = Set<UInt64>()
        var events: [TraceEvent<T>] = []
        var clientUndecodedCount = 0
        events.reserveCapacity(wireRun.events.count)
        for wireEvent in wireRun.events {
            let result = try hydrateEvent(wireEvent, endpointName: endpointName)
            guard result.runID == runID else {
                throw invalid(endpointName, "event run_id does not match its run envelope")
            }
            guard result.contextID == wireRun.contextID else {
                throw invalid(endpointName, "event context_id does not match its run envelope")
            }
            guard seenIDs.insert(result.id).inserted else {
                throw invalid(endpointName, "run contains a duplicate event id")
            }
            guard seenSequences.insert(result.sequence).inserted else {
                throw invalid(endpointName, "run contains a duplicate event sequence")
            }
            if let event = result.event {
                events.append(event)
            } else {
                clientUndecodedCount += 1
            }
        }
        events.sort { $0.sequence < $1.sequence }

        guard !events.isEmpty || clientUndecodedCount > 0 else {
            throw invalid(endpointName, "run contains no events")
        }
        if clientUndecodedCount > 0 {
            DPKLog.cloud.error(
                "hydrateRun(\(runID.uuidString, privacy: .public)): \(clientUndecodedCount) of \(wireRun.events.count) cloud payloads failed to decode as \(String(describing: T.self), privacy: .public); TraceRun.undecodedEventCount exposes the incomplete typed view"
            )
        }
        return TraceRun(
            runID: runID,
            contextID: wireRun.contextID,
            events: events,
            undecodedEventCount: clientUndecodedCount
        )
    }

    private struct HydratedEvent {
        let id: UUID
        let runID: UUID
        let contextID: String
        let sequence: UInt64
        let event: TraceEvent<T>?
    }

    private func hydrateEvent(
        _ wireEvent: WireEvent,
        endpointName: String
    ) throws -> HydratedEvent {
        guard let id = UUID(uuidString: wireEvent.id),
              let runID = UUID(uuidString: wireEvent.runID) else {
            throw invalid(endpointName, "event id or run_id is not a UUID")
        }
        guard wireEvent.sequence >= 0 else {
            throw invalid(endpointName, "event sequence cannot be negative")
        }
        guard TracePriority(rawValue: wireEvent.priority) != nil else {
            throw invalid(endpointName, "event priority is outside the supported range")
        }
        guard !wireEvent.type.isEmpty else {
            throw invalid(endpointName, "event type cannot be empty")
        }
        guard !wireEvent.engine.isEmpty else {
            throw invalid(endpointName, "event engine cannot be empty")
        }

        let payloadData = try JSONEncoder().encode(wireEvent.payload)
        guard let payload = try? JSONDecoder().decode(T.self, from: payloadData) else {
            return HydratedEvent(
                id: id,
                runID: runID,
                contextID: wireEvent.contextID,
                sequence: UInt64(wireEvent.sequence),
                event: nil
            )
        }

        guard wireEvent.priority == payload.priority.rawValue else {
            throw invalid(endpointName, "event priority disagrees with its decoded payload")
        }
        guard wireEvent.type == payload.typeIdentifier else {
            throw invalid(endpointName, "event type disagrees with its decoded payload")
        }

        return HydratedEvent(
            id: id,
            runID: runID,
            contextID: wireEvent.contextID,
            sequence: UInt64(wireEvent.sequence),
            event: TraceEvent(
                id: id,
                runID: runID,
                contextID: wireEvent.contextID,
                engineName: wireEvent.engine,
                schemaVersion: wireEvent.schemaVersion,
                sequence: UInt64(wireEvent.sequence),
                spanID: wireEvent.spanID,
                parentSpanID: wireEvent.parentSpanID,
                payload: payload,
                timestamp: Date(
                    timeIntervalSince1970: TimeInterval(wireEvent.timestamp) / 1_000_000.0
                )
            )
        )
    }

    private func request(
        pathComponents: [String],
        method: String,
        body: Data? = nil
    ) async throws -> Data {
        var url = endpoint
        for component in pathComponents {
            url.appendPathComponent(component)
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        let status = httpResponse.statusCode
        if status == 400 || status == 422,
           let errorResponse = try? JSONDecoder().decode(ErrorResponse.self, from: data),
           errorResponse.error == "UNSUPPORTED_SCHEMA" {
            guard let expected = errorResponse.expected,
                  !expected.isEmpty,
                  let received = errorResponse.received,
                  !received.isEmpty else {
                throw invalid(
                    pathComponents.first ?? "unknown",
                    "UNSUPPORTED_SCHEMA response is missing expected or received"
                )
            }
            throw CloudTraceStoreError.unsupportedSchema(
                expected: expected,
                received: received
            )
        }
        if status == 501 {
            throw CloudTraceStoreError.notImplemented
        }
        guard (200...299).contains(status) else {
            throw CloudTraceStoreError.serverError(status)
        }
        return data
    }

    private func decodeResponse<Response: Decodable>(
        _ type: Response.Type,
        from data: Data,
        endpointName: String
    ) throws -> Response {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw invalid(
                endpointName,
                "body does not match the documented JSON envelope: \(error)"
            )
        }
    }

    private func validateSchemaVersion(
        _ schemaVersion: String,
        endpointName: String
    ) throws {
        guard schemaVersion == TraceQueryDSL<T>.schemaVersion else {
            throw invalid(
                endpointName,
                "response schemaVersion \(schemaVersion) does not match \(TraceQueryDSL<T>.schemaVersion)"
            )
        }
    }

    /// A remote trace read is honest only when every prior buffered write reached the
    /// endpoint. `CloudWriter.flush` also resolves poison/exhausted batches by moving
    /// them to quarantine, so a normal flush return alone is not a delivery barrier.
    private func remoteReadBarrier() async throws {
        try await flush()
        let quarantined = await writer.quarantinedStats().total
        guard quarantined == 0 else {
            let boundedCount = quarantined > UInt64(Int.max)
                ? Int.max
                : Int(quarantined)
            throw CloudTraceStoreError.undeliveredQuarantine(count: boundedCount)
        }
    }

    private func invalid(
        _ endpointName: String,
        _ reason: String
    ) -> CloudTraceStoreError {
        .invalidResponse(endpoint: endpointName, reason: reason)
    }
}
