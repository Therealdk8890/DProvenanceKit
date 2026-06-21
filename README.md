# 🚀 DProvenanceKit

**DProvenanceKit lets you debug AI systems like you debug code.**

[![License: BSL 1.1](https://img.shields.io/badge/License-BSL_1.1-blue.svg)](COMMERCIAL.md)
[![Swift](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org)

It turns every execution into a queryable, replayable, diffable trace.

> Run → Record → Query → Diff → Detect Regressions

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

## Isn't This Just OpenTelemetry?

**No.**

OpenTelemetry answers:

> What happened?

DProvenanceKit answers:

> Why did the AI reach this conclusion?

### OpenTelemetry

- Request tracing
- Latency measurement
- Service observability
- Infrastructure monitoring

### DProvenanceKit

- Reasoning traceability
- Decision lineage
- Logic diffs
- Regression detection
- AI execution auditing

OpenTelemetry traces requests.

**DProvenanceKit traces reasoning.**

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

### Planned Expansion

- Payload-aware diffs
- Rich visualization
- Advanced analytics
- Distributed trace federation

---

# License

Business Source License 1.1 (BSL 1.1)

## Commercial Use
For production or commercial deployments, see our [COMMERCIAL.md](COMMERCIAL.md) for licensing options and pricing.
