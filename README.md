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
- outputs drift with no visible code change
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
let diff = runA.diff(against: runB)
print(diff.missingSteps)
print(diff.orderChanges)
```

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
}
```

### 2. Set up a Store

Initialize a store to hold the traces. `SQLiteTraceStore` writes events asynchronously to a lock-free SQLite backend, supporting extremely high throughput without blocking execution.

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

## 🧭 Architecture (high level)
```
DProvenanceKit
   ↓
TraceEvent Stream
   ↓
1. **SQLiteTraceStore (lock-free SQL engine)**: Asynchronously persists events via an actor-isolated buffer and WAL-mode SQLite database.
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
MIT License
