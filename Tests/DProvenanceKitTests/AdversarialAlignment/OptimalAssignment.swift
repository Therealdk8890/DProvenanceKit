import Foundation
@testable import DProvenanceKit

/// Globally optimal bipartite assignment using the production score function.
/// Test-only Hungarian / Munkres; does not alter DefaultTraceMatcher.
enum AdvOptimalAssignment {
    /// Maximize sum of scores; omit pairs with score <= 0 after padding.
    static func hungarianMaximize(_ scoreMatrix: [[Double]]) -> [(Int, Int)] {
        guard let first = scoreMatrix.first, !first.isEmpty else { return [] }
        let nRows = scoreMatrix.count
        let nCols = first.count
        let n = max(nRows, nCols)
        let maxVal = scoreMatrix.flatMap { $0 }.max() ?? 0.0

        var cost = Array(repeating: Array(repeating: maxVal, count: n), count: n)
        for i in 0..<nRows {
            for j in 0..<nCols {
                cost[i][j] = maxVal - scoreMatrix[i][j]
            }
        }

        var u = Array(repeating: 0.0, count: n + 1)
        var v = Array(repeating: 0.0, count: n + 1)
        var p = Array(repeating: 0, count: n + 1)
        var way = Array(repeating: 0, count: n + 1)

        for i in 1...n {
            p[0] = i
            var j0 = 0
            var minv = Array(repeating: Double.infinity, count: n + 1)
            var used = Array(repeating: false, count: n + 1)
            while true {
                used[j0] = true
                let i0 = p[j0]
                var delta = Double.infinity
                var j1 = 0
                for j in 1...n where !used[j] {
                    let cur = cost[i0 - 1][j - 1] - u[i0] - v[j]
                    if cur < minv[j] {
                        minv[j] = cur
                        way[j] = j0
                    }
                    if minv[j] < delta {
                        delta = minv[j]
                        j1 = j
                    }
                }
                for j in 0...n {
                    if used[j] {
                        u[p[j]] += delta
                        v[j] -= delta
                    } else {
                        minv[j] -= delta
                    }
                }
                j0 = j1
                if p[j0] == 0 { break }
            }
            while true {
                let j1 = way[j0]
                p[j0] = p[j1]
                j0 = j1
                if j0 == 0 { break }
            }
        }

        var assignment: [(Int, Int)] = []
        for j in 1...n {
            let i = p[j]
            if i == 0 { continue }
            let row = i - 1
            let col = j - 1
            if row < nRows && col < nCols && scoreMatrix[row][col] > 0.0 {
                assignment.append((row, col))
            }
        }
        return assignment
    }

    static func optimalBindings<T: TraceableEvent>(
        configuration: AlignmentConfiguration<T>,
        base: [TraceEvent<T>],
        comparison: [TraceEvent<T>]
    ) -> [AlignmentBinding] {
        let nB = base.count
        let nC = comparison.count
        guard nB > 0, nC > 0 else { return [] }

        var scoreMatrix = Array(repeating: Array(repeating: 0.0, count: nC), count: nB)
        for i in 0..<nB {
            let threshold = configuration.equivalenceEvaluator.ambiguityThreshold(for: base[i].payload)
            for j in 0..<nC {
                let (score, _) = configuration.scoreMatch(base: base[i], comp: comparison[j])
                if score >= threshold {
                    scoreMatrix[i][j] = score
                }
            }
        }

        let pairs = hungarianMaximize(scoreMatrix)
        return pairs.map { i, j in
            AlignmentBinding(
                baseEventID: base[i].id,
                comparisonEventID: comparison[j].id,
                similarityScore: scoreMatrix[i][j]
            )
        }
    }

    static func greedyBindings<T: TraceableEvent>(
        configuration: AlignmentConfiguration<T>,
        base: [TraceEvent<T>],
        comparison: [TraceEvent<T>]
    ) -> [AlignmentBinding] {
        DefaultTraceMatcher(configuration: configuration).match(
            base: base,
            comparison: comparison,
            evidenceCollector: NullEvidenceCollector()
        )
    }

    static func bindingPairSet(_ bindings: [AlignmentBinding]) -> Set<String> {
        Set(bindings.map { "\($0.baseEventID.uuidString)|\($0.comparisonEventID.uuidString)" })
    }

    static func totalScore(_ bindings: [AlignmentBinding]) -> Double {
        bindings.reduce(0.0) { $0 + $1.similarityScore }
    }
}
