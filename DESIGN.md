# DProvenanceKit — Design Notes

This document explains *why* DProvenanceKit is built the way it is. The public README covers what it does and how to use it; this is the layer underneath — the decisions, the tradeoffs they cost, and the failure modes the architecture has to defend against. It's written for anyone evaluating the library's internals, contributing to it, or deciding whether its guarantees are trustworthy enough to build on.

---

## 1. Goals and non-goals

The system optimizes for four things, in priority order:

1. **Non-intrusiveness.** Recording a reasoning event must never block, slow, or alter the execution being observed. Observability that changes the thing it observes is worse than none.
2. **Correctness under burst.** Reasoning systems emit events in spikes, not steady streams. The design has to stay correct and bounded at the exact moment a burst pins every buffer at capacity.
3. **Reproducible queries.** A query must mean the same thing regardless of which store answers it. A diff or regression check that depends on the storage backend is not a diff; it's a coin flip.
4. **Swift-native, on-device.** No external service, no network hop, nothing leaving the device. The trace lives where the reasoning lives.

Explicit **non-goals**: distributed collection across machines as a core guarantee, unstructured payload-value diffing, and cross-language support. These aren't oversights — they're scope chosen to keep the guarantees above honest. (Two boundary notes: behavior equivalence testing is available, but uses a formal semantic model via `TraceAlignmentEngine` rather than unstructured payload diffing. And `CloudTraceStore` ([docs/CLOUD.md](docs/CLOUD.md)) is an experimental client-side building block for shipping traces off-device — the guarantees above are still defined on-device, no server ships with this repository, and the hosted team pipeline is a separate commercial layer.)

---

## 2. The event model

An event is anything conforming to `TraceableEvent` (`Codable & Sendable & Equatable`), exposing two things: a `typeIdentifier` and a `priority`.

```swift
public protocol TraceableEvent: Codable, Sendable, Equatable {
    var typeIdentifier: String { get }  // stable across schema versions
    var priority: TracePriority { get }
}
```

The `typeIdentifier` is the stable key that diffing and querying are defined over. It must survive payload refactors and schema bumps, because every structural comparison in the system is expressed in terms of it. Payloads can evolve; identifiers cannot.

Internally an event travels as a generic envelope, `TraceEvent<T>`, carrying the run, context, engine, monotonic `sequence`, optional span lineage, payload, and timestamp. At the storage boundary it is flattened to a type-erased `TraceEventRow` (payload as JSON `Data`). This split is deliberate: the rich generic form gives type-safe construction and querying, while the erased row lets the storage and buffering layers move events around without dragging the generic parameter through every type.

A note on the clocks. Every event carries both a wall-clock `timestamp` and a monotonic per-run `sequence`. **`sequence` is authoritative**; `timestamp` is for display and coarse range filtering only. The reason is in §9 — it's the crux of the worked case study.

---

## 3. Ambient context via `@TaskLocal`

Recording uses no logger handle and no explicit context threading. The current run, engine stack, and span lineage live in task-local storage:

```swift
public enum TraceContext {
    @TaskLocal public static var currentRun: AnyActiveTraceRun?
    @TaskLocal public static var engineStack: [String]
    @TaskLocal public static var currentSpanID: String?
    @TaskLocal public static var parentSpanID: String?
}
```

`@TaskLocal` was chosen because it propagates correctly across `async` boundaries and structured-concurrency child tasks without the caller doing anything. A `withEngine` or `withSpan` scope nested deep inside an async call tree attributes its events correctly, with no parameter passing. The cost is that recording outside a `run` scope has nowhere to go; the design treats that as a **soft no-op** rather than a crash, so instrumentation left in code that runs outside a traced context degrades silently instead of breaking production.

The run handle is type-erased (`AnyActiveTraceRun`) so the task-local can be non-generic while the recording path stays typed — the erasure is re-narrowed at the record call via a checked cast.

---

## 4. The concurrency model — the central tradeoff

This is the decision everything else hangs on.

The obvious modern-Swift choice for the active run and the stores is an `actor`. We deliberately did **not** use one. The stores and the active run are `final class … @unchecked Sendable`, guarding their mutable state with an `NSLock`.

The reason is the non-intrusiveness goal. With an actor, `record(...)` would be `async`: callers would `await` it, the call would hop to the actor's executor, and — critically — an event would only be *durably enqueued* at some later scheduling point. That breaks two properties we want:

- **Immediate queryability.** With the lock-based design, once `record` returns, the event is committed to the in-memory structure and visible to the next query. There is no scheduling gap between "recorded" and "queryable."
- **`flush()` as a true barrier.** Because enqueue is synchronous and ordered, `flush()` is a real happens-before barrier — everything recorded before it is guaranteed persisted after it. With an async enqueue, `flush` could only ever be best-effort.

It also keeps the instrumentation call cheap and non-suspending, so dropping a `record(...)` into hot reasoning code doesn't introduce an `await` or an executor hop into the path being measured.

**What it costs.** `@unchecked Sendable` moves the correctness burden from the compiler to us. The lock discipline is now a property we have to maintain by hand and prove by test, rather than one Swift verifies. The `sequence` counter, the per-run event maps, and the buffer tiers are all hand-synchronized. This is a real, ongoing tax, and it's the first thing a reviewer should scrutinize. We accepted it because the alternative — an async, best-effort recording path — would compromise the system's primary goal. The lock-held critical sections are deliberately tiny and never span an `await`, which is what keeps the tradeoff sound.

---

## 5. The write path — priority-aware backpressure

A reasoning run can emit tens of thousands of events in a burst. The write buffer has to absorb that without unbounded memory growth and without ever paying more than O(1) per event — including when it's full and has to start dropping.

Every event declares one of four priority tiers:

```swift
public enum TracePriority: Int { case telemetry=0, diagnostic=1, structural=2, critical=3 }
```

The buffer holds **one FIFO per tier**. That single structural choice is what makes both ingestion and shedding constant-time: there is never a scan of the backlog to decide what to drop, because the cheapest-to-drop events are already grouped.

- **Enqueue** appends to the tier's FIFO — O(1).
- **Shedding** under global pressure pops the oldest event of the lowest non-empty tier — O(1). The eviction order is `telemetry → diagnostic`, and only if those are exhausted will an incoming `critical` displace the oldest `structural` (or, in extremis, the oldest `critical`). A `structural`/`critical` backlog is never sacrificed to admit a lower-priority event.
- **Per-run softening.** A single run that bursts past its per-run cap sheds *its own* `telemetry`/`diagnostic` first, so one noisy run can't evict the structural events of every other run.

The tier FIFOs are an amortized-O(1) array with a moving head cursor, compacting the dead prefix only once it dominates — so a long run of pops doesn't degrade to O(n) shifts.

Draining for persistence does a **k-way merge across the tiers by insertion stamp**, so even though events were bucketed by priority, they reach the writer in true global insertion order. Bucketing is an internal optimization; it's invisible in the output.

**The contract that makes this safe for analysis:** `telemetry` and `diagnostic` are defined as never affecting diff results, and diffs are floored at `structural` by default (§8). So shedding under load can drop high-volume noise without ever changing a structural diff or a regression verdict. Load-shedding and diff-correctness are decoupled by construction.

**And shedding is never silent.** Every drop is counted by tier in `TraceDropStats`, exposed as `store.dropStats`: an event refused at the door, a bursting run trimmed at its per-run cap, a victim evicted to admit something more important. The bit a caller usually wants is `dropStats.preservedIntegrity` — `true` exactly when nothing `structural` or `critical` was lost, i.e. when a diff over the affected runs is fully trustworthy. This is what turns "we shed under load" from a silent correctness hole into an auditable fact: a consumer can tell "this step truly didn't happen" apart from "this step was shed." `SQLiteTraceStore` extends the same tally to a payload that fails to JSON-encode, and the background writer does the same for a batch `INSERT` that throws and rolls back: those rows were already drained out of the buffer, so each is counted in its priority tier rather than being logged and silently forgotten. A write-time failure therefore surfaces in `dropStats`/`preservedIntegrity` instead of thinning a run behind a clean `preservedIntegrity == true`.

---

## 6. The background writer and durability

A single background actor (`SQLiteWriter`) drains the buffer into SQLite. It is the one place async is welcome, because it's off the recording path.

It **adapts to load** using an exponentially-weighted moving average of buffer depth: under high load it drains in large batches with near-zero sleep; when idle it drains small batches slowly. This keeps latency low under pressure without spinning hot when there's nothing to do.

Persistence is WAL-mode SQLite (`synchronous=NORMAL`, `temp_store=MEMORY`) with a covering set of indices, including the composite `(run_id, sequence)` index that the temporal queries depend on. Run metadata is UPSERTed on a throttle (≈1s) rather than per-event, to avoid write amplification on the `runs` table.

Two durability details worth calling out:

- **Crash reconciliation.** On open, the `runs` table is rebuilt from the persisted `trace_events` for any run whose recorded event count exceeds its last-known metadata — so a process that died mid-run leaves a recoverable trace, not a corrupt one.
- **Structural fingerprint.** Each run carries an incrementally-updated SHA-1 over its `type:engine` signature stream, giving an O(1) "did this run's shape change?" check without re-reading its events.

---

## 7. The query language and its two backends

Queries are built with a fluent DSL that lowers to an AST (`TraceQueryNode`): boolean composition (`and`/`or`/`not`), membership (`containsStep`/`missingStep`), subsequence (`sequence`), and temporal (`after`/`before`).

That one AST is evaluated **two completely different ways**:

- **In memory** (`InMemoryTraceStore`): the AST is interpreted directly over the run's `sequence`-ordered event list. Queries first narrow candidates through inverted indices (by context, engine, and event type), then run the full predicate only on survivors.
- **On disk** (`SQLiteTraceStore`): the AST is compiled to SQL, with boolean composition expressed as `INTERSECT`/`UNION`/`EXCEPT` over per-clause `SELECT run_id` subqueries.

Two implementations of one language is a powerful pattern — and a dangerous one. It is the single largest correctness risk in the system, and §9 is about the time it bit us.

---

## 8. The diff engine

Diffing reduces each run to a sequence of **structural signatures** — `typeIdentifier::engineName` — filtered to a minimum priority (default `.structural`), then runs the standard-library `CollectionDifference` (a Myers diff) over the two signature streams. Reordered, inserted, and removed reasoning steps fall out as `added`/`removed` changes carrying their original `sequence` for traceability.

The deliberate limitation of `TraceDiffEngine`: signatures are **structure only**. Two runs that took the same step types in the same order diff as identical even if their payload *values* differ wildly. The structural diff answers "did the reasoning *path* change?", not "did the reasoning *content* change?".

To answer content changes, DProvenanceKit provides `TraceAlignmentEngine`. Instead of a blind Myers diff on payload strings, the alignment engine determines whether two executions are behaviorally equivalent within a formally defined semantic model, executing a weighted comparison across event types, parent spans, temporal locality, and a provided `AnyEquivalenceEvaluator` for payloads.

---

## 9. Case study — the query-backend parity bug

This is the most instructive bug in the project's history, because it's the canonical failure mode of the two-backend design in §7, and because catching it well says more about the engineering discipline than any green test suite.

**The setup.** The in-memory evaluator and the SQL compiler are independent implementations of the same query language. For them to be trustworthy, they must agree on every input. They didn't.

**The bug.** The temporal operators (`after`, `before`, `sequence`) were compiled to SQL that ordered events by `timestamp`:

```sql
-- old .sequence: chain by wall-clock time
... WHERE e0.type=? AND e1.type=? AND e0.timestamp < e1.timestamp
```

But the in-memory evaluator orders by `sequence`, the monotonic causal counter. Mixing two ordering authorities produced two distinct divergences:

1. **False negatives from timestamp ties.** Events recorded in a tight burst can share a wall-clock timestamp to the microsecond. A strict `timestamp < timestamp` chain then finds no increasing path and reports *no match*, while the in-memory evaluator — ordering by the always-distinct `sequence` — correctly finds the subsequence. Verified directly against SQLite: three back-to-back events with a tied timestamp made the SQL `.sequence` return nothing where the truth is a match.

2. **False positives from "any" vs "first" occurrence.** The in-memory `.before(step, precededBy)` anchors to the *first* occurrence of `step` (`firstIndex(of:)`). The SQL matched "*any* `step` that has *some* earlier `precededBy`." On the trace `[errorDetected, stepCompleted, errorDetected]`, asking "did `stepCompleted` precede the first `errorDetected`?" the in-memory answer is **no** — but the old SQL said **yes**, via the second `errorDetected`. Two backends, opposite answers, same data.

**The fix.** Two corrections, both small once the cause was named:

- Order all temporal operators by `sequence`, not `timestamp`. `sequence` is strictly monotonic per run, so ties are impossible and the wall-clock divergence disappears. The `(run_id, sequence)` index already backed it.
- Anchor `.after`/`.before` to `MIN(sequence)` of the step, mirroring the in-memory "first occurrence" semantics exactly:

```sql
-- new .before: precededBy strictly before the FIRST step occurrence
SELECT DISTINCT e.run_id FROM trace_events e
JOIN (SELECT run_id, MIN(sequence) AS anchor FROM trace_events WHERE type=? GROUP BY run_id) a
  ON e.run_id = a.run_id
WHERE e.type=? AND e.sequence < a.anchor
```

**The discipline that now prevents recurrence.** A fix isn't done when the bug is gone; it's done when the bug can't silently return. The real deliverable was a **parity test suite** that runs identical scenarios through *both* stores and asserts identical results:

```swift
let (memory, sqlite) = try await matches(scenario: …, query: …)
XCTAssertEqual(memory, sqlite)  // a query means one thing, everywhere
```

The dedicated regression test fails on the old compiler and passes on the new one; a broader matrix runs every operator through both backends as a standing guard.

**The general lesson, stated plainly:** when you maintain two implementations of one specification, (a) the specification must be pinned by a *differential* test that exercises both against each other, not two separate test suites that can drift; and (b) any ordering-dependent semantics must commit to a single authoritative clock. We had violated both. The architecture is sound — but soundness at the macro level doesn't exempt you from getting the semantics exactly right at the seams, and the seams are where two-backend designs fail.

---

## 10. Known limitations and open questions

Stated plainly, because a design doc that only lists strengths isn't a design doc:

- **Apple-only by dependency.** System SQLite and CryptoKit tie the library to Apple OSes. This is consistent with the on-device-AI goal, but it's a hard scope boundary, not an accident.
- **The live engine's delivery stream is unbounded**, which sits in tension with the carefully bounded backpressure on the write path; a slow live consumer can grow memory.
- **The lock-based concurrency model** (§4) is correct but compiler-unverified. An actor-based redesign would get checked guarantees at the cost of the synchronous-record property — a tradeoff worth revisiting if Swift's concurrency tools make a synchronous, ordered, actor-backed enqueue expressible.

None of these are foundational. They're the difference between "well-architected experimental engine" and "load-bearing dependency," and they're the right next things to close.
