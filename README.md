# 🚀 DProvenanceKit
> “Every AI decision should be replayable, inspectable, and debuggable.”

**DProvenanceKit turns execution into a queryable provenance graph.**

It lets you:
- record every step an AI system takes
- replay reasoning deterministically
- query execution like a database
- diff runs to see exactly what changed
- detect behavioral drift automatically

If your system makes decisions you can’t explain later, this is for you.

---

## 🧠 Why this exists

Modern AI systems fail in a specific way:
**They don’t crash. They just behave differently.**

One day your agent:
- extracts correct data
- follows the right reasoning path
- passes all tests

The next day:
- it silently skips a step
- changes ordering
- loses intermediate logic
- produces a “plausible but wrong” answer

And you have no idea why.

Logs don’t help. Observability tools don’t go deep enough. Prompts don’t explain themselves.

### DProvenanceKit fixes that
It turns execution into a structured, queryable timeline of decisions.

Not logs.
Not traces.
**A reasoning graph.**

---

## ⚙️ Core Concepts

### 1. Trace Events (not logs)
Every meaningful decision becomes a structured event:
```swift
DProvenanceKit.record(.evaluatedDocumentCount(2))
DProvenanceKit.record(.detectedConflict(type: "date_mismatch"))
```

### 2. Runs (execution units)
Every execution is a deterministic, replayable run:
```swift
try await DProvenanceKit.run(contextID: "case_123", store: store) {
    // your system executes here
}
```

### 3. Queryable execution history
You can ask questions like:
*“Show me runs where comparison was skipped but conflict was detected”*
or
*“Find cases where heuristic order changed”*

### 4. Run Diffing (the killer feature)
Compare two executions:
- what steps disappeared
- what changed order
- what logic shifted
- what confidence drift occurred

This turns debugging into: **git diff — but for reasoning**

### 5. Live anomaly detection
Catch regressions as they happen:
- missing decision steps
- altered execution flow
- confidence drift
- inconsistent reasoning paths

---

## 🔥 What makes this different

Most systems give you: logs, traces, dashboards, metrics.

DProvenanceKit gives you: **a semantic execution model of your system.**

You don’t just see what happened.
**You can query why it happened.**

---

## ⚡ Key Features
- Event-sourced execution model
- Queryable reasoning traces (DSL)
- Cost-optimized query planner
- Live streaming anomaly detection
- Deterministic run replay
- JSONL durable persistence
- Run diff engine *(coming soon)*

---

## 🧭 Architecture (high level)
```
DProvenanceKit
   ↓
TraceEvent Stream
   ↓
FileTraceStore (durable log)
   ↓
InMemoryTraceStore (query index)
   ↓
Query Engine + Planner
   ↓
Live Anomaly Detection
   ↓
Diff + Analytics
```

---

## 🚀 Why developers use it
- “Why did my AI behave differently today?”
- “What step disappeared in production?”
- “Can I diff two agent runs like git?”
- “Can I detect reasoning regressions in CI?”

If yes → this is for you.

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
Initialize a store to hold the traces. `FileTraceStore` automatically writes events to the Application Support directory as JSONL files.

```swift
let store = FileTraceStore<MyAIDecision>()
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

### 4. Query Past Runs
Use the `TraceQueryDSL` to find runs that exhibit specific temporal patterns. For example, finding runs where a document was evaluated, followed by a final decision:

```swift
let query = TraceQueryDSL<MyAIDecision>()
    .requiring(step: "documentEvaluated", followedBy: "finalDecisionMade")

let matchingRuns = try await store.queryRuns(query)
print("Found \(matchingRuns.count) runs matching the pattern!")
```

### 5. Detect Anomalies
Build rules to catch logical regressions in your AI. For example, if a conflict is detected without the document ever being evaluated:

```swift
struct UnverifiedConflictRule: AnomalyRule {
    let name = "UnverifiedConflict"
    
    var anomalyQuery: TraceQueryDSL<MyAIDecision> {
        TraceQueryDSL()
            .requiring(step: "conflictDetected")
            .missing(step: "documentEvaluated")
    }
    
    func describe(run: TraceRun<MyAIDecision>) -> String {
        return "The AI reported a conflict, but no documents were actually evaluated."
    }
}

let detector = AnomalyDetector(store: store)
let anomalies = try await detector.detectAnomalies(rules: [UnverifiedConflictRule()])

for anomaly in anomalies {
    print("🚨 Regression Detected: \(anomaly.description)")
}
```

---

## License
MIT License
