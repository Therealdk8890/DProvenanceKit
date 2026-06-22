import Foundation

/// A public corpus of agent traces used for demonstrations, UI development, and benchmarking.
/// These traces simulate real-world AI agent behaviors to validate the TraceAlignmentEngine.
public struct DProvenanceCorpus: Sendable {
    
    public enum AgentEvent: TraceableEvent, Sendable, Equatable {
        case fileIO(action: String, file: String)
        case toolExecution(toolName: String, params: String)
        case planning(hypothesis: String)
        case decision(action: String)
        
        public var typeIdentifier: String {
            switch self {
            case .fileIO: return "fileIO"
            case .toolExecution: return "tool"
            case .planning: return "planning"
            case .decision: return "decision"
            }
        }
        
        public var priority: TracePriority {
            switch self {
            case .decision: return .critical
            case .fileIO, .toolExecution: return .structural
            case .planning: return .diagnostic
            }
        }
    }

    /// The canonical equivalence evaluator for the standard corpus, shared by the demo app, the
    /// CLI, and the benchmark tests so they all score identically.
    ///
    /// It is payload-aware: identical payloads score 1.0 (an exact match, which produces NO
    /// finding), a same-type-but-different payload scores high (a genuine semantic substitution,
    /// which SHOULD surface as a `semanticEvolution` finding), and unrelated events score 0.
    public static var standardEvaluator: AnyEquivalenceEvaluator<AgentEvent> {
        AnyEquivalenceEvaluator<AgentEvent>(
            identifier: "dprov_standard_semantics",
            evaluator: { b, c in
                if b == c { return 1.0 } // identical => exact match, no finding emitted
                guard b.typeIdentifier == c.typeIdentifier else { return 0.0 }
                switch b {
                case .toolExecution: return 0.95 // tool substitution (e.g. SearchDocs -> LookupAPIDocs)
                case .decision: return 0.8       // decision drift (e.g. Authorization -> Precheck)
                case .planning, .fileIO: return 0.0 // distinct hypotheses / files are not equivalent
                }
            }
        )
    }
    
    // MARK: - Example 1: Coding Agent Regression
    /// Baseline: ReadFile -> SearchDocs -> ValidateAPI -> GenerateFix -> VerifyFix
    /// Regression: ReadFile -> GenerateFix (Skipped search, validation, and verification)
    public static var codingAgentRegression: (base: TraceRun<AgentEvent>, comparison: TraceRun<AgentEvent>) {
        let runA = UUID()
        let runB = UUID()
        
        let baseEvents: [TraceEvent<AgentEvent>] = [
            TraceEvent(runID: runA, contextID: "demo_1", engineName: "Agent", schemaVersion: 1, sequence: 0, spanID: "s1", parentSpanID: nil, payload: .fileIO(action: "read", file: "App.swift"), timestamp: Date()),
            TraceEvent(runID: runA, contextID: "demo_1", engineName: "Agent", schemaVersion: 1, sequence: 1, spanID: "s1", parentSpanID: nil, payload: .toolExecution(toolName: "SearchDocs", params: "SwiftUI"), timestamp: Date()),
            TraceEvent(runID: runA, contextID: "demo_1", engineName: "Agent", schemaVersion: 1, sequence: 2, spanID: "s1", parentSpanID: nil, payload: .decision(action: "ValidateAPI"), timestamp: Date()),
            TraceEvent(runID: runA, contextID: "demo_1", engineName: "Agent", schemaVersion: 1, sequence: 3, spanID: "s1", parentSpanID: nil, payload: .decision(action: "GenerateFix"), timestamp: Date()),
            TraceEvent(runID: runA, contextID: "demo_1", engineName: "Agent", schemaVersion: 1, sequence: 4, spanID: "s1", parentSpanID: nil, payload: .toolExecution(toolName: "VerifyFix", params: "build"), timestamp: Date())
        ]
        
        let compEvents: [TraceEvent<AgentEvent>] = [
            TraceEvent(runID: runB, contextID: "demo_1", engineName: "Agent", schemaVersion: 1, sequence: 0, spanID: "s2", parentSpanID: nil, payload: .fileIO(action: "read", file: "App.swift"), timestamp: Date()),
            TraceEvent(runID: runB, contextID: "demo_1", engineName: "Agent", schemaVersion: 1, sequence: 1, spanID: "s2", parentSpanID: nil, payload: .decision(action: "GenerateFix"), timestamp: Date())
        ]
        
        return (TraceRun(runID: runA, contextID: "demo_1", events: baseEvents), TraceRun(runID: runB, contextID: "demo_1", events: compEvents))
    }
    
    // MARK: - Example 2: Semantic Evolution
    /// Baseline: SearchDocumentation
    /// New: LookupAPIDocs
    public static var semanticEvolution: (base: TraceRun<AgentEvent>, comparison: TraceRun<AgentEvent>) {
        let runA = UUID()
        let runB = UUID()
        
        let baseEvents: [TraceEvent<AgentEvent>] = [
            TraceEvent(runID: runA, contextID: "demo_2", engineName: "Agent", schemaVersion: 1, sequence: 0, spanID: "s1", parentSpanID: nil, payload: .toolExecution(toolName: "SearchDocumentation", params: "REST"), timestamp: Date())
        ]
        
        let compEvents: [TraceEvent<AgentEvent>] = [
            TraceEvent(runID: runB, contextID: "demo_2", engineName: "Agent", schemaVersion: 1, sequence: 0, spanID: "s2", parentSpanID: nil, payload: .toolExecution(toolName: "LookupAPIDocs", params: "REST"), timestamp: Date())
        ]
        
        return (TraceRun(runID: runA, contextID: "demo_2", events: baseEvents), TraceRun(runID: runB, contextID: "demo_2", events: compEvents))
    }
    
    // MARK: - Example 3: Reordering
    /// Baseline: ReadFile -> SearchDocs -> GenerateFix
    /// New: SearchDocs -> ReadFile -> GenerateFix
    public static var reordering: (base: TraceRun<AgentEvent>, comparison: TraceRun<AgentEvent>) {
        let runA = UUID()
        let runB = UUID()
        
        let baseEvents: [TraceEvent<AgentEvent>] = [
            TraceEvent(runID: runA, contextID: "demo_3", engineName: "Agent", schemaVersion: 1, sequence: 0, spanID: "s1", parentSpanID: nil, payload: .fileIO(action: "read", file: "Config.swift"), timestamp: Date()),
            TraceEvent(runID: runA, contextID: "demo_3", engineName: "Agent", schemaVersion: 1, sequence: 1, spanID: "s1", parentSpanID: nil, payload: .toolExecution(toolName: "SearchDocs", params: "Config API"), timestamp: Date()),
            TraceEvent(runID: runA, contextID: "demo_3", engineName: "Agent", schemaVersion: 1, sequence: 2, spanID: "s1", parentSpanID: nil, payload: .decision(action: "GenerateFix"), timestamp: Date())
        ]
        
        let compEvents: [TraceEvent<AgentEvent>] = [
            TraceEvent(runID: runB, contextID: "demo_3", engineName: "Agent", schemaVersion: 1, sequence: 0, spanID: "s2", parentSpanID: nil, payload: .toolExecution(toolName: "SearchDocs", params: "Config API"), timestamp: Date()),
            TraceEvent(runID: runB, contextID: "demo_3", engineName: "Agent", schemaVersion: 1, sequence: 1, spanID: "s2", parentSpanID: nil, payload: .fileIO(action: "read", file: "Config.swift"), timestamp: Date()),
            TraceEvent(runID: runB, contextID: "demo_3", engineName: "Agent", schemaVersion: 1, sequence: 2, spanID: "s2", parentSpanID: nil, payload: .decision(action: "GenerateFix"), timestamp: Date())
        ]
        
        return (TraceRun(runID: runA, contextID: "demo_3", events: baseEvents), TraceRun(runID: runB, contextID: "demo_3", events: compEvents))
    }
    
    // MARK: - Example 4: Branch Collapse
    /// Baseline: Investigate -> Hypothesis A, Hypothesis B, Hypothesis C
    /// New: Investigate -> Hypothesis A, Hypothesis C (Dropped B)
    public static var branchCollapse: (base: TraceRun<AgentEvent>, comparison: TraceRun<AgentEvent>) {
        let runA = UUID()
        let runB = UUID()
        
        let baseEvents: [TraceEvent<AgentEvent>] = [
            TraceEvent(runID: runA, contextID: "demo_4", engineName: "Agent", schemaVersion: 1, sequence: 0, spanID: "s1", parentSpanID: nil, payload: .decision(action: "Investigate"), timestamp: Date()),
            TraceEvent(runID: runA, contextID: "demo_4", engineName: "Agent", schemaVersion: 1, sequence: 1, spanID: "sA", parentSpanID: "s1", payload: .planning(hypothesis: "A"), timestamp: Date()),
            TraceEvent(runID: runA, contextID: "demo_4", engineName: "Agent", schemaVersion: 1, sequence: 2, spanID: "sB", parentSpanID: "s1", payload: .planning(hypothesis: "B"), timestamp: Date()),
            TraceEvent(runID: runA, contextID: "demo_4", engineName: "Agent", schemaVersion: 1, sequence: 3, spanID: "sC", parentSpanID: "s1", payload: .planning(hypothesis: "C"), timestamp: Date())
        ]
        
        let compEvents: [TraceEvent<AgentEvent>] = [
            TraceEvent(runID: runB, contextID: "demo_4", engineName: "Agent", schemaVersion: 1, sequence: 0, spanID: "s2", parentSpanID: nil, payload: .decision(action: "Investigate"), timestamp: Date()),
            TraceEvent(runID: runB, contextID: "demo_4", engineName: "Agent", schemaVersion: 1, sequence: 1, spanID: "sA2", parentSpanID: "s2", payload: .planning(hypothesis: "A"), timestamp: Date()),
            TraceEvent(runID: runB, contextID: "demo_4", engineName: "Agent", schemaVersion: 1, sequence: 2, spanID: "sC2", parentSpanID: "s2", payload: .planning(hypothesis: "C"), timestamp: Date())
        ]
        
        return (TraceRun(runID: runA, contextID: "demo_4", events: baseEvents), TraceRun(runID: runB, contextID: "demo_4", events: compEvents))
    }
}
