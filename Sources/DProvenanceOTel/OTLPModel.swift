import Foundation

/// OTLP/JSON trace document model, spec-exact per the proto3 JSON mapping of
/// `opentelemetry/proto/trace/v1/trace.proto`: camelCase field names, trace and
/// span ids as hex strings (not base64), 64-bit nanosecond timestamps as
/// decimal strings, enums as integers.
///
/// Codable in both directions so tests (and receipt parsing) can round-trip
/// documents through the exact bytes a backend would see.
public struct OTLPTraceDocument: Codable, Sendable, Equatable {
    public var resourceSpans: [OTLPResourceSpans]

    public init(resourceSpans: [OTLPResourceSpans]) {
        self.resourceSpans = resourceSpans
    }
}

public struct OTLPResourceSpans: Codable, Sendable, Equatable {
    public var resource: OTLPResource
    public var scopeSpans: [OTLPScopeSpans]

    public init(resource: OTLPResource, scopeSpans: [OTLPScopeSpans]) {
        self.resource = resource
        self.scopeSpans = scopeSpans
    }
}

public struct OTLPResource: Codable, Sendable, Equatable {
    public var attributes: [OTLPKeyValue]

    public init(attributes: [OTLPKeyValue]) {
        self.attributes = attributes
    }
}

public struct OTLPScopeSpans: Codable, Sendable, Equatable {
    public var scope: OTLPScope
    public var spans: [OTLPSpan]

    public init(scope: OTLPScope, spans: [OTLPSpan]) {
        self.scope = scope
        self.spans = spans
    }
}

public struct OTLPScope: Codable, Sendable, Equatable {
    public var name: String
    public var version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

/// Custom Codable guarantees: hex ids, nanos-as-strings, `parentSpanId`
/// OMITTED (key absent, not "" / null) when nil. Backends distinguish root
/// spans by the absence of the key, so an empty string would orphan the span.
public struct OTLPSpan: Codable, Sendable, Equatable {
    public var traceId: String            // exactly 32 lowercase hex chars
    public var spanId: String             // exactly 16 lowercase hex chars
    public var parentSpanId: String?      // nil on root spans -> key absent
    public var name: String
    public var kind: OTLPSpanKind         // encodes as Int
    public var startTimeUnixNano: String  // uint64 nanos, decimal string
    public var endTimeUnixNano: String
    public var attributes: [OTLPKeyValue]
    public var events: [OTLPSpanEvent]
    public var status: OTLPStatus

    public init(traceId: String, spanId: String, parentSpanId: String?,
                name: String, kind: OTLPSpanKind,
                startTimeUnixNano: String, endTimeUnixNano: String,
                attributes: [OTLPKeyValue], events: [OTLPSpanEvent],
                status: OTLPStatus) {
        self.traceId = traceId
        self.spanId = spanId
        self.parentSpanId = parentSpanId
        self.name = name
        self.kind = kind
        self.startTimeUnixNano = startTimeUnixNano
        self.endTimeUnixNano = endTimeUnixNano
        self.attributes = attributes
        self.events = events
        self.status = status
    }

    private enum CodingKeys: String, CodingKey {
        case traceId, spanId, parentSpanId, name, kind
        case startTimeUnixNano, endTimeUnixNano, attributes, events, status
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        traceId = try container.decode(String.self, forKey: .traceId)
        spanId = try container.decode(String.self, forKey: .spanId)
        parentSpanId = try container.decodeIfPresent(String.self, forKey: .parentSpanId)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(OTLPSpanKind.self, forKey: .kind)
        startTimeUnixNano = try container.decode(String.self, forKey: .startTimeUnixNano)
        endTimeUnixNano = try container.decode(String.self, forKey: .endTimeUnixNano)
        attributes = try container.decode([OTLPKeyValue].self, forKey: .attributes)
        events = try container.decode([OTLPSpanEvent].self, forKey: .events)
        status = try container.decode(OTLPStatus.self, forKey: .status)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(traceId, forKey: .traceId)
        try container.encode(spanId, forKey: .spanId)
        if let parentSpanId {
            try container.encode(parentSpanId, forKey: .parentSpanId)
        }
        try container.encode(name, forKey: .name)
        try container.encode(kind, forKey: .kind)
        try container.encode(startTimeUnixNano, forKey: .startTimeUnixNano)
        try container.encode(endTimeUnixNano, forKey: .endTimeUnixNano)
        try container.encode(attributes, forKey: .attributes)
        try container.encode(events, forKey: .events)
        try container.encode(status, forKey: .status)
    }
}

public enum OTLPSpanKind: Int, Codable, Sendable, Equatable {
    case unspecified = 0
    case `internal`  = 1   // default for DPK spans
    case server      = 2
    case client      = 3   // GenAI-promoted inference spans (semconv)
    case producer    = 4
    case consumer    = 5
}

public struct OTLPSpanEvent: Codable, Sendable, Equatable {
    public var timeUnixNano: String
    public var name: String
    public var attributes: [OTLPKeyValue]

    public init(timeUnixNano: String, name: String, attributes: [OTLPKeyValue]) {
        self.timeUnixNano = timeUnixNano
        self.name = name
        self.attributes = attributes
    }
}

/// Span status per proto3 JSON: `message` is omitted (key absent) when nil.
public struct OTLPStatus: Codable, Sendable, Equatable {
    public var code: Int              // 0 unset, 1 ok, 2 error
    public var message: String?       // omitted when nil

    public static let unset = OTLPStatus(code: 0)
    public static let ok = OTLPStatus(code: 1)
    public static func error(_ message: String) -> OTLPStatus {
        OTLPStatus(code: 2, message: message)
    }

    public init(code: Int, message: String? = nil) {
        self.code = code
        self.message = message
    }

    private enum CodingKeys: String, CodingKey { case code, message }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(Int.self, forKey: .code)
        message = try container.decodeIfPresent(String.self, forKey: .message)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        if let message {
            try container.encode(message, forKey: .message)
        }
    }
}

public struct OTLPKeyValue: Codable, Sendable, Equatable {
    public var key: String
    public var value: OTLPAnyValue

    public init(key: String, value: OTLPAnyValue) {
        self.key = key
        self.value = value
    }

    public static func string(_ key: String, _ v: String) -> OTLPKeyValue {
        OTLPKeyValue(key: key, value: .string(v))
    }
    public static func int(_ key: String, _ v: Int64) -> OTLPKeyValue {
        OTLPKeyValue(key: key, value: .int(v))
    }
    public static func bool(_ key: String, _ v: Bool) -> OTLPKeyValue {
        OTLPKeyValue(key: key, value: .bool(v))
    }
    public static func double(_ key: String, _ v: Double) -> OTLPKeyValue {
        OTLPKeyValue(key: key, value: .double(v))
    }
}

/// Exactly one variant key per proto3 JSON; `intValue` ENCODES as a JSON
/// string (64-bit ints are strings in proto3 JSON), DECODES leniently from
/// string or number so receipts survive servers that emit bare numbers.
/// No array/kvlist in v1 (documented limitation — semconv occasionally wants
/// arrays, e.g. `gen_ai.request.stop_sequences`; `GenAIAttributes.extra`
/// cannot express them).
public enum OTLPAnyValue: Codable, Sendable, Equatable {
    case string(String)
    case int(Int64)
    case bool(Bool)
    case double(Double)

    private enum CodingKeys: String, CodingKey {
        case stringValue, intValue, boolValue, doubleValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let s = try container.decodeIfPresent(String.self, forKey: .stringValue) {
            self = .string(s)
        } else if container.contains(.intValue) {
            if let s = try? container.decode(String.self, forKey: .intValue),
               let v = Int64(s) {
                self = .int(v)
            } else {
                self = .int(try container.decode(Int64.self, forKey: .intValue))
            }
        } else if let b = try container.decodeIfPresent(Bool.self, forKey: .boolValue) {
            self = .bool(b)
        } else if let d = try container.decodeIfPresent(Double.self, forKey: .doubleValue) {
            self = .double(d)
        } else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "OTLPAnyValue requires exactly one of stringValue/intValue/boolValue/doubleValue"
            ))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .string(let s): try container.encode(s, forKey: .stringValue)
        case .int(let i): try container.encode(String(i), forKey: .intValue)
        case .bool(let b): try container.encode(b, forKey: .boolValue)
        case .double(let d): try container.encode(d, forKey: .doubleValue)
        }
    }
}
