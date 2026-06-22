import Foundation

public struct CategoryDeltaMetrics: Sendable, Equatable {
    public let precisionDelta: Double
    public let recallDelta: Double
    public let f1Delta: Double
    
    public init(current: CategoryMetrics, baseline: CategoryMetrics) {
        self.precisionDelta = current.precision - baseline.precision
        self.recallDelta = current.recall - baseline.recall
        self.f1Delta = current.f1Score - baseline.f1Score
    }
}

public struct BenchmarkDeltaReport<T: TraceableEvent>: Sendable {
    public let currentReport: BenchmarkReport<T>
    public let baselineReport: BenchmarkReport<T>
    
    public let globalDelta: CategoryDeltaMetrics
    public let stratifiedDeltas: [String: CategoryDeltaMetrics]
    
    public let runtimeDeltaMs: Double
    
    public init(current: BenchmarkReport<T>, baseline: BenchmarkReport<T>) {
        self.currentReport = current
        self.baselineReport = baseline
        self.globalDelta = CategoryDeltaMetrics(current: current.globalMetrics, baseline: baseline.globalMetrics)
        
        var strats: [String: CategoryDeltaMetrics] = [:]
        let allCategories = Set(current.stratifiedMetrics.keys).union(baseline.stratifiedMetrics.keys)
        
        let emptyMetrics = CategoryMetrics(truePositives: 0, falsePositives: 0, falseNegatives: 0)
        
        for cat in allCategories {
            let curr = current.stratifiedMetrics[cat] ?? emptyMetrics
            let base = baseline.stratifiedMetrics[cat] ?? emptyMetrics
            strats[cat] = CategoryDeltaMetrics(current: curr, baseline: base)
        }
        
        self.stratifiedDeltas = strats
        self.runtimeDeltaMs = current.averageRunTimeMs - baseline.averageRunTimeMs
    }
}

extension BenchmarkReport {
    public func compare(to baseline: BenchmarkReport<T>) -> BenchmarkDeltaReport<T> {
        return BenchmarkDeltaReport(current: self, baseline: baseline)
    }
}
