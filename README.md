# DProvenanceKit

**Reasoning observability and regression testing for AI systems — Swift-native, built for on-device and Apple-platform AI.**

When an agent's reasoning drifts between runs, DProvenanceKit turns each execution into a queryable, diffable trace so you can see *what changed and why* — not just *what happened*.

> Run → Record → Query → Diff → Detect Regressions

[![Swift 6](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org)
[![Platform: macOS | iOS](https://img.shields.io/badge/Platform-macOS%20%7C%20iOS-lightgrey.svg)](https://swift.org)
[![License: BSL 1.1](https://img.shields.io/badge/License-BSL_1.1-blue.svg)](https://github.com/Therealdk8890/DProvenanceKit/blob/main/COMMERCIAL.md)

---

## Who this is for

If you're building AI in Swift — agents, LLM workflows, tool-using models, or reasoning that runs **on-device** with Apple Foundation Models, MLX, or Core ML — the observability ecosystem has mostly passed you by. LangSmith, Langfuse, Phoenix, OpenTelemetry: Python- and JS-first, built around requests crossing a network.

DProvenanceKit works at the reasoning layer, in your language, with no service to stand up and nothing leaving the device. If your reasoning happens in Swift, this is built for you.

---

## AI systems don't fail like traditional software

Traditional software crashes. AI systems often don't — they fail quietly:

- Agents silently skip steps
- Reasoning order changes between runs
- The same input takes a different path
- Outputs change with no obvious explanation
- Logs show *what happened*, but not *why*

DProvenanceKit makes those changes visible, queryable, and comparable.

## Questions you can finally answer

- Why did the model approve Case A but reject Case B?
- Which reasoning step disappeared after a model upgrade?
- When did this regression first appear?
- Which agent skipped validation?
- Why are two supposedly identical runs producing different results?

```swift
let diff = engine.diff(base: runA, comparison: runB)
```

## Isn't this just OpenTelemetry?

OpenTelemetry answers **what happened** — request tracing, latency, service health, infrastructure monitoring.

DProvenanceKit answers **why the AI reached this conclusion** — decision lineage, logic diffs, regression detection, execution auditing.

> OpenTelemetry traces requests. DProvenanceKit traces reasoning.

## Git for AI logic

Instead of diffing two walls of logs:

```
Run A                    Run B
 ├─ evaluateDocuments     ├─ evaluateDocuments
 ├─ applyHeuristic        └─ detectConflict
 └─ detectConflict

Missing in Run B:
 - applyHeuristic
```

You compare reasoning paths directly.

---

# 5-minute demo

### 1. Record an execution run

```swift
try await DProvenanceKit<MyAIDecision>.run(
    contextID: "demo_case",
    store: store
) {
    DProvenanceKit<MyAIDecision>.record(.documentEvaluated(documentID: "DocA", score: 0.95))
    DProvenanceKit<MyAIDecision>.record(.conflictDetected(reason: "timeline_inconsistency"))
    DProvenanceKit<MyAIDecision>.record(.finalDecisionMade(approved: false))
}
```

### 2. Query reasoning patterns

```swift
let suspiciousRuns = try await store.queryRuns(
    TraceQueryDSL<MyAIDecision>()
        .requiring(step: "conflictDetected")
        .missing(step: "documentEvaluated")
)
```

Find runs where a conflict was reported but no document was ever evaluated.

### 3. Diff runs

```swift
let engine = TraceDiffEngine<MyAIDecision>()
let diff = engine.diff(base: runA, comparison: runB)
print(diff.changes)
```

See exactly which structural reasoning steps appeared, disappeared, or moved.

### 4. Semantic Alignment

For a deeper inspection, `TraceAlignmentEngine` lets you determine if two executions are behaviorally equivalent within a formally defined semantic model, even if the exact payloads vary slightly.

```swift
let config = AlignmentConfiguration(
    profile: .strictAuditV1,
    equivalenceEvaluator: AnyEquivalenceEvaluator(identifier: "MyAIDecision_Semantic") { a, b in
        // Define your formal semantic model for equivalence here
        // E.g., fuzzy matching token counts or semantic similarity of prompt inputs
        return a == b ? 1.0 : 0.0
    }
)

let aligner = TraceAlignmentEngine(configuration: config)
let alignment = aligner.align(base: runA, comparison: runB)
print(alignment.regressionRisk.level)
```

Compare runs across both structural shape and payload semantics to catch subtle regressions.

### 5. Detect regressions automatically

```swift
let detector = AnomalyDetector(store: store)
let anomalies = try await detector.detectAnomalies(rules: [UnverifiedConflictRule()])
```

```
🚨 Conflict detected
🚨 No supporting heuristic found
🚨 Potential reasoning regression
```

---

# Validation & Benchmarks

**Each configuration defines a distinct equivalence relation over the space of execution traces, corresponding to a specific observation model.** The benchmark corpus evaluates the engine's ability to distinguish genuine regressions from meaning-preserving evolution within a specific semantic profile.

Current Corpus:
- 8 scenarios (including reordering, semantic evolution, noise injection, and branch collapse)
- Precision: 1.000
- Recall: 1.000
- F1: 1.000

See [BENCHMARKS.md](BENCHMARKS.md) for dataset definitions, evaluation methodology, confusion matrices, runtime analysis, and benchmark corpus details.

---

# How it really works

The surface API is small on purpose; the engineering is in keeping it correct and non-intrusive under real load.

**Recording never blocks execution.** `record(...)` is synchronous and touches only an in-memory buffer — it never waits on disk. A background writer drains the buffer in batches into WAL-mode SQLite, adapting batch size and cadence to load. Because the in-memory commit is synchronous, an event is queryable the instant `record` returns, and `flush()` is a true barrier rather than a best-effort hint.

**Backpressure is priority-aware and O(1).** Reasoning systems can emit enormous bursts. Each event declares a priority — `critical`, `structural`, `diagnostic`, `telemetry` — and the write buffer holds one FIFO per tier. Both ingestion and load-shedding stay constant-time even at the moment a burst pins the buffer at capacity: there's no scan of the backlog. Under pressure, `telemetry` and `diagnostic` are shed first; `structural` and `critical` are preserved. Diffs are floored at `structural` by default, so shedding low-priority events never changes a diff result. And shedding is never silent: every dropped event is tallied by tier, so `store.dropStats.preservedIntegrity` answers *"did this run lose anything a diff depends on?"* — and a payload that fails to encode is counted the same way, not dropped quietly.

**Durable and crash-safe.** Writes land in WAL-mode SQLite with sensible pragmas and a covering set of indices. If a process dies mid-run, the `runs` table is reconciled from the persisted events on next open, so an interrupted run is rebuilt rather than lost. Each run also carries an incrementally computed structural fingerprint for fast "did this run's shape change?" checks.

**Ambient context, no plumbing.** Run, engine, and span context propagate through Swift's `@TaskLocal` storage, so nested `withEngine` / `withSpan` scopes attribute events correctly across `async` boundaries without threading a logger through every call.

**One query language, two backends, kept honest.** `TraceQueryDSL` compiles to an in-memory AST evaluator (for `InMemoryTraceStore`) and to SQL (for `SQLiteTraceStore`). Those are two independent implementations of the same semantics, so they're held in lockstep by a parity test suite that runs identical scenarios through both stores and asserts identical results — temporal operators included. A query means the same thing wherever it runs.

The full rationale — the concurrency tradeoff, the query-parity bug that drove the two-backend parity suite, and the known limitations — lives in **[DESIGN.md](DESIGN.md)**.

---

# Getting started

### Installation

Add DProvenanceKit to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Therealdk8890/DProvenanceKit.git", branch: "main")
]
```

### 1. Define your events

Any `enum` or `struct` that conforms to `TraceableEvent`. `typeIdentifier` must be stable across schema versions; `priority` controls survival under load.

```swift
import DProvenanceKit

enum MyAIDecision: TraceableEvent {
    case promptGenerated(tokenCount: Int)
    case documentEvaluated(documentID: String, score: Double)
    case conflictDetected(reason: String)
    case finalDecisionMade(approved: Bool)

    var typeIdentifier: String {
        switch self {
        case .promptGenerated:   return "promptGenerated"
        case .documentEvaluated: return "documentEvaluated"
        case .conflictDetected:  return "conflictDetected"
        case .finalDecisionMade: return "finalDecisionMade"
        }
    }

    var priority: TracePriority {
        switch self {
        case .promptGenerated, .documentEvaluated: return .telemetry
        case .conflictDetected:                    return .diagnostic
        case .finalDecisionMade:                   return .critical
        }
    }
}
```

### 2. Configure a store

```swift
let store = try SQLiteTraceStore<MyAIDecision>(
    fileURL: URL(fileURLWithPath: "/path/to/traces.sqlite")
)
```

`SQLiteTraceStore` buffers writes in memory and persists asynchronously over WAL-mode SQLite, so recording never blocks execution. Use `InMemoryTraceStore` for tests and ephemeral runs.

### 3. Record runs

```swift
try await DProvenanceKit<MyAIDecision>.run(contextID: "Case-12345", store: store) {

    DProvenanceKit<MyAIDecision>.record(.promptGenerated(tokenCount: 150))

    try await DProvenanceKit<MyAIDecision>.withEngine(name: "DocumentAnalyzer") {
        DProvenanceKit<MyAIDecision>.record(.documentEvaluated(documentID: "DocA", score: 0.95))
    }

    DProvenanceKit<MyAIDecision>.record(.finalDecisionMade(approved: true))
}
```

---

# Architecture

```
Trace Event Stream → Trace Store → Query Engine → Diff / Anomaly Detection
```

| Component            | Role                                                              |
| -------------------- | ----------------------------------------------------------------- |
| `SQLiteTraceStore`   | Non-blocking writes, WAL-mode persistence, background batching     |
| `InMemoryTraceStore` | Fast local execution, indexed queries, optional live evaluation    |
| Query Engine         | Reasoning-pattern search, missing-step and temporal detection      |
| Diff Engine          | Structural reasoning diffs and path comparison                     |
| Anomaly Detection    | Rule-based validation and regression discovery                     |

---

# Status

**Experimental — core engine complete, actively evolving.**

**Working today:** recording, querying (including temporal and sequence operators), structural diffing, semantic alignment (behavioral equivalence), rule-based anomaly and regression detection, both stores at parity, and by-tier drop accounting (`dropStats` / `preservedIntegrity`) so load-shedding is never silent.

**Planned:** counting events lost to a failed batch insert, richer visualization, distributed trace federation.

**Scope:** Apple platforms (macOS / iOS). The library depends on system SQLite and CryptoKit, so it targets Apple OSes rather than Linux — by design, since the goal is reasoning observability for Swift and on-device AI.

---

# Commercial & team use

The library and the **Lineage** trace viewer are free to build with. If you're running DProvenanceKit in production — or want a **team version**: traces shared across machines and CI, a regression gate that fails a pull request when reasoning drifts, and production monitoring — reach out: **[therealdk8890+lineage@gmail.com](mailto:therealdk8890+lineage@gmail.com)**.

---

# License

DProvenanceKit is distributed under the **Business Source License 1.1**: free for development, testing, and non-production use, with limited production use under the Additional Use Grant. It converts to Apache 2.0 on June 16, 2030. Commercial production use and licensing options are described in [COMMERCIAL.md](https://github.com/Therealdk8890/DProvenanceKit/blob/main/COMMERCIAL.md).
