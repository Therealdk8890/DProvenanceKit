# 🚀 DProvenanceKit

**DProvenanceKit lets you debug AI systems like you debug code.**

A small, embeddable Swift library that records every on-device AI execution as a
queryable, replayable, diffable trace — no server, no network, just a SQLite file.

> Run → Record → Query → Diff → Detect Regressions

[![License: BSL 1.1](https://img.shields.io/badge/License-BSL_1.1-blue.svg)](COMMERCIAL.md)
[![Swift](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org)
[![Platform: iOS | macOS | visionOS](https://img.shields.io/badge/Platform-iOS%20%7C%20macOS%20%7C%20visionOS-lightgrey.svg)](https://swift.org)

---

## AI Systems Don't Fail Like Traditional Software

Traditional software crashes.

AI systems often don't.

Instead:

- Agents silently skip steps
- Reasoning order changes between runs
- The same input takes a different path
- Outputs change with no obvious explanation
- Logs show *what happened* but not *why*

DProvenanceKit makes those changes visible, queryable, and comparable.

---

## Questions You Can Finally Answer

Without DProvenanceKit:

- Why did the model approve Case A but reject Case B?
- Which reasoning step disappeared after a model upgrade?
- When did this regression first appear?
- Which agent skipped validation?
- Why are two supposedly identical runs producing different results?

With DProvenanceKit:

```swift
let diff = engine.diff(base: runA, comparison: runB)
```

You can inspect exactly what changed.

---

## Where DProvenanceKit Fits

DProvenanceKit is deliberately small and single-purpose: a record of *what an AI
decided, and in what order*, kept on the device and diffable against last time.

It is **not** a distributed tracing system or a hosted observability platform, and it
doesn't try to be:

- Need cross-service spans, fleet-scale sampling, and an exporter ecosystem? Use
  **OpenTelemetry**. It traces requests across a distributed system; DProvenanceKit
  traces reasoning within a single process.
- Want dashboards and team features for hosted LLM observability? Use **LangSmith** or
  similar. DProvenanceKit has no backend to host — the data stays on the device.

Reach for DProvenanceKit when the model runs **on-device** and you want a queryable,
causally-ordered, diffable record of its reasoning, with no infrastructure to stand up
and nothing to trust but a file you can read.

> **Why it's built this way →** [DESIGN.md](DESIGN.md) covers the engineering judgment
> behind it: synchronous recording over actors, O(1) priority-bucketed load-shedding,
> and a worked case study of a query-parity bug between the two backends — how it was
> caught with a differential test and fixed.

---

## Git for AI Logic

Traditional debugging:

```text
Run A logs
Run B logs

Good luck finding the difference.
```

DProvenanceKit:

```text
Run A
 ├─ evaluateDocuments
 ├─ applyHeuristic
 └─ detectConflict

Run B
 ├─ evaluateDocuments
 └─ detectConflict

Missing:
- applyHeuristic
```

Instead of comparing logs, you compare reasoning paths.

---

# ⏱️ 5-Minute Demo

## 1. Record an Execution Run

```swift
try await DProvenanceKit.run(
    contextID: "demo_case",
    store: store
) {
    DProvenanceKit.record(.evaluatedDocumentCount(2))
    DProvenanceKit.record(.appliedHeuristic("date_match"))
    DProvenanceKit.record(.detectedConflict("timeline_inconsistency"))
}
```

---

## 2. Query Reasoning Patterns

```swift
let suspiciousRuns = try await store.queryRuns(
    TraceQueryDSL<MyAIDecision>()
        .requiring(step: "detectedConflict")
        .missing(step: "appliedHeuristic")
)
```

Find runs where a conflict was reported but no heuristic was applied.

---

## 3. Diff Runs

```swift
let engine = TraceDiffEngine<MyAIDecision>()

let diff = engine.diff(
    base: runA,
    comparison: runB
)

print(diff.changes)
```

See exactly which reasoning steps appeared, disappeared, or changed.

> Diffs currently compare structural execution signatures (event types, engines, ordering). Payload value comparison is planned for a future release.

---

## 4. Detect Regressions Automatically

```swift
let detector = AnomalyDetector(store: store)

let anomalies = try await detector.detectAnomalies(
    rules: [UnverifiedConflictRule()]
)
```

Example output:

```text
🚨 Conflict detected
🚨 No supporting heuristic found
🚨 Potential reasoning regression
```

---

# ⚙️ How It Works

**This records and analyzes execution traces so you can debug reasoning systems.**

That's it.

Every execution becomes a queryable history of decisions.

---

# 📦 Getting Started

## Installation

Add DProvenanceKit to your `Package.swift`:

```swift
dependencies: [
    .package(
        url: "https://github.com/Therealdk8890/DProvenanceKit.git",
        branch: "main"
    )
]
```

---

## 1. Define Events

```swift
import DProvenanceKit

enum MyAIDecision: TraceableEvent {
    case promptGenerated(tokenCount: Int)
    case documentEvaluated(documentID: String, score: Double)
    case conflictDetected(reason: String)
    case finalDecisionMade(approved: Bool)

    var typeIdentifier: String {
        switch self {
        case .promptGenerated:
            return "promptGenerated"

        case .documentEvaluated:
            return "documentEvaluated"

        case .conflictDetected:
            return "conflictDetected"

        case .finalDecisionMade:
            return "finalDecisionMade"
        }
    }

    var priority: TracePriority {
        switch self {
        case .promptGenerated,
             .documentEvaluated:
            return .telemetry

        case .conflictDetected:
            return .diagnostic

        case .finalDecisionMade:
            return .critical
        }
    }
}
```

> **Heads-up:** event payloads are persisted with `JSONEncoder`, so a payload must encode
> as a JSON *object*. Use a struct or an enum with associated values (as above). A
> raw-value enum such as `enum E: String` encodes as a top-level fragment and currently
> fails to persist — see [DESIGN.md](DESIGN.md#known-limitations).

---

## 2. Configure a Store

```swift
let storeURL = URL(
    fileURLWithPath: "/path/to/traces.sqlite"
)

let store = try SQLiteTraceStore<MyAIDecision>(
    fileURL: storeURL
)
```

`SQLiteTraceStore` buffers writes in memory and persists asynchronously using WAL-mode SQLite, ensuring trace recording never blocks execution.

---

## 3. Record Runs

```swift
try await DProvenanceKit.run(
    contextID: "Case-12345",
    store: store
) {

    DProvenanceKit.record(
        .promptGenerated(tokenCount: 150)
    )

    try await DProvenanceKit.withEngine(
        name: "DocumentAnalyzer"
    ) {
        DProvenanceKit.record(
            .documentEvaluated(
                documentID: "DocA",
                score: 0.95
            )
        )
    }

    DProvenanceKit.record(
        .finalDecisionMade(approved: true)
    )
}
```

---

# Designed For

- AI agents
- Multi-agent systems
- LLM workflows
- Tool-using models
- Reasoning engines
- Workflow orchestration
- Decision support systems
- Deterministic pipelines

---

# Trace Priorities

AI systems can generate enormous bursts of trace events.

DProvenanceKit uses priority-aware congestion control to preserve the most important reasoning information under load.

| Priority | Purpose |
|-----------|----------|
| Critical | Final decisions |
| Structural | Reasoning boundaries |
| Diagnostic | Debug information |
| Telemetry | High-volume observations |

During overload conditions, lower-priority events are shed first while structural and critical events are preserved to maintain diff accuracy.

---

# Architecture

```text
DProvenanceKit
      ↓
Trace Event Stream
      ↓
Trace Stores
      ↓
Query Engine
      ↓
Anomaly Detection
      ↓
Diff & Analytics
```

### SQLiteTraceStore

- Non-blocking writes
- WAL-mode SQLite
- Background batching

### InMemoryTraceStore

- Fast local execution
- Test environments
- Temporary traces

### Query Engine

- Reasoning pattern search
- Missing-step detection
- Trace filtering

### Diff Engine

- Structural reasoning diffs
- Regression identification
- Path comparison

### Anomaly Detection

- Rule-based validation
- Regression discovery
- Execution monitoring

---

# Status

**Experimental**

Core engine complete.

Actively evolving.

### Current Capabilities

- Recording
- Querying
- Diffing
- Regression detection
- Anomaly detection

### Integrity (and how it's proven)

The properties a diff tool lives or dies by are guarantees here, each backed by a test:

- Recording is **synchronous and ordered**, so a flush sees every event recorded before
  it, in record order.
- Under burst, load-shedding drops only low-priority telemetry and **counts every drop**
  — `store.dropStats.preservedIntegrity` tells you whether anything that could change a
  diff was lost.
- The two query backends (in-memory and SQLite) are held to **identical results** by a
  differential parity test.

See [DESIGN.md](DESIGN.md) for the mechanisms and the tests behind each.

### Planned Expansion

- Payload-aware diffs
- Rich visualization
- Advanced analytics
- Distributed trace federation

---

# License

DProvenanceKit is distributed under the **Business Source License 1.1 (BSL 1.1)**.

- Free for development, testing, and non-production use.
- Limited production use allowed under the Additional Use Grant.
- Commercial / production use requires a paid license.

**[View full commercial licensing options →](COMMERCIAL.md)**

On June 16, 2030 the license automatically converts to Apache 2.0.
