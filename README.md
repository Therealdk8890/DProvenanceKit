# 🚀 DProvenanceKit

**DProvenanceKit lets you debug AI systems like you debug code.**

It turns every execution into a queryable, replayable, diffable trace.

Run → Record → Query → Diff → Detect regressions

---

## 💥 This is what breaks today

Modern AI systems fail in a specific way:
They don’t crash. They just behave differently.

- AI agents silently skip steps
- reasoning order changes between runs
- the same input quietly takes a different path
- logs don’t explain why

**This library makes those changes visible and queryable.**

---

## ⏱️ 5-Minute Demo

**1. Record an execution run**
```swift
try await DProvenanceKit.run(contextID: "demo_case", store: store) {
    DProvenanceKit.record(.evaluatedDocumentCount(2))
    DProvenanceKit.record(.appliedHeuristic("date_match"))
    DProvenanceKit.record(.detectedConflict("timeline_inconsistency"))
}
```

**2. Query for reasoning patterns**
```swift
// "Find runs missing comparison step"
let suspiciousRuns = try await store.queryRuns(
    TraceQueryDSL<MyAIDecision>()
        .requiring(step: "detectedConflict")
        .missing(step: "appliedHeuristic")
)
```

**3. Diff runs (like git for logic)**
```swift
// "Diff run A vs B"
let engine = TraceDiffEngine<MyAIDecision>()
let diff = engine.diff(base: runA, comparison: runB)
print(diff.changes)
```

> Diffs compare **structural signatures** — which decision types fired, in which engine, and in what order. Payload values aren't compared yet, so two runs that take the same path with different numbers (e.g. a score of `0.95` vs `0.10`) diff as identical.

**4. Catch regressions automatically**
```swift
// "Detect anomaly"
let detector = AnomalyDetector(store: store)
let anomalies = try await detector.detectAnomalies(rules: [UnverifiedConflictRule()])
// 🚨 "The AI reported a conflict, but no heuristic was actually applied."
```

---

## 📦 Getting Started

### Installation
Add DProvenanceKit to your `Package.swift` dependencies:

```swift
dependencies: [
    .package(url: "https://github.com/Therealdk8890/DProvenanceKit.git", branch: "main")
]
```

### 1. Define your Events
Adopt the `TraceableEvent` protocol to define the types of decisions your AI makes.

```swift
import DProvenanceKit

enum MyAIDecision: TraceableEvent {
    case promptGenerated(tokenCount: Int)
    case documentEvaluated(documentID: String, score: Double)
    case conflictDetected(reason: String)
    case finalDecisionMade(approved: Bool)

    var typeIdentifier: String {
        switch self {
        case .promptGenerated: return "promptGenerated"
        case .documentEvaluated: return "documentEvaluated"
        case .conflictDetected: return "conflictDetected"
        case .finalDecisionMade: return "finalDecisionMade"
        }
    }
    
    var priority: TracePriority {
        switch self {
        case .promptGenerated, .documentEvaluated: return .telemetry
        case .conflictDetected: return .diagnostic
        case .finalDecisionMade: return .critical
        }
    }
}
```

### 2. Set up a Store

Initialize a store to hold the traces. `SQLiteTraceStore` buffers events in memory and writes them asynchronously on a background actor, so `record` never blocks on disk I/O — even under high-throughput bursts. Persistence uses a WAL-mode SQLite database.

```swift
let storeURL = URL(fileURLWithPath: "/path/to/traces.sqlite")
let store = try SQLiteTraceStore<MyAIDecision>(fileURL: storeURL)
```

### 3. Record Execution Runs
Wrap your AI's execution in a `DProvenanceKit.run` block. Any events recorded inside this block—even deep within nested async functions—will be safely attributed to the current run.

```swift
try await DProvenanceKit.run(contextID: "Case-12345", store: store) {
    
    // Somewhere deep in your application logic...
    DProvenanceKit.record(.promptGenerated(tokenCount: 150))
    
    // You can also label specific engines or sub-agents
    try await DProvenanceKit.withEngine(name: "DocumentAnalyzer") {
        DProvenanceKit.record(.documentEvaluated(documentID: "DocA", score: 0.95))
    }
    
    DProvenanceKit.record(.finalDecisionMade(approved: true))
}
```

---

## ⚙️ How it Works (in one sentence)

**This records and analyzes execution traces so you can debug reasoning systems.**

*(That's it. It turns black-box AI execution into a queryable database of decisions.)*

---

### 4. Trace Priorities (Congestion Control)

AI reasoning often bursts with highly variable loads. DProvenanceKit treats tracing like network traffic, implementing **priority-aware congestion control**. 

Your event types must adopt the `priority` property. In the event of a burst anomaly (e.g. an agent gets stuck in a loop generating 100k events in a millisecond), the in-memory buffer sheds `telemetry` and `diagnostic` events from the offending run to protect global buffer health, while **always preserving** `structural` and `critical` boundary events so reasoning logic diffs remain accurate. Shedding is O(1) per event — the buffer keeps one FIFO per priority tier, so it never scans the backlog even at capacity.

```swift
enum MyAIDecision: TraceableEvent {
    case documentEvaluated(String) // Priority: telemetry
    case reasoningApplied(String)  // Priority: structural
    
    var priority: TracePriority {
        switch self {
        case .documentEvaluated: return .telemetry
        case .reasoningApplied: return .structural
        }
    }
    // ...
}
```

## Architecture (high level)
```
DProvenanceKit
   ↓
TraceEvent Stream
   ↓
1. **SQLiteTraceStore (non-blocking writes)**: `record` enqueues into an in-memory buffer synchronously; a background actor batches inserts into a WAL-mode SQLite database.
2. **InMemoryTraceStore (query index)**: For fast, localized execution.
   ↓
Query Engine + Planner
   ↓
Live Anomaly Detection
   ↓
Diff + Analytics
```

---

## 🧪 Status
**Experimental.** Core engine complete. Actively evolving.

Designed for:
- AI agents
- reasoning systems
- workflow engines
- deterministic pipelines
- tool-using LLM systems

---

## 🧠 Philosophy
If a system makes decisions, those decisions should be:
**observable, queryable, and comparable over time.**

---

## License
Business Source License 1.1 (BSL 1.1)
