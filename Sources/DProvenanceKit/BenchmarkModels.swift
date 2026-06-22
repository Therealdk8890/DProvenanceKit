import Foundation

/// A wrapper around an expected finding with a confidence score.
public struct ExpectedFinding: Sendable, Equatable {
    public let finding: AlignmentFinding
    public let expectedConfidence: Double
    
    public init(finding: AlignmentFinding, expectedConfidence: Double = 1.0) {
        self.finding = finding
        self.expectedConfidence = expectedConfidence
    }
}

/// Represents a single offline benchmark case.
public struct BenchmarkCase<T: TraceableEvent>: Sendable {
    public let id: String
    public let name: String
    public let description: String
    public let baseRun: TraceRun<T>
    public let comparisonRun: TraceRun<T>
    public let expectedFindings: [ExpectedFinding]
    
    public init(
        id: String = UUID().uuidString,
        name: String,
        description: String,
        baseRun: TraceRun<T>,
        comparisonRun: TraceRun<T>,
        expectedFindings: [ExpectedFinding]
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.baseRun = baseRun
        self.comparisonRun = comparisonRun
        self.expectedFindings = expectedFindings
    }
}

/// A collection of benchmark cases representing a specific testing dataset.
public struct BenchmarkDataset<T: TraceableEvent>: Sendable {
    public let name: String
    public let description: String
    public let cases: [BenchmarkCase<T>]
    
    public init(name: String, description: String, cases: [BenchmarkCase<T>]) {
        self.name = name
        self.description = description
        self.cases = cases
    }
}
