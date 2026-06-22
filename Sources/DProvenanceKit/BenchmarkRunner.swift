import Foundation

public struct DeterministicBoundary: Sendable, Equatable {
    public let cacheIsolated: Bool
    public let seedControl: String?
    
    public init(cacheIsolated: Bool = true, seedControl: String? = nil) {
        self.cacheIsolated = cacheIsolated
        self.seedControl = seedControl
    }
}

public struct EnvironmentContext: Sendable, Equatable {
    public let boundary: DeterministicBoundary
    public let iteration: Int
    
    public init(boundary: DeterministicBoundary, iteration: Int) {
        self.boundary = boundary
        self.iteration = iteration
    }
}

public actor BenchmarkRunner<T: TraceableEvent> {
    
    // We use a factory so each case gets a clean engine instance
    // This allows us to cleanly capture meta-events per-case without crossover.
    public typealias EngineFactory = @Sendable (@escaping @Sendable (TraceEvent<AlignmentMetaEvent>) -> Void) -> TraceAlignmentEngine<T>
    public typealias ContextualEngineFactory = @Sendable (EnvironmentContext, @escaping @Sendable (TraceEvent<AlignmentMetaEvent>) -> Void) -> TraceAlignmentEngine<T>
    
    public init() {}
    
    private final class EventCollector: @unchecked Sendable {
        private var lock = NSLock()
        var events: [TraceEvent<AlignmentMetaEvent>] = []
        func append(_ event: TraceEvent<AlignmentMetaEvent>) {
            lock.lock()
            events.append(event)
            lock.unlock()
        }
    }
    
    public func runRepeatedEvaluation(
        dataset: BenchmarkDataset<T>,
        iterations: Int,
        boundary: DeterministicBoundary = DeterministicBoundary(),
        engineFactory: ContextualEngineFactory
    ) async -> BenchmarkStabilityReport<T> {
        var reports: [BenchmarkReport<T>] = []
        for i in 0..<iterations {
            let context = EnvironmentContext(boundary: boundary, iteration: i)
            let report = await run(dataset: dataset) { callback in
                engineFactory(context, callback)
            }
            reports.append(report)
        }
        return BenchmarkStabilityReport(iterations: iterations, reports: reports, boundary: boundary)
    }
    
    public func run(dataset: BenchmarkDataset<T>, engineFactory: EngineFactory) async -> BenchmarkReport<T> {
        var caseResults: [BenchmarkCaseResult<T>] = []
        var runTimes: [Double] = []
        
        var globalTP = 0
        var globalFP = 0
        var globalFN = 0
        
        var categoryTP: [String: Int] = [:]
        var categoryFP: [String: Int] = [:]
        var categoryFN: [String: Int] = [:]
        
        for bCase in dataset.cases {
            let collector = EventCollector()
            let callback: @Sendable (TraceEvent<AlignmentMetaEvent>) -> Void = { event in
                collector.append(event)
            }
            
            let engine = engineFactory(callback)
            
            let start = Date()
            let alignmentResult = engine.align(base: bCase.baseRun, comparison: bCase.comparisonRun, minimumPriority: .diagnostic)
            let duration = Date().timeIntervalSince(start) * 1000.0 // ms
            
            runTimes.append(duration)
            
            let extractor = AlignmentFindingsExtractor<T>()
            let actualFindings = extractor.extract(from: alignmentResult)
            
            // Map meta events to timeline
            let timeline = collector.events.map { event -> DecisionTimelineEntry in
                let title: String
                let detail: String
                var category: AlignmentStrengthCategory? = nil
                
                switch event.payload {
                case .evaluatedPair(_, _, let baseSeq, let compSeq, let score):
                    title = "Evaluated Base:\(baseSeq) → Comp:\(compSeq)"
                    detail = "Calculated heuristic alignment score."
                    category = AlignmentStrengthCategory(strength: score)
                    
                case .ambiguityThresholdMet(_, _, let compSeq, let score):
                    title = "Ambiguity Threshold Exceeded"
                    detail = "Comparison event \(compSeq) hit ambiguity threshold."
                    category = AlignmentStrengthCategory(strength: score)
                    
                case .candidateEvicted(_, _, let compSeq, let reason):
                    title = "Rejected Comp:\(compSeq)"
                    detail = "Reason: \(reason)"
                    category = .rejected
                    
                case .regressionDetected(_, _, let level, let reasoning):
                    title = "Regression Risk: \(level.capitalized)"
                    detail = reasoning
                }
                
                return DecisionTimelineEntry(
                    id: event.id,
                    timestamp: event.timestamp,
                    title: title,
                    detail: detail,
                    strengthCategory: category,
                    metaEvent: event.payload
                )
            }
            
            // Compute TP, FP, FN using multiset logic (consume elements)
            var truePositives: [AlignmentFinding] = []
            var falsePositives: [AlignmentFinding] = []
            var falseNegatives: [ExpectedFinding] = []
            
            var availableActual = actualFindings
            
            // Check FN and TP
            for expected in bCase.expectedFindings {
                // Find first matching finding deterministically (could sort to be totally safe, but finding is Equatable)
                // Wait, equatable match is fine, we just take the first.
                if let index = availableActual.firstIndex(of: expected.finding) {
                    availableActual.remove(at: index)
                    truePositives.append(expected.finding)
                    categoryTP[expected.finding.categoryName, default: 0] += 1
                    globalTP += 1
                } else {
                    falseNegatives.append(expected)
                    categoryFN[expected.finding.categoryName, default: 0] += 1
                    globalFN += 1
                }
            }
            
            // Whatever is left in availableActual is a false positive
            for actual in availableActual {
                falsePositives.append(actual)
                categoryFP[actual.categoryName, default: 0] += 1
                globalFP += 1
            }
            
            let diagnoser = BenchmarkFailureDiagnoser()
            let diagnoses = diagnoser.diagnose(
                falsePositives: falsePositives,
                falseNegatives: falseNegatives,
                timeline: timeline,
                alignmentResult: alignmentResult
            )
            let auditor = ExplainabilityAuditor()
            let fidelityScore: FidelityVector

            if actualFindings.isEmpty {
                // The engine produced no findings. If the case also expected none, the
                // (empty) explanation is trivially faithful. But if expected findings were
                // missed (false negatives), an empty explanation is NOT faithful — the engine
                // failed to surface and justify what should have been there, so fidelity is 0.
                fidelityScore = falseNegatives.isEmpty
                    ? FidelityVector(coverage: 1, completeness: 1, causalOrdering: 1, noHallucinations: 1)
                    : FidelityVector(coverage: 0, completeness: 0, causalOrdering: 0, noHallucinations: 0)
            } else if let evidence = alignmentResult.verificationArtifacts?.evidence {
                let builder = DefaultFormalizationMapBuilder()
                let map = builder.build(from: evidence)
                fidelityScore = auditor.audit(map)
            } else {
                // Findings exist but the engine was run without evidence capture
                // (captureMode != .evidenceOnly), so fidelity is unverifiable.
                fidelityScore = FidelityVector(coverage: 0, completeness: 0, causalOrdering: 0, noHallucinations: 0)
            }
            
            let result = BenchmarkCaseResult(
                benchmarkCase: bCase,
                runTimeMs: duration,
                actualFindings: actualFindings,
                truePositives: truePositives,
                falsePositives: falsePositives,
                falseNegatives: falseNegatives,
                diagnoses: diagnoses,
                fidelityScore: fidelityScore,
                alignmentResult: alignmentResult,
                timeline: timeline
            )
            caseResults.append(result)
        }
        
        let sortedRuntimes = runTimes.sorted()
        let avgRuntime = sortedRuntimes.isEmpty ? 0 : sortedRuntimes.reduce(0, +) / Double(sortedRuntimes.count)
        let p95Index = max(0, Int(ceil(Double(sortedRuntimes.count) * 0.95)) - 1)
        let p95Runtime = sortedRuntimes.isEmpty ? 0 : sortedRuntimes[min(p95Index, sortedRuntimes.count - 1)]
        
        let avgFidelity = caseResults.isEmpty ? 1.0 : caseResults.reduce(0.0) { $0 + $1.fidelityScore.overallScore } / Double(caseResults.count)
        
        let globalMetrics = CategoryMetrics(truePositives: globalTP, falsePositives: globalFP, falseNegatives: globalFN)
        
        var stratifiedMetrics: [String: CategoryMetrics] = [:]
        let allCategories = Set(categoryTP.keys).union(categoryFP.keys).union(categoryFN.keys)
        for cat in allCategories {
            stratifiedMetrics[cat] = CategoryMetrics(
                truePositives: categoryTP[cat] ?? 0,
                falsePositives: categoryFP[cat] ?? 0,
                falseNegatives: categoryFN[cat] ?? 0
            )
        }
        
        let passedCases = caseResults.filter { $0.passed }.count
        
        return BenchmarkReport(
            datasetName: dataset.name,
            caseResults: caseResults,
            totalCases: caseResults.count,
            passedCases: passedCases,
            averageRunTimeMs: avgRuntime,
            p95RunTimeMs: p95Runtime,
            globalMetrics: globalMetrics,
            stratifiedMetrics: stratifiedMetrics,
            averageFidelityScore: avgFidelity
        )
    }
}
