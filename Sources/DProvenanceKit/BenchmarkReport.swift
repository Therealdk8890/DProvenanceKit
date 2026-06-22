import Foundation

public struct CategoryMetrics: Sendable, Equatable {
    public let truePositives: Int
    public let falsePositives: Int
    public let falseNegatives: Int
    
    public var precision: Double {
        let total = truePositives + falsePositives
        return total > 0 ? Double(truePositives) / Double(total) : 1.0
    }
    
    public var recall: Double {
        let total = truePositives + falseNegatives
        return total > 0 ? Double(truePositives) / Double(total) : 1.0
    }
    
    public var f1Score: Double {
        let p = precision
        let r = recall
        return (p + r) > 0 ? 2 * (p * r) / (p + r) : 0.0
    }
}

public struct BenchmarkCaseResult<T: TraceableEvent>: Sendable {
    public let benchmarkCase: BenchmarkCase<T>
    public let runTimeMs: Double
    
    // The findings the engine actually extracted
    public let actualFindings: [AlignmentFinding]
    
    // Ground truth evaluation
    public let truePositives: [AlignmentFinding]
    public let falsePositives: [AlignmentFinding]
    public let falseNegatives: [ExpectedFinding]
    
    // Diagnosis & Audit
    public let diagnoses: [DiagnosedFailure]
    public let fidelityScore: FidelityVector
    
    // Full Engine Result for debugging
    public let alignmentResult: TraceAlignmentResult<T>
    public let timeline: [DecisionTimelineEntry]
    
    public var passed: Bool {
        return falsePositives.isEmpty && falseNegatives.isEmpty
    }
}

public struct BenchmarkReport<T: TraceableEvent>: Sendable {
    public let datasetName: String
    public let caseResults: [BenchmarkCaseResult<T>]
    
    public let totalCases: Int
    public let passedCases: Int
    
    public let averageRunTimeMs: Double
    public let p95RunTimeMs: Double
    
    public let globalMetrics: CategoryMetrics
    
    public let stratifiedMetrics: [String: CategoryMetrics]
    
    public let averageFidelityScore: Double
    
    public var causalRanking: [CausalRank] {
        var groups: [FailureCause: [DiagnosedFailure]] = [:]
        
        for caseResult in caseResults {
            for diagnosis in caseResult.diagnoses {
                groups[diagnosis.hypothesizedCause, default: []].append(diagnosis)
            }
        }
        
        let rawRanks = groups.map { cause, failures -> (cause: FailureCause, frequency: Int, avgConf: Double, rawImpact: Double) in
            let freq = Double(failures.count)
            let avgConf = failures.reduce(0.0) { $0 + $1.diagnosisConfidence } / freq
            let score = freq * cause.severity * avgConf
            return (cause, failures.count, avgConf, score)
        }
        
        let totalImpact = rawRanks.reduce(0.0) { $0 + $1.rawImpact }
        let meanImpact = rawRanks.isEmpty ? 0 : totalImpact / Double(rawRanks.count)
        
        let variance = rawRanks.isEmpty ? 0 : rawRanks.reduce(0.0) { sum, rank in
            let diff = rank.rawImpact - meanImpact
            return sum + (diff * diff)
        } / Double(rawRanks.count)
        let stdevImpact = sqrt(variance)
        
        return rawRanks.map { rank in
            let fractional = totalImpact > 0 ? (rank.rawImpact / totalImpact) : 0
            let zScore = stdevImpact > 0 ? ((rank.rawImpact - meanImpact) / stdevImpact) : 0
            
            return CausalRank(
                cause: rank.cause,
                frequency: rank.frequency,
                averageConfidence: rank.avgConf,
                rawImpactScore: rank.rawImpact,
                fractionalImpact: fractional,
                zScoreImpact: zScore
            )
        }.sorted { $0.rawImpactScore > $1.rawImpactScore }
    }
}

public struct CausalRank: Sendable, Equatable {
    public let cause: FailureCause
    public let frequency: Int
    public let averageConfidence: Double
    public let rawImpactScore: Double
    
    // UI/Product metric: share of systemic impact (0.0-1.0)
    public let fractionalImpact: Double
    
    // Scientific/Diagnostic metric: deviation from mean
    public let zScoreImpact: Double
}

public struct BenchmarkStabilityReport<T: TraceableEvent>: Sendable {
    public let iterations: Int
    public let reports: [BenchmarkReport<T>]
    public let boundary: DeterministicBoundary
    
    public init(iterations: Int, reports: [BenchmarkReport<T>], boundary: DeterministicBoundary = DeterministicBoundary()) {
        self.iterations = iterations
        self.reports = reports
        self.boundary = boundary
    }
    
    public var meanPrecision: Double {
        reports.reduce(0.0) { $0 + $1.globalMetrics.precision } / Double(iterations)
    }
    
    public var meanRecall: Double {
        reports.reduce(0.0) { $0 + $1.globalMetrics.recall } / Double(iterations)
    }
    
    public var meanF1: Double {
        reports.reduce(0.0) { $0 + $1.globalMetrics.f1Score } / Double(iterations)
    }
    
    public var precisionVariance: Double {
        let mean = meanPrecision
        return reports.reduce(0.0) { $0 + pow($1.globalMetrics.precision - mean, 2) } / Double(iterations)
    }
    
    public var f1Variance: Double {
        let mean = meanF1
        return reports.reduce(0.0) { $0 + pow($1.globalMetrics.f1Score - mean, 2) } / Double(iterations)
    }
    
    public var driftFingerprint: String {
        if f1Variance < 0.0001 { return "Stable: No significant drift" }
        // Simple heuristic for drift
        if precisionVariance > f1Variance {
            return "Unstable: Precision fluctuates (oversensitive matcher boundary)"
        } else {
            return "Unstable: Recall fluctuates (inconsistent search space exploration)"
        }
    }
}
