import Foundation
import DProvenanceKit

/// How much of each event's payload is re-encoded into `dpk.payload`.
public enum PayloadInclusion: Sendable, Equatable {
    case full
    /// Cut on a UTF-8 boundary; `dpk.payload_truncated = true` is added only
    /// when a cut actually happened.
    case truncated(maxBytes: Int)
    case omitted
}

/// How events carrying `GenAIAttributes` are materialized (mapping rule M6).
public enum GenAIPromotion: Sendable, Equatable {
    /// DEFAULT. Each semantics-bearing event becomes its own child span so
    /// Langfuse (and GenAI-aware backends) classify it as a generation —
    /// they only read gen_ai.* from SPAN attributes, never span events.
    case dedicatedChildSpan
    /// gen_ai.* merged onto the span-event attributes. Invisible to
    /// Langfuse's generation mapping; documented escape hatch.
    case attachedToEventOnly
}

public struct OTelExportOptions<T: TraceableEvent>: Sendable {
    /// `service.name` resource attribute.
    public var serviceName: String

    /// Appended after the fixed resource attributes (mapping rule M9), in
    /// caller order.
    public var resourceAttributes: [OTLPKeyValue]

    /// Opt-in snapshot of the source store's drop tally, mirrored onto the
    /// resource so backends can see whether the export is structurally
    /// complete. Store-scoped ("state of the store at export time"), not
    /// per-run — DPK does not attribute drops to runs.
    public var dropStats: TraceDropStats?

    /// Root span name; when it returns an empty string the mapper falls back
    /// to `"run " + first 8 hex of traceId` (a `contextID` can be empty).
    public var rootSpanName: @Sendable (TraceRun<T>) -> String

    /// Child span display name. The original DPK span id survives any
    /// override in the `dpk.span_id` attribute.
    public var childSpanName: @Sendable (_ dpkSpanID: String) -> String

    public var payloadInclusion: PayloadInclusion

    public var genAIPromotion: GenAIPromotion

    /// Fallback semantics source for payload types that cannot adopt
    /// `OTelSemanticsProviding`; a payload's own conformance wins when it
    /// returns non-nil.
    public var semanticAttributes: (@Sendable (TraceEvent<T>) -> GenAIAttributes?)?

    /// Root span status; nil means UNSET. Child and promoted spans are
    /// always UNSET.
    public var rootStatus: (@Sendable (TraceRun<T>) -> OTLPStatus)?

    public init() {
        self.serviceName = "dprovenancekit"
        self.resourceAttributes = []
        self.dropStats = nil
        self.rootSpanName = { $0.contextID }
        self.childSpanName = { $0 }
        self.payloadInclusion = .truncated(maxBytes: 32_768)
        self.genAIPromotion = .dedicatedChildSpan
        self.semanticAttributes = nil
        self.rootStatus = nil
    }
}
