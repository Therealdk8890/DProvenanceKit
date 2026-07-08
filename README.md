# DProvenanceKit

**Reasoning observability and regression testing for AI systems — Swift-native, built for on-device and Apple-platform AI.**

When an agent's reasoning drifts between runs, DProvenanceKit turns each execution into a queryable, diffable trace so you can see *what changed and why* — not just *what happened*.

> Run → Record → Query → Diff → Detect Regressions

[![CI](https://github.com/Therealdk8890/DProvenanceKit/actions/workflows/ci.yml/badge.svg)](https://github.com/Therealdk8890/DProvenanceKit/actions/workflows/ci.yml)
[![Swift Versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FTherealdk8890%2FDProvenanceKit%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/Therealdk8890/DProvenanceKit)
[![Platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FTherealdk8890%2FDProvenanceKit%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/Therealdk8890/DProvenanceKit)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://github.com/Therealdk8890/DProvenanceKit/blob/main/LICENSE)

---

## See a regression in 30 seconds

Your on-device agent shipped fine. Then an OS/model update landed and it *quietly* stopped calling a tool — no crash, no error, just a fluent wrong answer. Here's the reasoning trace, before vs. after:

```diff
  instructions
  prompt        "What's the weather in Paris right now?"
- tool call     getWeather            ← silently dropped after the update
- tool output   getWeather
~ response      "14°C, light rain"  →  "sunny and 22°C"   (made up)
```

DProvenanceKit diffs the two runs, flags the dropped **critical** step, and **fails your CI build**:

```
Regression risk:  HIGH — Critical reasoning steps removed: tool call
CI gate:          ❌ FAILED — reasoning regression detected
```

Run the whole thing yourself — no live model required:

```sh
swift run FoundationModelsRegressionDemo --gate
```

**Your agent changed behavior, and now you know exactly why.** Full walkthrough: **[Catching a Foundation Models regression](docs/foundation-models-regression-demo.md)**.

---

## Who this is for

If you're building AI in Swift — agents, LLM workflows, tool-using models, or reasoning that runs **on-device** with Apple Foundation Models, MLX, or Core ML — the observability ecosystem has mostly passed you by. LangSmith, Langfuse, Phoenix, OpenTelemetry: Python- and JS-first, built around requests crossing a network.

DProvenanceKit works at the reasoning layer, in your language, with no service to stand up and nothing leaving the device. If your reasoning happens in Swift, this is built for you — and if it happens in Apple's Foundation Models, tracing it is [one line](docs/foundation-models.md).

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

And when you need both: **[DProvenanceOTel](docs/otel-bridge.md)** exports finished runs as standard OTLP spans — DPK stays the on-device capture layer, and reasoning traces flow to Langfuse or any OTLP/HTTP collector for the dashboards your team already watches. Export, not equivalence.

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

Query by the *content* of reasoning, not just which steps ran — e.g. runs where a document scored below 0.5:

```swift
let lowConfidence = try await store.queryRuns(
    TraceQueryDSL<MyAIDecision>().matching(step: "documentEvaluated") {
        if case .documentEvaluated(_, let score) = $0 { return score < 0.5 }
        return false
    }
)
```

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

// Batteries-included rule: flag any run that detected a conflict but never
// evaluated a document to support it. Or conform your own type to `AnomalyRule`.
let rule = MissingSupportRule<MyAIDecision>(
    name: "UnsupportedConflict",
    whenPresent: "conflictDetected",
    isMissing: "documentEvaluated"
)
let anomalies = try await detector.detectAnomalies(rules: [rule])
```

```
🚨 Conflict detected
🚨 No supporting heuristic found
🚨 Potential reasoning regression
```

### 6. Trace a decision's lineage

Record what each step was derived from, and the causal graph builds itself — then ask *why* a conclusion was reached.

```swift
let doc = DProvenanceKit<MyAIDecision>.record(.documentEvaluated(documentID: "DocA", score: 0.95))
let decision = DProvenanceKit<MyAIDecision>.record(.finalDecisionMade(approved: false), derivedFrom: doc!)

let why = try await store.explain(id: decision!)   // what this decision was derived from
let downstream = try await store.impact(of: doc!)   // everything DocA's evaluation influenced
```

`record(_:derivedFrom:)` wires the edge as you record, so `lineage`, `impact`, and `explain` work without manual bookkeeping.

---

# Validation & Benchmarks

**Each configuration defines a distinct equivalence relation over the space of execution traces, corresponding to a specific observation model.** The benchmark corpus evaluates the engine's ability to distinguish genuine regressions from meaning-preserving evolution within a specific semantic profile.

Current Corpus:
- 8 scenarios (including reordering, semantic evolution, noise injection, and branch collapse)
- Precision: 1.000
- Recall: 1.000
- F1: 1.000

> These are **conformance benchmarks over a curated set of known failure modes** — evidence the engine behaves correctly on the regressions it's designed to catch, not a claim that it detects *every possible* reasoning regression. The perfect scores reflect a controlled diagnostic corpus, not statistical generalization to arbitrary traces.

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
    .package(url: "https://github.com/Therealdk8890/DProvenanceKit.git", from: "0.2.0")
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

### 4. Trace an Apple Foundation Models session

If your AI is Apple's on-device LLM, skip the custom vocabulary — the adapter ships one, frozen and diff-ready:

```swift
import DProvenanceFoundationModels

let fmStore = try SQLiteTraceStore<FoundationModelTraceEvent>(
    fileURL: URL(fileURLWithPath: "traces.sqlite")
)

try await FMTrace.run(contextID: "onboarding-chat", store: fmStore) {
    let session = LanguageModelSession.traced(instructions: "Be terse.")
    _ = try await session.respond(to: "Plan my day.")
}
```

Every prompt, response, tool call, and generation error is now a queryable trace event. Already have working FoundationModels code? `session.recordProvenance()` ingests the transcript after the fact — zero refactor. Full guide, including redaction and streaming: **[docs/foundation-models.md](docs/foundation-models.md)**.

> **See it catch a real regression:** `swift run FoundationModelsRegressionDemo` — an agent that silently stops calling its tool after a model update, caught as a `HIGH`-risk regression and failed in CI. [Walkthrough →](docs/foundation-models-regression-demo.md)

### 5. Export to Langfuse or any OTLP backend

```swift
import DProvenanceOTel

let exporter = OTLPHTTPExporter<MyAIDecision>(
    configuration: .langfuse(publicKey: "pk-lf-...", secretKey: "sk-lf-...")
)
let receipt = try await DProvenanceOTelExport.export(from: store, using: exporter)
```

One run becomes one OTel trace, deterministically — same run, same trace ID, every export. Backend matrix and mapping details: **[docs/otel-bridge.md](docs/otel-bridge.md)**.

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
| `DProvenanceFoundationModels` | Drop-in tracing for Apple Foundation Models sessions and tools |
| `DProvenanceOTel`    | Deterministic OTLP/JSON export to Langfuse and OTLP/HTTP collectors |

---

# Documentation

| Guide | What's inside |
| ----- | ------------- |
| [Foundation Models integration](docs/foundation-models.md) | Trace Apple's on-device LLM: live sessions, post-hoc transcripts, traced tools, redaction policy |
| [OpenTelemetry bridge](docs/otel-bridge.md) | Export runs as OTLP spans to Langfuse or any OTLP/HTTP collector |
| [Trace replay](docs/REPLAY.md) | Reconstruct a run's span tree as of any point in time, with integrity manifests |
| [Snapshot diffing](docs/SNAPSHOTS.md) | Diff two replay states: span changes, event changes, the exact divergence point |
| [Live queries](docs/LIVE_QUERIES.md) | Register a query once, get a callback the moment a run starts matching |
| [Cloud ingestion (experimental)](docs/CLOUD.md) | Buffered, offline-first HTTP trace shipping with drop accounting |
| [Trace inspector UI](docs/UI.md) | Drop-in SwiftUI viewer for macOS: run list, timeline scrubber, diff overlay |
| [DESIGN.md](DESIGN.md) | Engine internals: the concurrency tradeoff, backpressure, durability, known limitations |
| [SEMANTICS.md](SEMANTICS.md) | The formal semantic model behind alignment and behavioral equivalence |
| [BENCHMARKS.md](BENCHMARKS.md) | Benchmark corpus, evaluation methodology, confusion matrices |
| [Alignment validation walkthrough](walkthrough.md) | Case study: validating the alignment engine against the corpus |

---

# Status

**Experimental — core engine complete, actively evolving.**

**Working today:** recording, querying (including temporal and sequence operators), structural diffing, semantic alignment (behavioral equivalence), rule-based anomaly and regression detection, both stores at parity, by-tier drop accounting (`dropStats` / `preservedIntegrity`) so load-shedding is never silent — including events lost to a failed batch insert — a drop-in [Foundation Models adapter](docs/foundation-models.md) (live capture and post-hoc transcript ingestion), [OTLP export](docs/otel-bridge.md) to Langfuse or any OTLP/HTTP collector, and a [WebVisualizer](WebVisualizer/) reasoning-diff explorer fed by [`WebDiffExport`](WebVisualizer/SCHEMA.md) JSON.

**Planned:** richer graph/lineage visualization, distributed trace federation, hosted/team trace workflows.

**Scope:** Apple platforms (macOS / iOS). The library depends on system SQLite and CryptoKit, so it targets Apple OSes rather than Linux — by design, since the goal is reasoning observability for Swift and on-device AI.

---

# Not writing Swift?

There's a full **Python port** — [DProvenanceKitPython](https://github.com/Therealdk8890/DProvenanceKitPython) — with the same recording API, query DSL, diff and alignment engines, and validation corpus, plus a CI regression gate and a [GitHub Action](https://github.com/Therealdk8890/dprovenancekit-action) that fails a pull request when an agent's reasoning regresses.

Docs, hosted trace visualizer, and more at **[dprovenance.dev](https://dprovenance.dev)**.

---

# Commercial & team use

The whole library is free and open source under Apache 2.0 — including for production and commercial use. That covers everything that runs on your machine: recording, querying, diffing, **provenance/lineage**, the FoundationModels adapter, and exporting to your own Langfuse or OTel backend. If you want a **team version** — traces and lineage shared across machines and CI, a regression gate that fails a pull request when reasoning drifts, cross-machine analytics, and production monitoring — or commercial support and SLAs, reach out: **[therealdk8890+lineage@gmail.com](mailto:therealdk8890+lineage@gmail.com)**. See [COMMERCIAL.md](https://github.com/Therealdk8890/DProvenanceKit/blob/main/COMMERCIAL.md) for details.

If you want to buy or evaluate support, start with the packaged offer in
[docs/COMMERCIAL_OFFER.md](docs/COMMERCIAL_OFFER.md), the Stripe-ready catalog in
[docs/BILLING_SETUP.md](docs/BILLING_SETUP.md), or the GitHub commercial inquiry template.

---

# License

DProvenanceKit is distributed under the **Apache License 2.0** — free for any use, including production and commercial use, with no usage restrictions. See [LICENSE](LICENSE). Support, SLAs, and enterprise/hosted features are described in [COMMERCIAL.md](https://github.com/Therealdk8890/DProvenanceKit/blob/main/COMMERCIAL.md).
