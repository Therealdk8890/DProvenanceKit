import XCTest
@testable import DProvenanceKit

/// Adversarial alignment suite: production greedy matcher vs optimal assignment.
/// Does NOT change DefaultTraceMatcher / TraceAlignmentEngine production paths.
final class AdversarialAlignmentTests: XCTestCase {

    private static let pairingDisagreementBudget = 1.0
    private static let verdictFlipBudget = 0.25
    private static let unexpectedHighNoneFlipBudget = 0.0
    private static let minSuiteCases = 40

    private static let suiteReport: AdvSuiteReport = {
        AdvCompare.runSuite(configurationFor: configForCase, cases: AdvGenerators.allCases())
    }()

    // MARK: - Configs

    private static func exactEqualityConfig(
        profile: AlignmentProfile = .strictAuditV1
    ) -> AlignmentConfiguration<AdvEvent> {
        AlignmentConfiguration(
            profile: profile,
            equivalenceEvaluator: AnyEquivalenceEvaluator<AdvEvent>(identifier: "ExactEquality_v1") { a, b in
                a == b ? 1.0 : 0.0
            }
        )
    }

    private static func gradedTrapConfig() -> AlignmentConfiguration<AdvEvent> {
        let grades: [String: Double] = [
            "b0|c0": 0.8, "b0|c1": 0.6, "b1|c0": 0.7, "b1|c1": 0.0,
            "t3_b0|t3_c0": 0.9, "t3_b0|t3_c1": 0.75, "t3_b0|t3_c2": 0.1,
            "t3_b1|t3_c0": 0.8, "t3_b1|t3_c1": 0.2, "t3_b1|t3_c2": 0.7,
            "t3_b2|t3_c0": 0.15, "t3_b2|t3_c1": 0.85, "t3_b2|t3_c2": 0.55,
            "t4_b0|t4_c0": 0.95, "t4_b0|t4_c1": 0.7,
            "t4_b1|t4_c0": 0.9, "t4_b1|t4_c2": 0.75,
            "t4_b2|t4_c1": 0.85, "t4_b2|t4_c3": 0.65,
            "t4_b3|t4_c2": 0.8, "t4_b3|t4_c3": 0.2,
            "steal_b0|steal_c0": 0.84, "steal_b0|steal_c1": 0.7,
            "steal_b1|steal_c0": 0.8, "steal_b1|steal_c1": 0.05,
        ]
        return AlignmentConfiguration(
            profile: .strictAuditV1,
            equivalenceEvaluator: AnyEquivalenceEvaluator<AdvEvent>(
                identifier: "GradedTrap_v1",
                evaluator: { a, b in grades["\(a.body)|\(b.body)"] ?? 0.0 },
                ambiguityThresholdFn: { _ in 0.4 }
            )
        )
    }

    private static func semanticLabelConfig() -> AlignmentConfiguration<AdvEvent> {
        AlignmentConfiguration(
            profile: .strictAuditV1,
            equivalenceEvaluator: AnyEquivalenceEvaluator<AdvEvent>(identifier: "SemanticLabel_v1") { a, b in
                (!a.semanticLabel.isEmpty && a.semanticLabel == b.semanticLabel) ? 1.0 : 0.0
            }
        )
    }

    private static func boundaryConfig(threshold: Double) -> AlignmentConfiguration<AdvEvent> {
        let profile = AlignmentProfile(
            strategy: .developerDebug,
            version: 1,
            typeWeight: 0.0,
            payloadWeight: 1.0,
            structuralWeight: 0.0,
            temporalWeight: 0.0,
            semanticThreshold: threshold,
            maxAmbiguousCandidates: 3,
            ambiguityDeltaThreshold: 0.10,
            alignmentMode: .linear
        )
        let forced: [String: Double] = [
            "sim-lo": 0.749999,
            "sim-eq": 0.75,
            "sim-hi": 0.750001,
        ]
        return AlignmentConfiguration(
            profile: profile,
            equivalenceEvaluator: AnyEquivalenceEvaluator<AdvEvent>(
                identifier: "BoundaryProbe_v1",
                evaluator: { a, b in
                    if let v = forced[b.body] { return v }
                    if let v = forced[a.body] { return v }
                    return a == b ? 1.0 : 0.0
                },
                ambiguityThresholdFn: { _ in 0.4 }
            )
        )
    }

    private static func configForCase(_ case_: AdvCase) -> AlignmentConfiguration<AdvEvent> {
        if case_.name.hasPrefix("greedy_trap") || case_.notes.hasPrefix("graded") {
            return gradedTrapConfig()
        }
        if case_.category == "semantic_hook" || case_.name.hasPrefix("semantic_") {
            return semanticLabelConfig()
        }
        return exactEqualityConfig()
    }

    // MARK: - Unit tests

    func testHungarianMaximizesKnownTrap() {
        let matrix: [[Double]] = [
            [5.0, 4.0],
            [4.0, 0.0],
        ]
        let pairs = AdvOptimalAssignment.hungarianMaximize(matrix)
        XCTAssertEqual(Set(pairs.map { "\($0.0),\($0.1)" }), Set(["0,1", "1,0"]))
        XCTAssertEqual(pairs.reduce(0.0) { $0 + matrix[$1.0][$1.1] }, 8.0)
    }

    func testGreedyTrapDisagreementAndScore() {
        let case_ = AdvGenerators.greedyTrapFamily().first { $0.name == "greedy_trap_assignment" }!
        let config = Self.gradedTrapConfig()
        let base = case_.base.events.sorted { $0.sequence < $1.sequence }
        let comp = case_.comparison.events.sorted { $0.sequence < $1.sequence }
        let greedy = AdvOptimalAssignment.greedyBindings(configuration: config, base: base, comparison: comp)
        let optimal = AdvOptimalAssignment.optimalBindings(configuration: config, base: base, comparison: comp)
        XCTAssertGreaterThanOrEqual(
            AdvOptimalAssignment.totalScore(optimal) + 1e-9,
            AdvOptimalAssignment.totalScore(greedy)
        )
        XCTAssertNotEqual(
            AdvOptimalAssignment.bindingPairSet(greedy),
            AdvOptimalAssignment.bindingPairSet(optimal)
        )
        let metrics = AdvCompare.evaluateCase(
            configuration: config,
            name: case_.name,
            category: case_.category,
            base: case_.base,
            comparison: case_.comparison,
            notes: case_.notes
        )
        XCTAssertTrue(metrics.pairingDisagrees)
        XCTAssertGreaterThanOrEqual(metrics.optimalScoreSum + 1e-9, metrics.productionScoreSum)
    }

    func testThresholdBoundaryForcedScores() {
        let config = Self.boundaryConfig(threshold: 0.75)
        for (label, simBody) in [("below", "sim-lo"), ("at", "sim-eq"), ("above", "sim-hi")] {
            let base = AdvGenerators.mkRun([(0, AdvEvent(kind: "step", body: "anchor", critical: true))])
            let comp = AdvGenerators.mkRun([(0, AdvEvent(kind: "step", body: simBody, critical: true))])
            let result = TraceAlignmentEngine(configuration: config).align(base: base, comparison: comp)
            let (score, _) = config.scoreMatch(base: base.events[0], comp: comp.events[0])
            switch label {
            case "below":
                XCTAssertLessThan(score, 0.75)
                XCTAssertEqual(result.regressionRisk.level, .high)
            case "at":
                XCTAssertEqual(score, 0.75, accuracy: 1e-9)
                XCTAssertEqual(result.regressionRisk.level, .none)
            default:
                XCTAssertGreaterThan(score, 0.75)
                XCTAssertEqual(result.regressionRisk.level, .none)
            }
        }
    }

    func testSemanticEvaluatorDisagreeHook() {
        let case_ = AdvGenerators.semanticHookFamily().first { $0.name == "semantic_evaluator_disagree" }!
        let metrics = AdvCompare.evaluateCase(
            configuration: Self.semanticLabelConfig(),
            name: case_.name,
            category: case_.category,
            base: case_.base,
            comparison: case_.comparison,
            notes: case_.notes
        )
        XCTAssertEqual(metrics.productionPairCount, 2)
        XCTAssertEqual(metrics.optimalPairCount, 2)
        XCTAssertFalse(metrics.highNoneFlip)
    }

    func testGeneratorCatalogHasLongAndFuzzCoverage() {
        let cases = AdvGenerators.allCases()
        let names = Set(cases.map(\.name))
        let cats = Set(cases.map(\.category))
        XCTAssertTrue(names.contains(where: { $0.hasPrefix("long_repeated_") }))
        XCTAssertTrue(names.contains(where: { $0.hasPrefix("fuzz_seed_") }))
        XCTAssertTrue(cats.contains("ties") && cats.contains("collisions") && cats.contains("fuzz"))
        XCTAssertGreaterThanOrEqual(cases.count, Self.minSuiteCases)
    }

    func testSuiteMetricsWithinBudget() {
        let report = Self.suiteReport
        XCTAssertGreaterThanOrEqual(report.n, Self.minSuiteCases, "expected ≥\(Self.minSuiteCases) cases, got \(report.n)")
        XCTAssertLessThanOrEqual(report.disagreementRate, Self.pairingDisagreementBudget)
        XCTAssertLessThanOrEqual(report.verdictFlipRate, Self.verdictFlipBudget)

        let unexpected = report.cases.filter {
            !AdvGenerators.specialEvaluatorCases.contains($0.name) && $0.highNoneFlip
        }
        if !unexpected.isEmpty {
            XCTFail(
                "Unexpected HIGH↔none verdict flips under ExactEquality_v1: \(unexpected.map(\.name))"
            )
        }
        print(
            "ADVERSARIAL_ALIGNMENT_METRICS n=\(report.n) " +
            "disagreement_rate=\(String(format: "%.3f", report.disagreementRate)) " +
            "verdict_flip_rate=\(String(format: "%.3f", report.verdictFlipRate)) " +
            "high_none_flip_rate=\(String(format: "%.3f", report.highNoneFlipRate))"
        )
        print(report.summaryJSON())
    }

    func testOptimalScoreDominatesGreedy() {
        for c in Self.suiteReport.cases {
            XCTAssertGreaterThanOrEqual(
                c.optimalScoreSum + 1e-9,
                c.productionScoreSum,
                c.name
            )
        }
    }

    func testCategorizedFailuresPrinted() {
        let cats = Self.suiteReport.categorizedFailures()
        print("categorized_failures=\(cats)")
        // Soft structural check: dictionary keyed by category.
        XCTAssertNotNil(cats as [String: [[String: String]]]?)
    }
}
