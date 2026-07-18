// Outer compiler gate: keeps Swift 6.0/6.1 consumer builds from parsing this file's
// FM-session surface — see TracedLanguageModelSession.swift and issue #57.
#if compiler(>=6.2)
#if canImport(FoundationModels)
import Foundation
import Synchronization
import DProvenanceKit

/// Session-scoped capture state shared between a TracedLanguageModelSession
/// and its session-owned TracedTools.
///
/// COUPLING: `ActiveTraceRun.record` reads TraceContext.currentSpanID /
/// parentSpanID at record time (see core's DProvenanceKit.swift), and the
/// FoundationModels runtime may invoke tools detached from the task that
/// called respond — where every task-local is empty. This context therefore
/// captures the run handle, engine, and ambient span at turn start and
/// re-binds TraceContext.$currentRun / $currentSpanID / $parentSpanID
/// synchronously around each record.
///
/// Transcript entry ids tracked here are INTERNAL dedupe bookkeeping only;
/// they never enter payloads (the no-volatile-data contract).
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
final class FMToolCaptureContext: Sendable {
    struct State: Sendable {
        var run: (any AnyActiveTraceRun)?
        var engineName: String?
        var ambientSpanID: String?
        var ambientParentSpanID: String?
        var turnIndex: Int
        var turnSpanName: String?
        var callCounters: [String: Int] = [:]
        var recordedEntryIDs: Set<String> = []
        var liveToolEventKeys: Set<String> = []
        var promptRecordedTurns: Set<Int> = []
        var didRecordSessionPreamble = false
        var liveToolTracing: Bool
    }

    let configuration: FMTracingConfiguration
    let state: Mutex<State>

    init(configuration: FMTracingConfiguration, startingTurnIndex: Int, liveToolTracing: Bool) {
        self.configuration = configuration
        self.state = Mutex(State(turnIndex: startingTurnIndex, liveToolTracing: liveToolTracing))
    }

    var capturedRun: (any AnyActiveTraceRun)? {
        state.withLock { $0.run }
    }

    var liveToolTracing: Bool {
        state.withLock { $0.liveToolTracing }
    }

    /// Starts a turn and captures the ambient run handle, engine, and span so
    /// tool invocations dispatched by the FM runtime can record into the
    /// originating run even when detached. Resets per-turn invocation counters.
    ///
    /// `promptOrdinal` is the transcript-derived prompt count at turn start,
    /// NOT an internal counter: it keeps the wrapper's turn numbering equal to
    /// the ordinals a post-hoc transcript mapping computes, even when the
    /// `base` escape hatch appends turns this wrapper never saw, or a failed
    /// turn never reached the transcript. Live dedupe markers keyed by turn
    /// stay valid against `recordProvenance()` for exactly this reason.
    func beginTurn(promptOrdinal: Int) -> (turnIndex: Int, spanName: String) {
        let run = TraceContext.currentRun
        let engine = TraceContext.engineStack.last
        let span = TraceContext.currentSpanID
        let parent = TraceContext.parentSpanID
        return state.withLock { s in
            let turn = promptOrdinal
            s.turnIndex = turn + 1
            s.run = run
            s.engineName = engine
            s.ambientSpanID = span
            s.ambientParentSpanID = parent
            s.turnSpanName = FMSpanPath.turn(turn, sessionLabel: configuration.sessionLabel)
            s.callCounters = [:]
            return (turn, s.turnSpanName ?? FMSpanPath.turn(turn, sessionLabel: configuration.sessionLabel))
        }
    }

    var currentTurnIndex: Int {
        state.withLock { max($0.turnIndex - 1, 0) }
    }

    /// Resolves the invocation ordinal and span names for a session-owned tool
    /// call. Does NOT register the live-copy dedupe key — the caller marks it
    /// via `markLiveToolCall` only after the record actually delivered, so an
    /// undelivered live record never makes reconciliation skip the transcript
    /// copy.
    func beginToolCall(named toolName: String) -> (turnIndex: Int, invocationIndex: Int, turnSpanName: String, toolSpanName: String) {
        state.withLock { s in
            let turn = max(s.turnIndex - 1, 0)
            let k = s.callCounters[toolName, default: 0]
            s.callCounters[toolName] = k + 1
            let turnSpan = s.turnSpanName ?? FMSpanPath.turn(turn, sessionLabel: configuration.sessionLabel)
            let toolSpan = FMSpanPath.tool(
                named: toolName, invocation: k, turnIndex: turn, sessionLabel: configuration.sessionLabel
            )
            return (turn, k, turnSpan, toolSpan)
        }
    }

    func markLiveToolCall(turnIndex: Int, toolName: String, invocationIndex: Int) {
        state.withLock {
            _ = $0.liveToolEventKeys.insert(
                Self.toolEventKey(kind: "call", turn: turnIndex, toolName: toolName, invocation: invocationIndex)
            )
        }
    }

    func markLiveToolOutput(turnIndex: Int, toolName: String, invocationIndex: Int) {
        state.withLock {
            _ = $0.liveToolEventKeys.insert(
                Self.toolEventKey(kind: "output", turn: turnIndex, toolName: toolName, invocation: invocationIndex)
            )
        }
    }

    func hasLiveToolEvent(kind: String, turn: Int, toolName: String, invocation: Int) -> Bool {
        state.withLock {
            $0.liveToolEventKeys.contains(
                Self.toolEventKey(kind: kind, turn: turn, toolName: toolName, invocation: invocation)
            )
        }
    }

    static func toolEventKey(kind: String, turn: Int, toolName: String, invocation: Int) -> String {
        "\(kind):\(turn):\(toolName):\(invocation)"
    }

    func markPromptRecorded(turn: Int) {
        state.withLock { _ = $0.promptRecordedTurns.insert(turn) }
    }

    func promptWasRecordedLive(turn: Int) -> Bool {
        state.withLock { $0.promptRecordedTurns.contains(turn) }
    }

    func markEntriesRecorded(_ ids: some Sequence<String>) {
        state.withLock { $0.recordedEntryIDs.formUnion(ids) }
    }

    func isEntryRecorded(_ id: String) -> Bool {
        state.withLock { $0.recordedEntryIDs.contains(id) }
    }

    /// Returns true exactly once per session.
    func claimSessionPreamble() -> Bool {
        state.withLock {
            guard !$0.didRecordSessionPreamble else { return false }
            $0.didRecordSessionPreamble = true
            return true
        }
    }

    /// True when a record issued right now would land in a run the configured
    /// recorder can deliver into: the ambient task-local run, or (when the
    /// task has none) the run handle captured at turn start. Callers gate
    /// dedupe bookkeeping on this so soft no-ops stay backfillable.
    func canDeliverNow() -> Bool {
        if TraceContext.currentRun != nil {
            return configuration.recorder.canDeliver()
        }
        guard let captured = state.withLock({ $0.run }) else { return false }
        return TraceContext.$currentRun.withValue(captured) {
            configuration.recorder.canDeliver()
        }
    }

    /// Records with explicit span identity derived from `spanPath`
    /// (leaf = last name, parent = the name above it, falling back to the
    /// ambient span captured at turn start). When the invoking task has an
    /// ambient run its task-locals win; otherwise the captured handle and
    /// engine are re-bound so detached tool invocations still land.
    ///
    /// Returns whether the record could deliver (probed under the exact run
    /// binding the record used) — callers must not advance dedupe bookkeeping
    /// on `false`.
    @discardableResult
    func record(_ event: FoundationModelTraceEvent, spanPath: [String]) -> Bool {
        let (capturedRun, capturedEngine, capturedSpan, capturedParent) = state.withLock {
            ($0.run, $0.engineName, $0.ambientSpanID, $0.ambientParentSpanID)
        }

        let inTask = TraceContext.currentRun != nil
        let ambientSpan = inTask ? TraceContext.currentSpanID : capturedSpan
        let ambientParent = inTask ? TraceContext.parentSpanID : capturedParent

        let leaf: String?
        let parent: String?
        if let last = spanPath.last {
            leaf = last
            parent = spanPath.count >= 2 ? spanPath[spanPath.count - 2] : ambientSpan
        } else {
            leaf = ambientSpan
            parent = ambientParent
        }

        let engineStack = TraceContext.engineStack.isEmpty
            ? [capturedEngine ?? configuration.engineName]
            : TraceContext.engineStack

        var delivered = false
        func emit() {
            TraceContext.$engineStack.withValue(engineStack) {
                TraceContext.$currentSpanID.withValue(leaf) {
                    TraceContext.$parentSpanID.withValue(parent) {
                        delivered = configuration.recorder.canDeliver()
                        configuration.recorder.record(event)
                    }
                }
            }
        }

        if !inTask, let capturedRun {
            TraceContext.$currentRun.withValue(capturedRun) { emit() }
        } else {
            emit()
        }
        return delivered
    }
}
#endif
#endif  // compiler(>=6.2)
