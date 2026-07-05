# CloudTraceStore (Experimental)

> **Status: experimental.** The ingestion path — buffering, load-shedding, retry, circuit breaking, quarantine — is real and chaos-tested. The query path is not implemented, and no server ships with this repository. DProvenanceKit's core promise remains local-first (see [DESIGN.md](../DESIGN.md)); this store is an early client-side building block for the "distributed trace federation" direction the README lists as planned. A hosted team version — shared traces, CI regression gates, monitoring — is a separate commercial offering ([COMMERCIAL.md](../COMMERCIAL.md)).

Sometimes traces need to leave the device — a fleet of agents, a CI box, a beta cohort. `CloudTraceStore` is a `TraceStore` that ships events to an HTTP endpoint you operate, engineered around one rule: **recording never blocks and never lies**. Events buffer in memory offline-first, ship in background batches, back off through failures, and when something is finally lost or undeliverable, it's counted or quarantined — never silently gone.

## Minimal end-to-end example

Using the `MyAIDecision` event type from the [README's *Getting started* section](../README.md#getting-started):

```swift
import DProvenanceKit

let store = CloudTraceStore<MyAIDecision>(
    endpoint: URL(string: "https://traces.example.com/v1")!,
    apiKey: "your-api-key",
    config: OfflineConfig(
        capacity: BufferCapacity(
            maxItems: 10_000,
            maxBytes: 8 * 1024 * 1024,
            maxEventSizeBytes: 256 * 1024
        ),
        eviction: .dropOldest
    )
)

await DProvenanceKit<MyAIDecision>.run(contextID: "Case-12345", store: store) {
    DProvenanceKit<MyAIDecision>.record(.finalDecisionMade(approved: true))
}

do {
    try await store.flush(timeout: 10)
} catch CloudWriterError.flushTimedOut(let undelivered) {
    print("\(undelivered) events still buffered — endpoint unreachable")
}
```

## The write path

`record(_:)` is non-blocking: it JSON-encodes the payload into a wire row and enqueues it in the same priority-bucketed, capacity-bounded `TraceWriteBuffer` the SQLite store uses. A background `CloudWriter` actor drains the buffer — batches of up to 1,000 rows, every 500 ms — and POSTs JSON to `{endpoint}/ingest` with a `Bearer` API key.

**Buffer semantics under pressure** (the same guarantees as local recording, documented in the README's *How it really works*):

- One FIFO per priority tier; ingestion and shedding are O(1) even at capacity.
- `.dropOldest` evicts the oldest event of the *lowest* tier first (`telemetry`, then `diagnostic`). `structural` backlog is never evicted unless the incoming event is `critical`; in the worst case a critical may displace the oldest structural or the oldest critical.
- `.rejectNew` refuses the incoming event instead.
- A per-run soft cap (default 5,000 buffered events per run) sheds only `telemetry` and `diagnostic` for the bursting run — its `structural` and `critical` events keep flowing.
- An event larger than `maxEventSizeBytes` is dropped at the door.
- Every one of these losses is tallied by tier in `dropStats`:

```swift
let drops = store.dropStats
if !drops.preservedIntegrity {
    print("shed \(drops.structural) structural and \(drops.critical) critical events — diffs over this data are suspect")
}
```

One known exception to the accounting: a payload that fails `JSONEncoder` inside `record` is dropped silently and **not** counted in `dropStats`. Keep payloads reliably `Encodable`.

## Failure handling

**Retries.** A failed batch is retried up to 10 times with jittered exponential backoff, capped at 60 s per wait. The batch stays "inflight" between attempts — it is not lost if the writer loops.

**Circuit breaker.** After 5 consecutive failures the breaker opens and the writer stops hammering the endpoint for 30 s, then lets a single half-open probe through; success closes the circuit, failure re-opens it. This is the standard `CircuitBreaker` actor, public and reusable:

```swift
func guardedSend(breaker: CircuitBreaker, send: () async throws -> Void) async {
    guard await breaker.allowRequest() else {
        let wait = await breaker.timeUntilAllowed()
        print("circuit open — retry in \(wait)s")
        return
    }

    do {
        try await send()
        await breaker.recordSuccess()
    } catch {
        await breaker.recordFailure()
    }
}
```

**Poison batches.** An HTTP 400 means the server rejected the batch's content — retrying can't fix it. The whole batch is quarantined in memory instead of poisoning the retry loop. Batches that exhaust all 10 attempts are quarantined the same way.

**Bounded flush.** `flush(timeout:)` is a drain barrier that refuses to hang: it returns once everything is delivered or quarantined, and throws `CloudWriterError.flushTimedOut(undelivered:)` if the deadline passes first — the undelivered events remain buffered, not lost. The protocol-witness `flush()` uses the default 30 s timeout.

## Quarantine and replay

Quarantined events can be pulled back out and fed to the [replay engine](REPLAY.md), which flags every span they touch instead of leaving it silently incomplete:

```swift
let quarantined = try await store.queryQuarantinedEvents(TraceQueryDSL<MyAIDecision>())

let engine = TraceReplayEngine(committed: run.events, quarantined: quarantined)
let snapshot = engine.snapshot()
print("contaminated spans:", snapshot.manifest.contaminatedSpans)
```

Two sharp edges to know:

- **Quarantine is in-memory only.** Quarantined batches do not survive process exit; there is no persistence or automatic re-drive.
- **Round-tripped IDs don't match.** `record` mints a fresh UUID for the wire row rather than reusing `event.id`, so a quarantined event comes back with a *different* event ID than the one originally recorded. ID-based correlation — including the replay manifest's duplicate detection — cannot match it to the original.

## Wire contract

No reference server ships with the repository; the contract below is what the client sends and expects. All requests carry `Authorization: Bearer {apiKey}` and `Content-Type: application/json`.

`POST {endpoint}/ingest` — a JSON array of event objects:

```json
{
  "id": "…", "run_id": "…", "context_id": "…",
  "priority": 3, "sequence": 17,
  "engine": "DocumentAnalyzer",
  "span_id": "…", "parent_span_id": null,
  "type": "finalDecisionMade",
  "payload": { "…": "inline JSON, or a base64 string if the payload isn't valid JSON" },
  "timestamp": 1767225600000000
}
```

`timestamp` is microseconds since the Unix epoch. Any 2xx acknowledges the batch; 400 quarantines it; anything else triggers retry/backoff.

## What is *not* implemented

Be aware before you build on it:

- **`queryRuns(_:)` cannot return data.** The request side is real — it POSTs `{schemaVersion, dsl, limit}` to `{endpoint}/query` and maps error responses (`UNSUPPORTED_SCHEMA` on 400/422 → `CloudTraceStoreError.unsupportedSchema`, 501 → `.notImplemented`, other non-2xx → `.serverError`) — but response decoding was never implemented: **on success it always returns `[]`**. Query your traces locally; the cloud store is an ingestion transport.
- **`negotiateCapabilities()` negotiates nothing.** It performs a GET to `{endpoint}/capabilities` and only verifies a 2xx; it parses no response.
- **No clean shutdown.** The background writer task starts in `init` and runs for the lifetime of the process; `CloudTraceStore` exposes no way to stop it.
- **Failure logging is `print()` to stdout.** There is no logging hook yet.

## API reference

```swift
public final class CloudTraceStore<T: TraceableEvent>: TraceStore, @unchecked Sendable {
    public init(endpoint: URL, apiKey: String,
                config: OfflineConfig = OfflineConfig(),
                session: URLSession = .shared)
    public func record(_ event: TraceEvent<T>)
    public func flush() async throws                       // 30 s default timeout
    public func flush(timeout: TimeInterval) async throws  // throws CloudWriterError.flushTimedOut
    public var dropStats: TraceDropStats { get }
    public func negotiateCapabilities() async throws                                  // stub: 2xx check only
    public func queryRuns(_ dsl: TraceQueryDSL<T>) async throws -> [TraceRun<T>]      // always [] on success
    public func queryQuarantinedEvents(_ dsl: TraceQueryDSL<T>) async throws -> [TraceEvent<T>]
}

public enum CloudTraceStoreError: Error {
    case notImplemented
    case serverError(Int)
    case unsupportedSchema(expected: String, received: String)
}

public enum CloudWriterError: Error, Equatable {
    case flushTimedOut(undelivered: Int)
}

public struct BufferCapacity: Sendable {
    public init(maxItems: Int = 50_000,
                maxBytes: Int = 50 * 1024 * 1024,
                maxEventSizeBytes: Int = 1 * 1024 * 1024)
}

public enum EvictionPolicy: Sendable {
    case dropOldest   // evict lowest-priority-oldest to admit the new event
    case rejectNew    // refuse the incoming event instead
}

public struct OfflineConfig: Sendable {
    public init(capacity: BufferCapacity = BufferCapacity(),
                eviction: EvictionPolicy = .dropOldest)
}

public actor CircuitBreaker {
    public enum State: Sendable, Equatable { case closed, open, halfOpen }
    public private(set) var state: State { get }
    public init(maxFailures: Int = 5, decayTimeout: TimeInterval = 30.0)
    public func allowRequest() -> Bool
    public func timeUntilAllowed() -> TimeInterval
    public func recordSuccess()
    public func recordFailure()
}
```

`CloudWriter` (the background drain actor) is also public, but `CloudTraceStore` constructs and owns its own instance; there is rarely a reason to instantiate one directly.
