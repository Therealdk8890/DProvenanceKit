import Foundation
@testable import DProvenanceKit

struct AdvCaseMetrics {
    let name: String
    let category: String
    let pairingDisagrees: Bool
    let productionPairCount: Int
    let optimalPairCount: Int
    let productionScoreSum: Double
    let optimalScoreSum: Double
    let productionRisk: String
    let optimalRisk: String
    let verdictFlips: Bool
    let highNoneFlip: Bool
    let notes: String
}

struct AdvSuiteReport {
    var cases: [AdvCaseMetrics] = []

    var n: Int { cases.count }

    var disagreementRate: Double {
        guard !cases.isEmpty else { return 0 }
        return Double(cases.filter(\.pairingDisagrees).count) / Double(n)
    }

    var verdictFlipRate: Double {
        guard !cases.isEmpty else { return 0 }
        return Double(cases.filter(\.verdictFlips).count) / Double(n)
    }

    var highNoneFlipRate: Double {
        guard !cases.isEmpty else { return 0 }
        return Double(cases.filter(\.highNoneFlip).count) / Double(n)
    }

    func categorizedFailures() -> [String: [[String: String]]] {
        var out: [String: [[String: String]]] = [:]
        for c in cases where c.pairingDisagrees || c.verdictFlips {
            out[c.category, default: []].append([
                "name": c.name,
                "pairing_disagrees": String(c.pairingDisagrees),
                "verdict_flips": String(c.verdictFlips),
                "high_none_flip": String(c.highNoneFlip),
                "production_risk": c.productionRisk,
                "optimal_risk": c.optimalRisk,
            ])
        }
        return out
    }

    func summaryJSON() -> String {
        let obj: [String: Any] = [
            "n_cases": n,
            "disagreement_rate": disagreementRate,
            "verdict_flip_rate": verdictFlipRate,
            "high_none_flip_rate": highNoneFlipRate,
            "categorized_failures": categorizedFailures(),
            "cases": cases.map { c -> [String: Any] in
                [
                    "name": c.name,
                    "category": c.category,
                    "pairing_disagrees": c.pairingDisagrees,
                    "production_pair_count": c.productionPairCount,
                    "optimal_pair_count": c.optimalPairCount,
                    "production_score_sum": c.productionScoreSum,
                    "optimal_score_sum": c.optimalScoreSum,
                    "production_risk": c.productionRisk,
                    "optimal_risk": c.optimalRisk,
                    "verdict_flips": c.verdictFlips,
                    "high_none_flip": c.highNoneFlip,
                    "notes": c.notes,
                ]
            },
        ]
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return s
    }
}

enum AdvCompare {
    static func filterEvents<T: TraceableEvent>(
        _ events: [TraceEvent<T>],
        minimumPriority: TracePriority
    ) -> [TraceEvent<T>] {
        events
            .filter { $0.payload.priority >= minimumPriority }
            .sorted { $0.sequence < $1.sequence }
    }

    /// Mirror TraceAlignmentEngine regression-risk derivation (test-local; no engine patch).
    static func riskFromAlignments<T: TraceableEvent>(
        configuration: AlignmentConfiguration<T>,
        alignments: [EventAlignment<T>],
        baseEvents: [TraceEvent<T>],
        compEvents: [TraceEvent<T>]
    ) -> RegressionRisk {
        let threshold = configuration.profile.semanticThreshold
        var baseIndexByID: [UUID: Int] = [:]
        for (i, e) in baseEvents.enumerated() where baseIndexByID[e.id] == nil {
            baseIndexByID[e.id] = i
        }
        var compIndexByID: [UUID: Int] = [:]
        for (j, e) in compEvents.enumerated() where compIndexByID[e.id] == nil {
            compIndexByID[e.id] = j
        }

        var removedCriticalTypes: [String] = []
        var changedCriticalTypes: [String] = []
        var criticalPairs: [(baseIdx: Int, compIdx: Int, type: String)] = []

        for a in alignments {
            guard let b = a.baseEvent, b.payload.priority == .critical else { continue }
            guard let c = a.comparisonEvent else {
                removedCriticalTypes.append(b.payload.typeIdentifier)
                continue
            }
            if b.payload != c.payload {
                let (score, _) = configuration.scoreMatch(base: b, comp: c)
                if score < threshold {
                    changedCriticalTypes.append(b.payload.typeIdentifier)
                }
            }
            if let bi = baseIndexByID[b.id], let ci = compIndexByID[c.id] {
                criticalPairs.append((bi, ci, b.payload.typeIdentifier))
            }
        }

        var reorderedCriticalTypes: [String] = []
        for x in criticalPairs {
            if criticalPairs.contains(where: { y in
                x.baseIdx != y.baseIdx && x.baseIdx < y.baseIdx && x.compIdx > y.compIdx
            }) {
                reorderedCriticalTypes.append(x.type)
            }
        }

        if !removedCriticalTypes.isEmpty {
            return RegressionRisk(
                level: .high,
                strength: 0.95,
                reasoning: "Critical reasoning steps removed: \(removedCriticalTypes.joined(separator: ", "))"
            )
        }
        if !reorderedCriticalTypes.isEmpty {
            return RegressionRisk(
                level: .high,
                strength: 1.0,
                reasoning: "Critical reasoning steps reordered: \(reorderedCriticalTypes.joined(separator: ", "))"
            )
        }
        if !changedCriticalTypes.isEmpty {
            return RegressionRisk(
                level: .high,
                strength: 0.9,
                reasoning: "Critical reasoning steps changed beyond equivalence: \(changedCriticalTypes.joined(separator: ", "))"
            )
        }
        return RegressionRisk(
            level: .none,
            strength: 1.0,
            reasoning: "No critical steps removed, reordered, or materially changed."
        )
    }

    static func alignWithBindings<T: TraceableEvent>(
        configuration: AlignmentConfiguration<T>,
        baseEvents: [TraceEvent<T>],
        compEvents: [TraceEvent<T>],
        bindings: [AlignmentBinding]
    ) -> (alignments: [EventAlignment<T>], risk: RegressionRisk) {
        let interpreter = DefaultAlignmentInterpreter(configuration: configuration)
        let semantics = DefaultEquivalenceModel(configuration: configuration)
        let collector = NullEvidenceCollector()
        let alignments = interpreter.interpret(
            base: baseEvents,
            comparison: compEvents,
            bindings: bindings,
            equivalence: { a, b in semantics.evaluate(a, b, evidenceCollector: collector) },
            evidenceCollector: collector
        )
        let risk = riskFromAlignments(
            configuration: configuration,
            alignments: alignments,
            baseEvents: baseEvents,
            compEvents: compEvents
        )
        return (alignments, risk)
    }

    static func evaluateCase(
        configuration: AlignmentConfiguration<AdvEvent>,
        name: String,
        category: String,
        base: TraceRun<AdvEvent>,
        comparison: TraceRun<AdvEvent>,
        minimumPriority: TracePriority = .structural,
        notes: String = ""
    ) -> AdvCaseMetrics {
        let baseEvents = filterEvents(base.events, minimumPriority: minimumPriority)
        let compEvents = filterEvents(comparison.events, minimumPriority: minimumPriority)

        let productionResult = TraceAlignmentEngine(configuration: configuration).align(
            base: base,
            comparison: comparison,
            minimumPriority: minimumPriority
        )
        let prodBindings = AdvOptimalAssignment.greedyBindings(
            configuration: configuration,
            base: baseEvents,
            comparison: compEvents
        )
        let optBindings = AdvOptimalAssignment.optimalBindings(
            configuration: configuration,
            base: baseEvents,
            comparison: compEvents
        )
        let (_, optRisk) = alignWithBindings(
            configuration: configuration,
            baseEvents: baseEvents,
            compEvents: compEvents,
            bindings: optBindings
        )

        let pairingDisagrees =
            AdvOptimalAssignment.bindingPairSet(prodBindings)
            != AdvOptimalAssignment.bindingPairSet(optBindings)
        let prodLevel = productionResult.regressionRisk.level
        let optLevel = optRisk.level
        let verdictFlips = prodLevel != optLevel
        let highNone: Set<RegressionRisk.Level> = [.high, .none]
        let highNoneFlip = verdictFlips && highNone == Set([prodLevel, optLevel])

        return AdvCaseMetrics(
            name: name,
            category: category,
            pairingDisagrees: pairingDisagrees,
            productionPairCount: prodBindings.count,
            optimalPairCount: optBindings.count,
            productionScoreSum: AdvOptimalAssignment.totalScore(prodBindings),
            optimalScoreSum: AdvOptimalAssignment.totalScore(optBindings),
            productionRisk: prodLevel.rawValue,
            optimalRisk: optLevel.rawValue,
            verdictFlips: verdictFlips,
            highNoneFlip: highNoneFlip,
            notes: notes
        )
    }

    static func runSuite(
        configurationFor: (AdvCase) -> AlignmentConfiguration<AdvEvent>,
        cases: [AdvCase]
    ) -> AdvSuiteReport {
        var report = AdvSuiteReport()
        for c in cases {
            report.cases.append(
                evaluateCase(
                    configuration: configurationFor(c),
                    name: c.name,
                    category: c.category,
                    base: c.base,
                    comparison: c.comparison,
                    notes: c.notes
                )
            )
        }
        return report
    }
}
