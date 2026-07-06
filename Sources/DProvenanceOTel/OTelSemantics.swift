import Foundation
import DProvenanceKit

/// dpk.* attribute keys — the single source of truth. Tests and downstream
/// dashboards key on these strings; never inline the literals elsewhere.
public enum DPKOTelAttribute {
    public static let runID            = "dpk.run_id"
    public static let contextID        = "dpk.context_id"
    public static let engine           = "dpk.engine"
    public static let typeIdentifier   = "dpk.type_identifier"
    public static let sequence         = "dpk.sequence"
    public static let schemaVersion    = "dpk.schema_version"
    public static let priority         = "dpk.priority"
    public static let payload          = "dpk.payload"
    public static let payloadTruncated = "dpk.payload_truncated"
    public static let payloadError     = "dpk.payload_error"     // "encoding_failed"
    public static let spanID           = "dpk.span_id"           // original DPK span id
    public static let parentSpanID     = "dpk.parent_span_id"    // original DPK parent id
    public static let eventID          = "dpk.event_id"          // this event's TraceEvent.id — the lineage join key
    public static let derivedFrom      = "dpk.derived_from"      // comma-joined source event ids (direct parents)
    public static let derivedFromType  = "dpk.derived_from.type" // comma-joined TraceEdgeType, index-aligned to derived_from
    public static let synthesized      = "dpk.synthesized"       // parent had no events
    public static let parentConflict   = "dpk.parent_conflict"   // self-parent/disagreement/cycle
    public static let eventCount       = "dpk.event_count"
    public static let dropTelemetry    = "dpk.drop_stats.telemetry"
    public static let dropDiagnostic   = "dpk.drop_stats.diagnostic"
    public static let dropStructural   = "dpk.drop_stats.structural"
    public static let dropCritical     = "dpk.drop_stats.critical"
    public static let dropTotal        = "dpk.drop_stats.total"
    public static let preservedIntegrity = "dpk.drop_stats.preserved_integrity"
}

/// gen_ai.* semconv keys emitted by GenAI promotion (mapping rule M6).
enum GenAISemconvAttribute {
    static let operationName     = "gen_ai.operation.name"
    static let requestModel      = "gen_ai.request.model"
    static let responseModel     = "gen_ai.response.model"
    static let toolName          = "gen_ai.tool.name"
    static let providerName      = "gen_ai.provider.name"
    static let usageInputTokens  = "gen_ai.usage.input_tokens"
    static let usageOutputTokens = "gen_ai.usage.output_tokens"
    /// OTel general semconv attribute (not gen_ai-namespaced): the type of a
    /// failed operation. Its presence also drives the span's ERROR status.
    static let errorType         = "error.type"

    /// The one `operation.name` whose promoted span is `INTERNAL` rather than
    /// `CLIENT` (tool execution happens in-process; inference calls out).
    static let executeToolOperation = "execute_tool"
}

/// GenAI semantic-convention attributes for one event. When present (and
/// promotion is on, the default) the event is materialized as its own child
/// span — Langfuse and other GenAI-aware backends classify generations from
/// `gen_ai.*` SPAN attributes only; on span events they are invisible.
public struct GenAIAttributes: Sendable, Equatable {
    public var operationName: String?
    public var requestModel: String?
    public var responseModel: String?
    public var toolName: String?
    public var providerName: String?
    public var usageInputTokens: Int64?
    public var usageOutputTokens: Int64?
    /// When set, this operation failed: the value is emitted as `error.type` and
    /// the promoted (or containing) span is marked with OTLP status ERROR, so
    /// error-rate dashboards can see it. Nil = success/unset.
    public var errorType: String?
    /// Appended after the fixed-order gen_ai set, in caller order. Cannot
    /// express arrays/kvlists (v1 limitation of `OTLPAnyValue`).
    public var extra: [OTLPKeyValue]

    public init(operationName: String? = nil, requestModel: String? = nil,
                responseModel: String? = nil, toolName: String? = nil,
                providerName: String? = nil, usageInputTokens: Int64? = nil,
                usageOutputTokens: Int64? = nil, errorType: String? = nil,
                extra: [OTLPKeyValue] = []) {
        self.operationName = operationName
        self.requestModel = requestModel
        self.responseModel = responseModel
        self.toolName = toolName
        self.providerName = providerName
        self.usageInputTokens = usageInputTokens
        self.usageOutputTokens = usageOutputTokens
        self.errorType = errorType
        self.extra = extra
    }

    /// Fixed emission order (mapping rule M6): operation.name, request.model,
    /// response.model, tool.name, provider.name, usage.input_tokens,
    /// usage.output_tokens, error.type, then `extra` — pinned so re-exports are
    /// byte-identical.
    var keyValues: [OTLPKeyValue] {
        var out: [OTLPKeyValue] = []
        if let operationName {
            out.append(.string(GenAISemconvAttribute.operationName, operationName))
        }
        if let requestModel {
            out.append(.string(GenAISemconvAttribute.requestModel, requestModel))
        }
        if let responseModel {
            out.append(.string(GenAISemconvAttribute.responseModel, responseModel))
        }
        if let toolName {
            out.append(.string(GenAISemconvAttribute.toolName, toolName))
        }
        if let providerName {
            out.append(.string(GenAISemconvAttribute.providerName, providerName))
        }
        if let usageInputTokens {
            out.append(.int(GenAISemconvAttribute.usageInputTokens, usageInputTokens))
        }
        if let usageOutputTokens {
            out.append(.int(GenAISemconvAttribute.usageOutputTokens, usageOutputTokens))
        }
        if let errorType {
            out.append(.string(GenAISemconvAttribute.errorType, errorType))
        }
        out.append(contentsOf: extra)
        return out
    }
}

/// Adopted by payload types that carry GenAI semantics. Conformance beats the
/// `OTelExportOptions.semanticAttributes` closure: the closure is only
/// consulted when a payload's `otelSemantics` is nil (mapping rule M6).
public protocol OTelSemanticsProviding {
    var otelSemantics: GenAIAttributes? { get }
    /// Overrides the derived span/span-event name when non-nil.
    var otelEventName: String? { get }
}

extension OTelSemanticsProviding {
    public var otelSemantics: GenAIAttributes? { nil }
    public var otelEventName: String? { nil }
}
