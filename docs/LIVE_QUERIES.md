# Live Trace Queries

Every query in the README runs *after the fact*: record the run, then ask questions. `LiveTraceQueryEngine` flips that around — register a `TraceQueryDSL` query once and get a callback **the moment a run starts matching it**, while the run is still executing. It's the difference between finding out tonight that an agent skipped validation, and finding out on the event that proves it.

The same query language, the same semantics, evaluated continuously instead of on demand.

## Minimal end-to-end example

Using the `MyAIDecision` event type from the [README's *Getting started* section](../README.md#getting-started):

```swift
import DProvenanceKit

struct SkippedValidationAlert: TraceQuerySubscription {
    typealias T = MyAIDecision

    let queryID = UUID()
    let query = TraceQueryDSL<MyAIDecision>()
        .requiring(step: "conflictDetected")
        .missing(step: "documentEvaluated")

    func onMatch(run: TraceRun<MyAIDecision>) {
        print("run \(run.runID) reported a conflict without evaluating any document")
    }

    func onUpdate(run: TraceRun<MyAIDecision>) {
        // The run grew and still matches.
    }
}

let live = LiveTraceQueryEngine<MyAIDecision>()
await live.register(SkippedValidationAlert())

let store = InMemoryTraceStore(liveEngine: live)

await DProvenanceKit<MyAIDecision>.run(contextID: "Case-12345", store: store) {
    DProvenanceKit<MyAIDecision>.record(.conflictDetected(reason: "timeline_inconsistency"))
}
```

The moment `conflictDetected` is recorded (and no `documentEvaluated` has been), `onMatch` fires with a snapshot of the run.

## How it works

The engine is an actor that holds registered subscriptions and per-query match state. On each `process(event:run:)`:

1. **Only affected queries re-evaluate.** At registration, the engine extracts every `typeIdentifier` the query's AST references and builds an inverted index. An arriving event re-evaluates only the queries that reference its type, plus *global* queries that reference no specific type (e.g. a bare `filter(contextID:)`). As a safety fallback, an event whose type matches no index entry — when there are no global queries either — re-evaluates **every** subscription rather than risk a miss; that is the worst-case cost.
2. **Match state gives you edge-triggered callbacks.** `onMatch(run:)` fires exactly once, when a run *first* satisfies the query. Subsequent events on an already-matching run fire `onUpdate(run:)`. If a run stops matching (a `.missing(step:)` query, once the step finally arrives), its state is cleared silently — and a later re-match fires `onMatch` again.

`InMemoryTraceStore` is the integration point. Pass a `liveEngine` at init and every `record` yields `(event, run-snapshot)` over an unbounded `AsyncStream` drained by a single serial consumer — so subscriptions observe events in exactly the order they were recorded, even under concurrent ingestion, and the run snapshot always already contains the event that triggered it. `record` itself stays synchronous and non-blocking; callbacks fire asynchronously shortly after.

## API reference

```swift
public protocol TraceQuerySubscription<T>: Sendable {
    associatedtype T: TraceableEvent
    var queryID: UUID { get }
    var query: TraceQueryDSL<T> { get }
    func onMatch(run: TraceRun<T>)
    func onUpdate(run: TraceRun<T>)
}

public struct QueryState: Sendable {
    public var matchingRuns: Set<UUID>
}

public actor LiveTraceQueryEngine<T: TraceableEvent> {
    public init()
    public func register(_ subscription: any TraceQuerySubscription<T>)
    public func process(event: TraceEvent<T>, run: TraceRun<T>) async
}

// Integration point — record(_:) feeds the live engine automatically:
public final class InMemoryTraceStore<T: TraceableEvent>: TraceStore, @unchecked Sendable {
    public init(liveEngine: LiveTraceQueryEngine<T>? = nil)
}
```

`process(event:run:)` is public so custom pipelines can drive the engine directly; with `InMemoryTraceStore` you never call it yourself.

## Constraints and limitations

- **Only `InMemoryTraceStore` feeds the engine.** `SQLiteTraceStore` and `CloudTraceStore` have no live-engine hookup.
- **There is no `unregister`.** Subscriptions live as long as the engine, and per-query `matchingRuns` state grows with the number of runs observed. Scope a live engine to a bounded workload (a test session, a debugging window) rather than an unbounded production lifetime.
- **There is no "unmatch" notification.** When a run drops out of a query's match set, state is cleared without a callback.
- **Callbacks run inside the actor, synchronously.** A slow `onMatch`/`onUpdate` stalls live processing for every subscription. Do the cheap thing in the callback (set a flag, enqueue work) and get out.
