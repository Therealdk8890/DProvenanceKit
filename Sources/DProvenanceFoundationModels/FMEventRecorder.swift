import Foundation
import DProvenanceKit

/// Adopted by host event vocabularies that want FoundationModels events to
/// land as a case of their own payload type (see `FMEventRecorder.embedding`).
public protocol FoundationModelEventEmbedding: TraceableEvent {
    init(foundationModelEvent: FoundationModelTraceEvent)
}

/// Routes FoundationModels events into whatever run is ambient. All routes
/// are safe no-ops outside a run (core's record semantics). Each built-in route
/// probes the ambient run's concrete type first, so a route whose payload type
/// does not match records nothing and never trips core's type-mismatch counter
/// (`ActiveTraceRun.payloadTypeMismatchCount`) or its DEBUG warning.
///
/// `canDeliver` reports whether a record issued right now would land: the
/// capture layer consults it before spending dedupe bookkeeping (entry-id
/// marks, the one-shot session preamble), so a soft no-op never poisons a
/// later `recordProvenance()` backfill. The built-in routes probe the ambient
/// run's concrete type; a custom `init` defaults to run-presence only, which
/// can overcount deliverability if the custom route's payload type mismatches
/// the run — pass an exact probe alongside custom routes that care.
public struct FMEventRecorder: Sendable {
    private let route: @Sendable (FoundationModelTraceEvent) -> Void

    /// True when the ambient `TraceContext.currentRun` would accept this
    /// recorder's payloads. Must be evaluated on the task that records.
    public let canDeliver: @Sendable () -> Bool

    public init(
        record: @escaping @Sendable (FoundationModelTraceEvent) -> Void,
        canDeliver: @escaping @Sendable () -> Bool = { TraceContext.currentRun != nil }
    ) {
        self.route = record
        self.canDeliver = canDeliver
    }

    /// For `DProvenanceKit<FoundationModelTraceEvent>` runs.
    public static let direct = FMEventRecorder { event in
        guard TraceContext.currentRun is DProvenanceKit<FoundationModelTraceEvent>.ActiveTraceRun else { return }
        DProvenanceKit<FoundationModelTraceEvent>.record(event)
    } canDeliver: {
        TraceContext.currentRun is DProvenanceKit<FoundationModelTraceEvent>.ActiveTraceRun
    }

    /// For `AnyTraceableEvent` runs, via `eraseToAny()` (deterministic rawJSON).
    public static let typeErased = FMEventRecorder { event in
        guard TraceContext.currentRun is DProvenanceKit<AnyTraceableEvent>.ActiveTraceRun else { return }
        DProvenanceKit<AnyTraceableEvent>.record(event.eraseToAny())
    } canDeliver: {
        TraceContext.currentRun is DProvenanceKit<AnyTraceableEvent>.ActiveTraceRun
    }

    /// DEFAULT: direct when the ambient run is typed for FM events, typeErased
    /// when it is an `AnyTraceableEvent` run; an unrelated-payload run records
    /// neither. At most one lands.
    public static let automatic = FMEventRecorder { event in
        let run = TraceContext.currentRun
        if run is DProvenanceKit<FoundationModelTraceEvent>.ActiveTraceRun {
            DProvenanceKit<FoundationModelTraceEvent>.record(event)
        } else if run is DProvenanceKit<AnyTraceableEvent>.ActiveTraceRun {
            DProvenanceKit<AnyTraceableEvent>.record(event.eraseToAny())
        }
    } canDeliver: {
        TraceContext.currentRun is DProvenanceKit<FoundationModelTraceEvent>.ActiveTraceRun
            || TraceContext.currentRun is DProvenanceKit<AnyTraceableEvent>.ActiveTraceRun
    }

    /// For runs typed by a host vocabulary that embeds FM events as a case.
    public static func embedding<T: FoundationModelEventEmbedding>(_ type: T.Type) -> FMEventRecorder {
        FMEventRecorder { event in
            guard TraceContext.currentRun is DProvenanceKit<T>.ActiveTraceRun else { return }
            DProvenanceKit<T>.record(T(foundationModelEvent: event))
        } canDeliver: {
            TraceContext.currentRun is DProvenanceKit<T>.ActiveTraceRun
        }
    }

    /// Records under the engine name "FoundationModels" when the caller has
    /// not established an engine; a caller-established engine is respected.
    /// (Configuration-driven paths bind their `engineName` before reaching
    /// here, so a custom name wins over this default.)
    public func record(_ event: FoundationModelTraceEvent) {
        guard TraceContext.engineStack.isEmpty else {
            route(event)
            return
        }
        DProvenanceKit<FoundationModelTraceEvent>.withEngineSync(name: FMTracingConfiguration.defaultEngineName) {
            route(event)
        }
    }
}
