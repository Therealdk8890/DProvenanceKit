# DProvenanceKit

**DProvenanceKit** is a lightweight, strictly-typed Swift package for **reasoning observability and regression testing in AI systems**. 

When building complex, multi-agent AI systems, understanding *how* a model arrived at a conclusion is just as important as the conclusion itself. DProvenanceKit allows you to passively instrument your AI engines, record granular decision-making steps, and write temporal queries to detect anomalous behavior or regressions in real-time.

## Features

- **Generic Trace Payloads**: Define your own strongly-typed events via the `TraceableEvent` protocol.
- **Structured Concurrency**: Uses Swift `@TaskLocal` variables to implicitly route events to the correct execution run without passing a logger instance around your entire codebase.
- **Durable Storage**: Ships with `InMemoryTraceStore` and `FileTraceStore` (JSONL) for persisting AI reasoning traces.
- **Trace Query DSL**: A declarative, temporal query language to evaluate the sequence and presence of specific reasoning steps within a run (e.g., "Step A must be followed by Step B, but Step C must be missing").
- **Live Query Engine**: Subscribe to reasoning queries and detect matches in real-time as your AI generates output.
- **Anomaly Detection**: Build regression test suites that define "Invalid Sequences" or "Anomalous Behaviors" to automatically flag when your AI deviates from expected logic flows.

## Installation

Add DProvenanceKit to your `Package.swift` dependencies:

```swift
dependencies: [
    .package(url: "https://github.com/Therealdk8890/DProvenanceKit.git", branch: "main")
]
```

## How It Works

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

You can also use the `LiveTraceQueryEngine` to evaluate these anomaly rules in real-time as events stream in!

## License
MIT License
