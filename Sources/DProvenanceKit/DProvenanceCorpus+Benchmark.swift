import Foundation

extension DProvenanceCorpus {
    // MARK: - Example 5: Meaning-Preserving Mutation (Caching)
    public static var cachingMutation: BenchmarkCase<AgentEvent> {
        let runA = UUID()
        let runB = UUID()
        
        let baseEvents: [TraceEvent<AgentEvent>] = [
            TraceEvent(runID: runA, contextID: "demo_5", engineName: "Agent", schemaVersion: 1, sequence: 0, spanID: "s1", parentSpanID: nil, payload: .decision(action: "UserLogin"), timestamp: Date()),
            TraceEvent(runID: runA, contextID: "demo_5", engineName: "Agent", schemaVersion: 1, sequence: 1, spanID: "s1", parentSpanID: nil, payload: .toolExecution(toolName: "FetchProfile", params: "user123"), timestamp: Date()),
            TraceEvent(runID: runA, contextID: "demo_5", engineName: "Agent", schemaVersion: 1, sequence: 2, spanID: "s1", parentSpanID: nil, payload: .decision(action: "RenderDashboard"), timestamp: Date())
        ]
        
        let compEvents: [TraceEvent<AgentEvent>] = [
            TraceEvent(runID: runB, contextID: "demo_5", engineName: "Agent", schemaVersion: 1, sequence: 0, spanID: "s2", parentSpanID: nil, payload: .decision(action: "UserLogin"), timestamp: Date()),
            TraceEvent(runID: runB, contextID: "demo_5", engineName: "Agent", schemaVersion: 1, sequence: 1, spanID: "s2", parentSpanID: nil, payload: .toolExecution(toolName: "FetchCachedProfile", params: "user123"), timestamp: Date()),
            TraceEvent(runID: runB, contextID: "demo_5", engineName: "Agent", schemaVersion: 1, sequence: 2, spanID: "s2", parentSpanID: nil, payload: .decision(action: "RenderDashboard"), timestamp: Date())
        ]
        
        return BenchmarkCase(
            name: "Meaning-Preserving Mutation",
            description: "Replaces network fetch with cached fetch",
            baseRun: TraceRun(runID: runA, contextID: "demo_5", events: baseEvents),
            comparisonRun: TraceRun(runID: runB, contextID: "demo_5", events: compEvents),
            expectedFindings: [
                ExpectedFinding(finding: .semanticEvolution(baseIdentifier: "tool", compIdentifier: "tool"), expectedConfidence: 1.0)
            ]
        )
    }
    
    // MARK: - Example 6: Non-Semantic Noise Injection
    public static var noiseInjection: BenchmarkCase<AgentEvent> {
        let runA = UUID()
        let runB = UUID()
        
        let baseEvents: [TraceEvent<AgentEvent>] = [
            TraceEvent(runID: runA, contextID: "demo_6", engineName: "Agent", schemaVersion: 1, sequence: 0, spanID: "s1", parentSpanID: nil, payload: .toolExecution(toolName: "FetchProfile", params: ""), timestamp: Date()),
            TraceEvent(runID: runA, contextID: "demo_6", engineName: "Agent", schemaVersion: 1, sequence: 1, spanID: "s1", parentSpanID: nil, payload: .decision(action: "RenderDashboard"), timestamp: Date())
        ]
        
        let compEvents: [TraceEvent<AgentEvent>] = [
            TraceEvent(runID: runB, contextID: "demo_6", engineName: "Agent", schemaVersion: 1, sequence: 0, spanID: "s2", parentSpanID: nil, payload: .toolExecution(toolName: "FetchProfile", params: ""), timestamp: Date()),
            TraceEvent(runID: runB, contextID: "demo_6", engineName: "Agent", schemaVersion: 1, sequence: 1, spanID: "s2", parentSpanID: nil, payload: .planning(hypothesis: "Log.Debug cache miss"), timestamp: Date()),
            TraceEvent(runID: runB, contextID: "demo_6", engineName: "Agent", schemaVersion: 1, sequence: 2, spanID: "s2", parentSpanID: nil, payload: .decision(action: "RenderDashboard"), timestamp: Date())
        ]
        
        return BenchmarkCase(
            name: "Noise Injection",
            description: "Injects telemetry/logging events",
            baseRun: TraceRun(runID: runA, contextID: "demo_6", events: baseEvents),
            comparisonRun: TraceRun(runID: runB, contextID: "demo_6", events: compEvents),
            expectedFindings: [
                // Expects no critical removal or semantic evolution! Just an exact match on core.
                // The planning step might just be added but it's diagnostic priority, so no critical findings expected.
            ]
        )
    }

    // MARK: - Example 7: Semantic Drift
    public static var semanticDrift: BenchmarkCase<AgentEvent> {
        let runA = UUID()
        let runB = UUID()
        
        let baseEvents: [TraceEvent<AgentEvent>] = [
            TraceEvent(runID: runA, contextID: "demo_7", engineName: "Agent", schemaVersion: 1, sequence: 0, spanID: "s1", parentSpanID: nil, payload: .decision(action: "PaymentAuthorization"), timestamp: Date())
        ]
        
        let compEvents: [TraceEvent<AgentEvent>] = [
            TraceEvent(runID: runB, contextID: "demo_7", engineName: "Agent", schemaVersion: 1, sequence: 0, spanID: "s2", parentSpanID: nil, payload: .decision(action: "PaymentPrecheck"), timestamp: Date())
        ]
        
        return BenchmarkCase(
            name: "Semantic Drift",
            description: "Substitution attack (Authorization vs Precheck)",
            baseRun: TraceRun(runID: runA, contextID: "demo_7", events: baseEvents),
            comparisonRun: TraceRun(runID: runB, contextID: "demo_7", events: compEvents),
            expectedFindings: [
                ExpectedFinding(finding: .semanticEvolution(baseIdentifier: "decision", compIdentifier: "decision"), expectedConfidence: 0.8)
            ]
        )
    }
    
    // MARK: - Example 8: Degenerate Traces
    public static var degenerateTraces: BenchmarkCase<AgentEvent> {
        let runA = UUID()
        let runB = UUID()
        
        return BenchmarkCase(
            name: "Degenerate Traces",
            description: "Empty trace vs Empty trace",
            baseRun: TraceRun(runID: runA, contextID: "demo_8", events: []),
            comparisonRun: TraceRun(runID: runB, contextID: "demo_8", events: []),
            expectedFindings: []
        )
    }
    
    // Convert existing tuples into Benchmark Cases
    public static var dataset: BenchmarkDataset<AgentEvent> {
        return BenchmarkDataset(
            name: "DProvenance Standard Corpus",
            description: "Official verification dataset for alignment algorithms",
            cases: [
                BenchmarkCase(
                    name: "Coding Agent Regression",
                    description: "A critical validation decision was skipped",
                    baseRun: codingAgentRegression.base,
                    comparisonRun: codingAgentRegression.comparison,
                    expectedFindings: [
                        // The ValidateAPI decision (critical) is dropped in the comparison run.
                        // The structural tool steps (SearchDocs, VerifyFix) are also dropped but are
                        // not critical, so they correctly produce no findings.
                        ExpectedFinding(finding: .criticalStepRemoved(baseEventIdentifier: "decision")),
                        ExpectedFinding(finding: .regressionRisk(RegressionRisk(level: .high, strength: 0.95, reasoning: "Critical reasoning steps removed: decision")))
                    ]
                ),
                BenchmarkCase(
                    name: "Semantic Evolution",
                    description: "Replaced SearchDocumentation with LookupAPIDocs",
                    baseRun: semanticEvolution.base,
                    comparisonRun: semanticEvolution.comparison,
                    expectedFindings: [
                        ExpectedFinding(finding: .semanticEvolution(baseIdentifier: "tool", compIdentifier: "tool"))
                    ]
                ),
                BenchmarkCase(
                    name: "Reordered Execution",
                    description: "Functionally identical, different order",
                    baseRun: reordering.base,
                    comparisonRun: reordering.comparison,
                    expectedFindings: [
                        // ReadFile and SearchDocs swap relative positions; both are genuine reorders.
                        ExpectedFinding(finding: .reorderedExecution(eventIdentifier: "fileIO", originalSequence: 0, newSequence: 1)),
                        ExpectedFinding(finding: .reorderedExecution(eventIdentifier: "tool", originalSequence: 1, newSequence: 0))
                    ]
                ),
                BenchmarkCase(
                    name: "Branch Collapse",
                    description: "Hypothesis B was dropped",
                    baseRun: branchCollapse.base,
                    comparisonRun: branchCollapse.comparison,
                    expectedFindings: [
                        // Since planning is .diagnostic, it wouldn't be a critical step removed unless we check all priorities
                        // For this dataset, we'll leave it empty to test true negatives, or maybe it should be a regression risk
                        // Let's expect no critical findings
                    ]
                ),
                cachingMutation,
                noiseInjection,
                semanticDrift,
                degenerateTraces
            ]
        )
    }

    // MARK: - Adversarial Dataset
    public static var adversarialDataset: BenchmarkDataset<AgentEvent> {
        return BenchmarkDataset(
            name: "DProvenance Adversarial Robustness Suite",
            description: "Stress tests for causal failure modes and semantic traps",
            cases: [
                BenchmarkCase(
                    name: "Dependency Inversion Trap",
                    description: "Swaps order of two dependent critical events",
                    baseRun: TraceRun(runID: UUID(), contextID: "adv_1", events: [
                        TraceEvent(runID: UUID(), contextID: "adv_1", engineName: "Agent", schemaVersion: 1, sequence: 0, spanID: "s1", parentSpanID: nil, payload: .decision(action: "CreateCustomer"), timestamp: Date()),
                        TraceEvent(runID: UUID(), contextID: "adv_1", engineName: "Agent", schemaVersion: 1, sequence: 1, spanID: "s1", parentSpanID: nil, payload: .decision(action: "GenerateInvoice"), timestamp: Date())
                    ]),
                    comparisonRun: TraceRun(runID: UUID(), contextID: "adv_1", events: [
                        TraceEvent(runID: UUID(), contextID: "adv_1", engineName: "Agent", schemaVersion: 1, sequence: 0, spanID: "s2", parentSpanID: nil, payload: .decision(action: "GenerateInvoice"), timestamp: Date()),
                        TraceEvent(runID: UUID(), contextID: "adv_1", engineName: "Agent", schemaVersion: 1, sequence: 1, spanID: "s2", parentSpanID: nil, payload: .decision(action: "CreateCustomer"), timestamp: Date())
                    ]),
                    expectedFindings: [
                        ExpectedFinding(finding: .reorderedExecution(eventIdentifier: "decision", originalSequence: 0, newSequence: 1)),
                        ExpectedFinding(finding: .reorderedExecution(eventIdentifier: "decision", originalSequence: 1, newSequence: 0)),
                        ExpectedFinding(finding: .regressionRisk(RegressionRisk(level: .high, strength: 1.0, reasoning: ""))) // Generic regression risk check
                    ]
                ),
                BenchmarkCase(
                    name: "Causal Ambiguity Trap",
                    description: "Multiple identical events to confuse bipartite matching",
                    baseRun: TraceRun(runID: UUID(), contextID: "adv_2", events: [
                        TraceEvent(runID: UUID(), contextID: "adv_2", engineName: "Agent", schemaVersion: 1, sequence: 0, spanID: "s1", parentSpanID: nil, payload: .toolExecution(toolName: "Search", params: "A"), timestamp: Date()),
                        TraceEvent(runID: UUID(), contextID: "adv_2", engineName: "Agent", schemaVersion: 1, sequence: 1, spanID: "s1", parentSpanID: nil, payload: .toolExecution(toolName: "Search", params: "A"), timestamp: Date())
                    ]),
                    comparisonRun: TraceRun(runID: UUID(), contextID: "adv_2", events: [
                        TraceEvent(runID: UUID(), contextID: "adv_2", engineName: "Agent", schemaVersion: 1, sequence: 0, spanID: "s2", parentSpanID: nil, payload: .toolExecution(toolName: "Search", params: "A"), timestamp: Date()),
                        TraceEvent(runID: UUID(), contextID: "adv_2", engineName: "Agent", schemaVersion: 1, sequence: 1, spanID: "s2", parentSpanID: nil, payload: .toolExecution(toolName: "Search", params: "A"), timestamp: Date())
                    ]),
                    expectedFindings: []
                ),
                BenchmarkCase(
                    name: "Partial Trace Truncation",
                    description: "Trace drops off before final critical decision",
                    baseRun: TraceRun(runID: UUID(), contextID: "adv_3", events: [
                        TraceEvent(runID: UUID(), contextID: "adv_3", engineName: "Agent", schemaVersion: 1, sequence: 0, spanID: "s1", parentSpanID: nil, payload: .decision(action: "Auth"), timestamp: Date()),
                        TraceEvent(runID: UUID(), contextID: "adv_3", engineName: "Agent", schemaVersion: 1, sequence: 1, spanID: "s1", parentSpanID: nil, payload: .decision(action: "Commit"), timestamp: Date())
                    ]),
                    comparisonRun: TraceRun(runID: UUID(), contextID: "adv_3", events: [
                        TraceEvent(runID: UUID(), contextID: "adv_3", engineName: "Agent", schemaVersion: 1, sequence: 0, spanID: "s2", parentSpanID: nil, payload: .decision(action: "Auth"), timestamp: Date())
                    ]),
                    expectedFindings: [
                        ExpectedFinding(finding: .criticalStepRemoved(baseEventIdentifier: "decision")),
                        ExpectedFinding(finding: .regressionRisk(RegressionRisk(level: .high, strength: 0.95, reasoning: "")))
                    ]
                ),
                BenchmarkCase(
                    name: "Semantic Substitution Trap",
                    description: "False friend equivalence: Cached vs Recompute",
                    baseRun: TraceRun(runID: UUID(), contextID: "adv_4", events: [
                        TraceEvent(runID: UUID(), contextID: "adv_4", engineName: "Agent", schemaVersion: 1, sequence: 0, spanID: "s1", parentSpanID: nil, payload: .toolExecution(toolName: "FetchUserProfile", params: "u1"), timestamp: Date())
                    ]),
                    comparisonRun: TraceRun(runID: UUID(), contextID: "adv_4", events: [
                        TraceEvent(runID: UUID(), contextID: "adv_4", engineName: "Agent", schemaVersion: 1, sequence: 0, spanID: "s2", parentSpanID: nil, payload: .toolExecution(toolName: "RecomputeProfileFromEvents", params: "u1"), timestamp: Date())
                    ]),
                    expectedFindings: [
                        ExpectedFinding(finding: .semanticEvolution(baseIdentifier: "tool", compIdentifier: "tool"), expectedConfidence: 0.8)
                    ]
                ),
                BenchmarkCase(
                    name: "Multi-tool Semantic Collapse",
                    description: "Two tools replaced by one overarching tool",
                    baseRun: TraceRun(runID: UUID(), contextID: "adv_5", events: [
                        TraceEvent(runID: UUID(), contextID: "adv_5", engineName: "Agent", schemaVersion: 1, sequence: 0, spanID: "s1", parentSpanID: nil, payload: .toolExecution(toolName: "GetLocation", params: ""), timestamp: Date()),
                        TraceEvent(runID: UUID(), contextID: "adv_5", engineName: "Agent", schemaVersion: 1, sequence: 1, spanID: "s1", parentSpanID: nil, payload: .toolExecution(toolName: "GetWeather", params: ""), timestamp: Date())
                    ]),
                    comparisonRun: TraceRun(runID: UUID(), contextID: "adv_5", events: [
                        TraceEvent(runID: UUID(), contextID: "adv_5", engineName: "Agent", schemaVersion: 1, sequence: 0, spanID: "s2", parentSpanID: nil, payload: .toolExecution(toolName: "GetLocationAndWeather", params: ""), timestamp: Date())
                    ]),
                    expectedFindings: [
                        ExpectedFinding(finding: .semanticEvolution(baseIdentifier: "tool", compIdentifier: "tool"), expectedConfidence: 0.8)
                    ]
                )
            ]
        )
    }
}
