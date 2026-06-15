# 🚀 DProvenanceKit
> “Every AI decision should be replayable, inspectable, and debuggable.”

**DProvenanceKit lets you debug AI systems like you debug code.**

Run → Record → Query → Diff → Detect regressions

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
let suspiciousRuns = try await store.queryRuns(
    TraceQueryDSL<MyAIDecision>()
        .requiring(step: "detectedConflict")
        .missing(step: "appliedHeuristic")
)
```

**3. Diff runs (like git for logic)**
```swift
// See exactly what logic shifted between two executions
let diff = runA.diff(against: runB)
print(diff.missingSteps)
print(diff.orderChanges)
```

**4. Catch regressions automatically**
```swift
let detector = AnomalyDetector(store: store)
let anomalies = try await detector.detectAnomalies(rules: [UnverifiedConflictRule()])
// 🚨 "The AI reported a conflict, but no heuristic was actually applied."
```

---

## ⚙️ How it Works (in one sentence)

**This records and analyzes execution traces so you can debug reasoning systems.**

*(That's it. It turns black-box AI execution into a queryable database of decisions.)*

---

## 📦 Installation
Add DProvenanceKit to your `Package.swift` dependencies:

```swift
dependencies: [
    .package(url: "https://github.com/Therealdk8890/DProvenanceKit.git", branch: "main")
]
```

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

## 🚀 Why developers use it
- “Why did my AI behave differently today?”
- “What step disappeared in production?”
- “Can I diff two agent runs like git?”
- “Can I detect reasoning regressions in CI?”

If yes → this is for you.

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
