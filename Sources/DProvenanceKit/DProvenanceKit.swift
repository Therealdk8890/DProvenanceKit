import Foundation
import os

#if DEBUG
/// Fires in DEBUG builds when instrumentation records with no active run. The
/// event is dropped by design (recording is a soft no-op outside a `run` scope),
/// but that silence is the single most common onboarding trap, so we surface it
/// here without changing the release-build behavior or trapping the process.
private let dpkDiagnosticsLog = Logger(subsystem: "com.dprovenancekit", category: "diagnostics")
#endif

public protocol AnyActiveTraceRun: Sendable {
    /// The id of this run — the same value `DProvenanceKit.run(...)` hands back so
    /// the recorded run can be fetched from the store and diffed.
    var runID: UUID { get }
    func recordAny(_ payload: Any, engineName: String?) -> UUID?
    func link(source: UUID, target: UUID, type: TraceEdgeType)
    func flush() async throws
}

public enum TraceContext {
    @TaskLocal public static var currentRun: AnyActiveTraceRun?
    @TaskLocal public static var engineStack: [String] = []
    @TaskLocal public static var currentSpanID: String?
    @TaskLocal public static var parentSpanID: String?
}

public enum DProvenanceKit<T: TraceableEvent> {
    public final class ActiveTraceRun: @unchecked Sendable, AnyActiveTraceRun {
        public let runID: UUID
        public let contextID: String
        private let store: any TraceStore<T>
        private let schemaVersion: Int
        private let sequenceLock = NSLock()
        private var sequenceCounter: UInt64 = 0

        public init(contextID: String, store: any TraceStore<T>, schemaVersion: Int = 1) {
            self.runID = UUID()
            self.contextID = contextID
            self.store = store
            self.schemaVersion = schemaVersion
        }

        @discardableResult
        public func record(_ payload: T, engineName: String?) -> UUID {
            sequenceLock.lock()
            let seq = sequenceCounter
            sequenceCounter += 1
            sequenceLock.unlock()
            
            let traceEvent = TraceEvent(
                runID: runID,
                contextID: contextID,
                engineName: engineName ?? "Unknown",
                schemaVersion: schemaVersion,
                sequence: seq,
                spanID: TraceContext.currentSpanID,
                parentSpanID: TraceContext.parentSpanID,
                payload: payload,
                timestamp: Date()
            )
            store.record(traceEvent)
            return traceEvent.id
        }
        
        @discardableResult
        public func recordAny(_ payload: Any, engineName: String?) -> UUID? {
            guard let typedPayload = payload as? T else { return nil }
            return self.record(typedPayload, engineName: engineName)
        }

        public func link(source: UUID, target: UUID, type: TraceEdgeType) {
            // Reject self-referential edges at the write boundary — they are never
            // valid provenance and would otherwise have to be filtered downstream.
            guard source != target else { return }
            store.link(source: source, target: target, type: type)
        }

        /// Records `payload` and links it to the events it was derived from, so the
        /// lineage/impact/explain graph is populated as you record instead of requiring
        /// manual UUID bookkeeping. The edge runs parent → new event, matching
        /// `TraceStore.explain`/`lineageEdges`. Returns the new event's id.
        @discardableResult
        public func record(_ payload: T, derivedFrom parents: [UUID],
                           engineName: String? = nil, type: TraceEdgeType = .derivedFrom) -> UUID {
            let id = record(payload, engineName: engineName)
            for parent in parents {
                link(source: parent, target: id, type: type)
            }
            return id
        }

        /// Single-parent convenience for ``record(_:derivedFrom:engineName:type:)``.
        @discardableResult
        public func record(_ payload: T, derivedFrom parent: UUID,
                           engineName: String? = nil, type: TraceEdgeType = .derivedFrom) -> UUID {
            record(payload, derivedFrom: [parent], engineName: engineName, type: type)
        }

        public func flush() async throws {
            try await store.flush()
        }
    }

    public static func run<R>(
        contextID: String,
        store: any TraceStore<T>,
        schemaVersion: Int = 1,
        _ block: () async throws -> R
    ) async rethrows -> R {
        let run = ActiveTraceRun(contextID: contextID, store: store, schemaVersion: schemaVersion)
        return try await TraceContext.$currentRun.withValue(run) {
            try await block()
        }
    }

    /// Records a run and returns both the block's result and the run's `runID`.
    ///
    /// This closes the Run → Record → Query → Diff loop from a single call: the
    /// plain `run` returns only the block's value, so the recorded run was
    /// previously unreachable without an empty-query detour. Take the `runID` and
    /// fetch the run straight back for diffing or alignment:
    ///
    /// ```swift
    /// let (_, runID) = try await DProvenanceKit<MyEvent>.runReturningID(contextID: "case", store: store) { run in
    ///     run.record(.stepA, engineName: nil)     // or DProvenanceKit.record(.stepA)
    /// }
    /// let recorded = try await store.getRun(id: runID)
    /// ```
    ///
    /// This is a distinct method rather than a `run` overload on purpose: overloading
    /// `run` only on the closure's arity is ambiguous when the closure ignores its
    /// parameter, so a separate name keeps every existing `run { }` call site stable.
    /// The closure receives the `ActiveTraceRun`; ignore it with `{ _ in … }` and use
    /// ambient `DProvenanceKit.record` if you prefer.
    @discardableResult
    public static func runReturningID<R>(
        contextID: String,
        store: any TraceStore<T>,
        schemaVersion: Int = 1,
        _ block: (ActiveTraceRun) async throws -> R
    ) async rethrows -> (result: R, runID: UUID) {
        let run = ActiveTraceRun(contextID: contextID, store: store, schemaVersion: schemaVersion)
        let result = try await TraceContext.$currentRun.withValue(run) {
            try await block(run)
        }
        return (result, run.runID)
    }

    public static func runSync<R>(
        contextID: String,
        store: any TraceStore<T>,
        schemaVersion: Int = 1,
        _ block: () throws -> R
    ) rethrows -> R {
        let run = ActiveTraceRun(contextID: contextID, store: store, schemaVersion: schemaVersion)
        return try TraceContext.$currentRun.withValue(run) {
            try block()
        }
    }

    public static func withEngine<R>(
        name: String,
        _ block: () async throws -> R
    ) async rethrows -> R {
        let newStack = TraceContext.engineStack + [name]
        return try await TraceContext.$engineStack.withValue(newStack) {
            try await block()
        }
    }

    public static func withEngineSync<R>(
        name: String,
        _ block: () throws -> R
    ) rethrows -> R {
        let newStack = TraceContext.engineStack + [name]
        return try TraceContext.$engineStack.withValue(newStack) {
            try block()
        }
    }

    public static func withSpan<R>(
        _ block: () async throws -> R
    ) async rethrows -> R {
        let newSpanID = UUID().uuidString
        let parent = TraceContext.currentSpanID
        return try await TraceContext.$currentSpanID.withValue(newSpanID) {
            try await TraceContext.$parentSpanID.withValue(parent) {
                try await block()
            }
        }
    }

    public static func withSpanSync<R>(
        _ block: () throws -> R
    ) rethrows -> R {
        let newSpanID = UUID().uuidString
        let parent = TraceContext.currentSpanID
        return try TraceContext.$currentSpanID.withValue(newSpanID) {
            try TraceContext.$parentSpanID.withValue(parent) {
                try block()
            }
        }
    }

    /// Open a span with a caller-supplied, human-readable identifier instead of a
    /// random UUID. The span id doubles as the node label in the trace viewer and
    /// only needs to be unique within a run, so a stable name like "Draft
    /// Generation" groups every event of the run under one meaningful node.
    public static func withSpan<R>(
        named name: String,
        _ block: () async throws -> R
    ) async rethrows -> R {
        let parent = TraceContext.currentSpanID
        return try await TraceContext.$currentSpanID.withValue(name) {
            try await TraceContext.$parentSpanID.withValue(parent) {
                try await block()
            }
        }
    }

    public static func withSpanSync<R>(
        named name: String,
        _ block: () throws -> R
    ) rethrows -> R {
        let parent = TraceContext.currentSpanID
        return try TraceContext.$currentSpanID.withValue(name) {
            try TraceContext.$parentSpanID.withValue(parent) {
                try block()
            }
        }
    }

    @discardableResult
    public static func record(_ payload: T) -> UUID? {
        guard let run = TraceContext.currentRun else {
            // Soft failure for executions outside of DProvenanceKit.run. Dropping
            // is deliberate (see DESIGN.md §3) so leftover instrumentation never
            // crashes production — but it silently loses events, which trips up
            // adopters. Warn in DEBUG only; release behavior is unchanged.
            #if DEBUG
            dpkDiagnosticsLog.warning("""
            DProvenanceKit.record(_:) called with no active run — event of type \
            '\(payload.typeIdentifier, privacy: .public)' was dropped. Wrap recording in \
            DProvenanceKit.run(contextID:store:) { ... }. Note: @TaskLocal run context does \
            not propagate across Task.detached { } — use Task { } or pass the run explicitly.
            """)
            #endif
            return nil
        }
        return run.recordAny(payload, engineName: TraceContext.engineStack.last)
    }

    /// Records `payload` and links it to the events it was derived from in one call,
    /// so the lineage/impact/explain graph is built as you record — no manual UUID
    /// bookkeeping or separate `link` calls. The edge runs parent → new event, the
    /// direction `TraceStore.explain`/`lineageEdges` expect. Returns the new event's
    /// id (nil when recording is a soft no-op outside a `run` scope), which you can
    /// feed as a parent to later derivations.
    ///
    /// ```swift
    /// let doc = DProvenanceKit.record(.documentEvaluated(id: "A", score: 0.9))
    /// let decision = DProvenanceKit.record(.decisionMade(approved: true), derivedFrom: doc!)
    /// let graph = try await store.lineage(of: decision!)   // decision ← doc
    /// ```
    @discardableResult
    public static func record(_ payload: T, derivedFrom parents: [UUID],
                              type: TraceEdgeType = .derivedFrom) -> UUID? {
        guard let id = record(payload) else { return nil }
        for parent in parents {
            link(source: parent, target: id, type: type)
        }
        return id
    }

    /// Single-parent convenience for ``record(_:derivedFrom:type:)``.
    @discardableResult
    public static func record(_ payload: T, derivedFrom parent: UUID,
                              type: TraceEdgeType = .derivedFrom) -> UUID? {
        record(payload, derivedFrom: [parent], type: type)
    }

    public static func link(source: UUID, target: UUID, type: TraceEdgeType) {
        guard let run = TraceContext.currentRun else { return }
        run.link(source: source, target: target, type: type)
    }
    
    public static func flush() async throws {
        guard let run = TraceContext.currentRun else { return }
        try await run.flush()
    }
}
