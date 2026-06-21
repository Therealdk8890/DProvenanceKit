# DProvenanceKit — Design Notes

This document explains *why* the library is built the way it is. The README tells you
what it does; this tells you the judgment calls behind it, because those are the part
worth reviewing. Every claim below names the file, symbol, or test that backs it, so
you can check the work rather than take my word for it.

The whole library is organized around one stance:

> **Causal order is the source of truth; wall-clock time is a lossy approximation of it.**

A trace exists to answer "what did this system decide, in what order, and how does that
differ from last time." Those are questions about *causal* order — the order operations
actually happened in — not about wall-clock timestamps, which tie at microsecond
resolution and can even run backwards under clock adjustment. Most of the interesting
design decisions fall out of taking that stance seriously and refusing to let wall-clock
time sneak back in as the authority.

A second, quieter stance runs underneath: **integrity has to be observable, not
asserted.** A diff tool that says "these two runs are identical" is only useful if you
can trust that it actually saw everything. So wherever the system can lose data — under
load, across a backend boundary — it is built to either not lose it, or to tell you
exactly what it lost.

---

## 1. Synchronous recording, over an actor

**The decision.** `record()` is synchronous and lock-backed, not an `async` call into
an actor.

**The obvious alternative.** In Swift concurrency, the textbook way to build a
concurrent write buffer is an `actor`. It gives you data-race safety for free. But it
forces a choice at the call site, and both options are bad:

- Make `record()` `async`. Now every place that records a reasoning step has to be in
  an async context and `await` it. Tracing has colonized your call graph, and you can't
  trace inside synchronous reasoning code at all.
- Fire-and-forget into the actor from a detached `Task`. Now `record()` returns before
  the event is committed, so you have lost ordering (two records can land in either
  order depending on scheduling) and you have lost any happens-before relationship
  between recording and flushing.

**What synchronous recording buys.** `TraceWriteBuffer.enqueue` and
`InMemoryTraceStore.record` are guarded by an `NSLock`, and the event is committed
*before the call returns* (`TraceWriteBuffer.swift`, `enqueue`). Three properties follow:

1. **`flush()` is a true barrier.** Because every `record` that happened-before a
   `flush` has already committed, `flush` cannot observe a half-written run. This is a
   structural guarantee, not a timing accident. Proven by
   `SQLiteStressTests.testFlushIsBarrierAndPreservesRecordOrder`: after a 500-event run,
   an immediate flush + query sees all 500, with sequence numbers contiguous `0..<500`.

2. **Order is deterministic.** Each event gets a monotonic `sequence` assigned under a
   lock at the moment of recording (`DProvenanceKit.ActiveTraceRun.record`,
   `sequenceLock`). Concurrent recorders are serialized at that point, so the sequence
   is the real causal order. The buffer then preserves it on the way out (see §2).

3. **No async coloring.** You can record from synchronous code. Tracing does not change
   the shape of the code being traced.

**The cost, stated honestly.** A lock sits on the hot path, so there is contention under
extreme concurrency, and you cannot `await` while holding it. That second constraint is
actually a design constraint that keeps the system honest: the critical section is pure
O(1) bookkeeping. The expensive work is split out — payload encoding happens *before*
the lock is taken (`SQLiteTraceStore.record`), and persistence happens *after*, on a
background `SQLiteWriter` actor that batches inserts. So the split is the point:
**a lock for ordering, an actor for I/O.** The fast thing is synchronous; the slow thing
is asynchronous; neither borrows the other's weakness.

---

## 2. O(1) load-shedding under burst

**The decision.** Congestion control is priority-bucketed: one FIFO per priority tier,
so both admitting an event and shedding one are O(1) — with no scan of the backlog,
ever.

**The obvious alternative, and why it's pathological.** Put everything in one queue.
When you're over capacity and need to drop the least important event, scan the queue for
the lowest-priority victim. That's O(n) per drop — and you pay it precisely when `n` is
at its maximum and you are already failing to keep up. The cost of shedding load grows
with the load you're shedding. Under a real burst that is a feedback loop into collapse.

**The structure** (`TraceWriteBuffer`, `TracePriority`):

- Four FIFOs, one per tier (`telemetry`, `diagnostic`, `structural`, `critical`).
- **Admit** = append to that tier's FIFO. O(1).
- **Shed** = pop the head of the lowest non-empty tier. O(1) (`evictOneLocked` →
  `popVictimLocked`). No search.
- **Drain** for persistence = a k-way merge across the four tier-heads by insertion
  stamp (`drainLocked`). k is a constant (4), so this is still linear in the events
  drained, and it hands events to the writer in **global insertion order** — which is
  what keeps the writer's streaming run-fingerprint computed in record order.
- The FIFO itself is amortized O(1): a plain array with a moving head cursor that only
  compacts when the dead prefix dominates (`FIFOQueue`). No per-pop shifting.

**The shedding policy is the integrity invariant.** Tiers are defined so that telemetry
and diagnostic events *can never change a structural diff* (`TracePriority` doc
comments). Eviction always sheds those first and preserves `structural`/`critical`. The
only time a critical event is displaced is when the buffer is *entirely* critical and a
newer critical arrives — saturation of last resort, where keeping the newest is the
least-bad option.

**Why you can trust that invariant: the drop counter (`TraceDropStats`).** This is the
difference between "impressive" and "trustworthy." Shedding silently would be a
correctness hole disguised as a performance feature: you compare two runs, see no
difference, and conclude they're identical — when in fact the distinguishing event was
quietly dropped under load. So every drop, at all three drop sites (incoming refused by
the per-run cap; incoming refused by the global cap; a buffered event evicted to make
room), is counted by tier. A consumer asks one question —
`store.dropStats.preservedIntegrity` — and gets back whether anything that could change
a diff was lost.

Proven by:
- `TraceWriteBufferTests.testGlobalEvictionIsCounted` and
  `testPerRunSoftCapKeepsCriticalEvents`: a conservation law holds —
  `admitted + dropped == enqueued`, so nothing vanishes unaccounted for — and every drop
  is telemetry, never structural/critical.
- `SQLiteStressTests.testBurstIngestionCollapse`: under a burst that overflows a small
  buffer, the critical events survive, `dropStats.telemetry > 0`, and
  `dropStats.preservedIntegrity` is `true`. That last assertion is the load-bearing one.

---

## 3. Two backends, one truth — a parity bug worth studying

This is the sharpest example of the library's central stance, because it's where I got
it wrong first and the test caught it.

**The shape.** There is one query language — an AST (`TraceQueryNode`) built by a fluent
DSL (`TraceQueryDSL`) — and two backends that must answer identically:

- **In-memory** interprets the AST by walking a run's events
  (`TraceQueryNode.evaluate`).
- **SQLite** compiles the AST to SQL and lets the database answer
  (`TraceQueryCompiler`).

Two implementations of one specification. The standard risk with that arrangement is
that they drift. They did.

**The bug.** The temporal operators — `after`, `before`, `sequence` — need an *ordering
authority*: when is event B "after" event A? The two backends disagreed on the answer:

- The in-memory backend ordered events by **`sequence`**, the monotonic causal clock.
  (`InMemoryTraceStore.makeRunLocked` sorts by `sequence`, with a comment noting wall-
  clock timestamps "can tie at microsecond resolution.")
- The SQL compiler ordered them by **`timestamp`** — wall-clock —
  `WHERE e2.timestamp > e1.timestamp`.

Same AST. Two different definitions of "after."

**When it bites.** Timestamps are `Date()` captured at microsecond resolution. Under the
exact bursts this library is built to survive:

- two events land in the **same microsecond** (a tie), or
- a clock adjustment puts a causally-later event at an **earlier** wall-clock time (an
  inversion).

In both cases the SQL comparison `e2.timestamp > e1.timestamp` disagrees with the
in-memory sequence comparison. **The same query returns different runs depending on which
backend you happen to be using** — and which answer is "right" depends on invisible
sub-microsecond timing.

**Why this is worse than an ordinary bug.** The product *is* a query-and-diff tool. Two
backends that disagree on the same question aren't "mostly correct" — they're a tool
that is confidently, silently wrong, where the wrongness is invisible and non-
deterministic. That is the precise opposite of the one thing the tool is supposed to
sell: a trustworthy answer to "did this change?"

**How it was caught: a differential parity test** (`QueryParityTests`). It records the
*same* scenario into a fresh in-memory store and a fresh SQLite store, runs each query
against both, and asserts they return the same runs. The sharpest case it pins is
`.before` over `[errorDetected, stepCompleted, errorDetected]`: `stepCompleted` sits
*between* the two `errorDetected` events, so it does not precede the *first* one — both
backends must report no match. The old timestamp-ordered SQL matched it anyway (via the
second `errorDetected`), diverging from the in-memory evaluator. A second case drives
`.sequence` through a tight burst where events can share a timestamp, and an
operator-parity matrix runs every operator over one shared scenario as a broad guard
against drift. Agreement alone isn't enough — two backends can agree on a wrong answer —
so the pointed cases also pin the causally-correct result, not just backend equality.

These tests fail on the old timestamp-ordered compiler and pass once the ordering
authority is unified. A regression test that you have watched fail is worth ten that you
have only watched pass.

**The fix.** Make `sequence` the single ordering authority everywhere. The compiler now
orders every temporal operator by `sequence` instead of `timestamp`: `after` and
`before` anchor to the *first* occurrence of `step` via `MIN(sequence)` — mirroring the
in-memory evaluator's `firstIndex(of:)` — and `sequence` chains its self-joins on
strictly increasing `sequence`. Because `sequence` is unique and monotonic within a run,
there are no ties, no inversions, and no ambiguity about *which* occurrence anchors the
comparison: the two backends now provably evaluate the same order. `timestamp` is
relegated to what it's actually good for — display and coarse range filtering, never
adjudicating causal order.

**The transferable lesson.** When one specification has two implementations, two things
are non-negotiable: a differential test that pins them to each other, and a single
source of truth for *every* semantic dimension. Ordering is such a dimension. The bug
was having two sources of truth for it; the fix was having one; the test is what makes
"one" enforceable going forward.

---

## Integrity guarantees, and what proves each

| Guarantee | Mechanism | Proof |
|---|---|---|
| A flush sees every event recorded before it | synchronous `record` + lock | `testFlushIsBarrierAndPreservesRecordOrder` |
| Recorded order is preserved end to end | per-record `sequence` + k-way merge drain | `testDrainPreservesGlobalInsertionOrder` |
| Both query backends answer identically | unified `sequence` ordering authority | `QueryParityTests` (verified failing pre-fix) |
| Load-shedding never drops what a diff needs | priority tiers + eviction policy | `testBurstIngestionCollapse`, `testHeavyBurstShedsTelemetryButKeepsCritical` |
| No event is ever lost silently | `TraceDropStats` at all 3 drop sites | `testGlobalEvictionIsCounted`, `testPerRunSoftCapKeepsCriticalEvents` |

---

## Scope: what this is, and what it is not

**What it is.** A small, embeddable Swift library for recording, querying, and diffing
the *reasoning steps* of AI systems — designed to run on-device, with no server, no
network, and no daemon. The persistent store is a single WAL-mode SQLite file. You can
read the whole codebase in a sitting, audit exactly what it records, and embed it
without taking on a platform dependency.

**What it is not, and what to use instead.** This is not a distributed tracing system or
an APM, and it is not trying to be.

- If you need cross-service spans, fleet-scale sampling, and an ecosystem of exporters —
  that's **OpenTelemetry**. It traces requests across a distributed system. DProvenanceKit
  traces reasoning within one process.
- If you want a hosted product with a web UI, dashboards, and team features for LLM
  observability — that's **LangSmith** or similar. DProvenanceKit has no backend to host;
  the data stays on the device.

The earlier framing of this project argued *against* OpenTelemetry rhetorically. That was
a mistake: it invites a comparison on OTel's home turf (scale, ecosystem) that a small
library will always lose, and it obscures where this design actually wins.

**The lane, claimed plainly.** On-device and embedded AI — a Swift app running a model
locally, an agent inside a macOS/iOS application — where you want a queryable, diffable,
causally-ordered record of what the model decided, and you want that record to stay on
the device. In that lane, smallness is the feature, not an apology: no infra to stand up,
nothing to trust but a file you can read, and a diff you can rely on because the
integrity is observable.

---

## Known limitations

These are real and worth knowing before you adopt it.

- **Diffs are structural, not value-aware.** `TraceDiffEngine` compares event type,
  engine, and causal order. Two runs that take the same steps with different *payload
  values* currently diff as identical. Payload-aware diffing is the main planned
  extension.
- **Payload encoding must produce a JSON object.** `SQLiteTraceStore.record` encodes
  payloads with `JSONEncoder` and currently drops an event whose payload fails to encode.
  A `String`-raw-value enum encodes as a top-level JSON *fragment*, which fails — so such
  an event type would silently vanish from the SQLite store while still working in the
  in-memory store. Use a struct or an enum with associated values (encodes as an object).
  This is a known sharp edge; closing it (count or surface these as drops, rather than
  swallowing them) is the obvious next integrity item.
- **Single process, single file.** No federation, no multi-writer coordination beyond
  one process's buffer + writer.
- **`structural`/`critical` can still be shed at true saturation.** The per-run and
  global caps preserve them as long as anything cheaper exists to drop. If a buffer is
  *entirely* critical and overflowing, the oldest critical is displaced — and counted, so
  you will see it in `dropStats`.
