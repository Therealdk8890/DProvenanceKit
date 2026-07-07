import XCTest
@testable import DProvenanceKit

final class WebDiffExportTests: XCTestCase {

    // MARK: Fixtures

    enum E: TraceableEvent {
        case step(String)
        var typeIdentifier: String { if case .step(let s) = self { return s }; return "" }
        var priority: TracePriority { .structural }
    }

    private let fixedTS = Date(timeIntervalSince1970: 1_700_000_000)

    private func event(_ runID: UUID, _ type: String, seq: UInt64) -> TraceEvent<E> {
        TraceEvent(runID: runID, contextID: "onboarding",
                   engineName: "engine1", schemaVersion: 1, sequence: seq,
                   spanID: nil, parentSpanID: nil, payload: .step(type), timestamp: fixedTS)
    }

    private func run(_ id: UUID, _ types: [String]) -> TraceRun<E> {
        let events = types.enumerated().map { event(id, $0.element, seq: UInt64($0.offset)) }
        return TraceRun(runID: id, contextID: "onboarding", events: events)
    }

    private let exactEvaluator = AnyEquivalenceEvaluator<E>(identifier: "exact") {
        $0.typeIdentifier == $1.typeIdentifier ? 1.0 : 0.0
    }

    // MARK: Engine-driven fidelity (expectations derived from the real alignment)

    func testExportFaithfullyReflectsAlignment() {
        let base = run(UUID(), ["stepA", "stepB", "stepC"])
        let comp = run(UUID(), ["stepA", "stepC", "stepD"])
        let config = AlignmentConfiguration(profile: .strictAuditV1, equivalenceEvaluator: exactEvaluator)
        let alignment = TraceAlignmentEngine(configuration: config).align(base: base, comparison: comp)

        // Count states from the alignment itself so the test doesn't hard-code engine internals.
        var eAdded = 0, eRemoved = 0, eChanged = 0, eUnchanged = 0
        for a in alignment.alignments {
            switch a.state {
            case .added: eAdded += 1
            case .removed: eRemoved += 1
            case .exactMatch: eUnchanged += 1
            case .semanticMatch, .reordered, .ambiguous: eChanged += 1
            }
        }
        let total = eAdded + eRemoved + eChanged + eUnchanged
        let touched = eAdded + eRemoved + eChanged

        let export = WebDiffExport.make(base: base, comparison: comp, alignment: alignment)

        XCTAssertEqual(export.tree.children?.count, alignment.alignments.count)
        XCTAssertEqual(export.metrics.addedNodes, eAdded)
        XCTAssertEqual(export.metrics.removedNodes, eRemoved)
        XCTAssertEqual(export.metrics.changedPaths, touched)
        XCTAssertEqual(export.summary.changedLogicPaths, touched)
        XCTAssertEqual(export.metrics.driftScore, Int((Double(touched) / Double(total) * 100).rounded()))
        XCTAssertEqual(export.tree.type, touched == 0 ? .unchanged : .changed)
        // stepB is .structural, not .critical → no regression risk.
        XCTAssertEqual(export.summary.regressionRisk, "None")
        XCTAssertEqual(export.metrics.risk, "None")
    }

    func testIdenticalRunsHaveZeroDrift() {
        let base = run(UUID(), ["stepA", "stepB", "stepC"])
        let comp = run(UUID(), ["stepA", "stepB", "stepC"])
        let config = AlignmentConfiguration(profile: .strictAuditV1, equivalenceEvaluator: exactEvaluator)

        let export = WebDiffExport.make(base: base, comparison: comp, configuration: config)

        XCTAssertEqual(export.metrics.driftScore, 0)
        XCTAssertEqual(export.metrics.addedNodes, 0)
        XCTAssertEqual(export.metrics.removedNodes, 0)
        XCTAssertEqual(export.summary.changedLogicPaths, 0)
        XCTAssertEqual(export.tree.type, .unchanged)
        XCTAssertEqual(export.tree.children?.allSatisfy { $0.type == .unchanged }, true)
    }

    // MARK: Precise state→kind mapping (synthetic alignment)

    func testEveryAlignmentStateMapsToTheRightNode() {
        let baseID = UUID(), compID = UUID()
        func b(_ t: String) -> TraceEvent<E> { event(baseID, t, seq: 0) }
        func c(_ t: String) -> TraceEvent<E> { event(compID, t, seq: 0) }
        let expl = AlignmentExplanation.none

        let alignments: [EventAlignment<E>] = [
            .init(state: .exactMatch, baseEvent: b("keep"), comparisonEvent: c("keep"), explanation: expl),
            .init(state: .semanticMatch(strength: 0.8), baseEvent: b("Approved"), comparisonEvent: c("Denied"), explanation: expl),
            .init(state: .semanticMatch(strength: 0.8), baseEvent: b("same"), comparisonEvent: c("same"), explanation: expl),
            .init(state: .reordered(originalSequence: 5, newSequence: 2), baseEvent: b("moved"), comparisonEvent: c("moved"), explanation: expl),
            .init(state: .ambiguous(optionsCount: 3), baseEvent: b("query"), comparisonEvent: c("query"), explanation: expl),
            .init(state: .added, baseEvent: nil, comparisonEvent: c("fresh"), explanation: expl),
            .init(state: .removed, baseEvent: b("gone"), comparisonEvent: nil, explanation: expl),
        ]
        let result = TraceAlignmentResult(
            baseRunID: baseID, comparisonRunID: compID,
            profileHash: "p", engineVersion: "test",
            alignments: alignments,
            regressionRisk: RegressionRisk(level: .none, strength: 1.0, reasoning: "n/a")
        )

        let export = WebDiffExport.make(
            base: run(baseID, ["keep"]), comparison: run(compID, ["keep"]),
            alignment: result
        )
        let nodes = export.tree.children ?? []
        XCTAssertEqual(nodes.count, 7)

        XCTAssertEqual(nodes[0].type, .unchanged); XCTAssertNil(nodes[0].details)
        XCTAssertEqual(nodes[1].type, .changed)
        XCTAssertEqual(nodes[1].details, .init(runA: "Approved", runB: "Denied"))   // label change → delta
        XCTAssertEqual(nodes[2].type, .changed); XCTAssertNil(nodes[2].details)     // same-type drift → no delta
        XCTAssertEqual(nodes[3].type, .changed)
        XCTAssertEqual(nodes[3].details, .init(runA: "step 5", runB: "step 2"))     // reordered → positions
        XCTAssertEqual(nodes[4].type, .changed)
        XCTAssertEqual(nodes[4].details, .init(runA: "query", runB: "3 candidates"))
        XCTAssertEqual(nodes[5].type, .added); XCTAssertEqual(nodes[5].label, "fresh")
        XCTAssertEqual(nodes[6].type, .removed); XCTAssertEqual(nodes[6].label, "gone")

        // ids are positional (deterministic)
        XCTAssertEqual(nodes.map(\.id), (1...7).map { "node-\($0)" })
        XCTAssertEqual(export.tree.id, "root")
        // 6 of 7 touched → drift 86, and the root reflects "something changed"
        XCTAssertEqual(export.summary.changedLogicPaths, 6)
        XCTAssertEqual(export.metrics.driftScore, 86)
        XCTAssertEqual(export.tree.type, .changed)
    }

    // MARK: JSON contract, determinism, formatting

    func testJSONRoundTripsAndIsDeterministic() throws {
        let base = run(UUID(), ["stepA", "stepB"])
        let comp = run(UUID(), ["stepA", "stepC"])
        let config = AlignmentConfiguration(profile: .strictAuditV1, equivalenceEvaluator: exactEvaluator)
        let export = WebDiffExport.make(base: base, comparison: comp, configuration: config)

        let data1 = try export.jsonData()
        let data2 = try export.jsonData()
        XCTAssertEqual(data1, data2, "same input must encode to identical bytes")

        let decoded = try JSONDecoder().decode(WebDiffExport.self, from: data1)
        XCTAssertEqual(decoded, export, "encode → decode must round-trip")

        // The viewer hard-requires a typed tree node plus the envelope.
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data1) as? [String: Any])
        XCTAssertNotNil(obj["summary"]); XCTAssertNotNil(obj["metrics"])
        XCTAssertNotNil(obj["timeline"])
        let tree = try XCTUnwrap(obj["tree"] as? [String: Any])
        XCTAssertNotNil(tree["type"])
    }

    func testTimelineDatesAndRunsFormatting() {
        let base = run(UUID(), ["stepA"])
        let comp = run(UUID(), ["stepB"])
        let config = AlignmentConfiguration(profile: .strictAuditV1, equivalenceEvaluator: exactEvaluator)
        let export = WebDiffExport.make(
            base: base, comparison: comp, configuration: config,
            baseLabel: "Baseline", comparisonLabel: "Candidate", corpusRuns: 2847
        )

        XCTAssertEqual(export.timeline.runA.label, "Baseline")
        XCTAssertEqual(export.timeline.runB.label, "Candidate")
        // fixedTS (2023-11-14T22:13:20Z) formatted in UTC as "MMM d, HH:mm"
        XCTAssertEqual(export.timeline.runA.date, "Nov 14, 22:13")
        XCTAssertEqual(export.summary.runs, "2,847")     // thousands separator
    }

    func testEmptyRunHasNoDate() {
        let base = TraceRun<E>(runID: UUID(), contextID: "onboarding", events: [])
        let comp = run(UUID(), ["stepA"])
        let config = AlignmentConfiguration(profile: .strictAuditV1, equivalenceEvaluator: exactEvaluator)
        let export = WebDiffExport.make(base: base, comparison: comp, configuration: config)
        XCTAssertEqual(export.timeline.runA.date, "")
    }

    func testFingerprintIsCorrectFull64BitHash() {
        // Comparison signature is "stepA::engine1|stepB::engine1|stepC::engine1"; its FNV-1a
        // (64-bit) is 6BEC67EE79E290F4. A 32-bit-truncating formatter would drop the high
        // word and yield "0000..." — this pins the full width.
        let comp = run(UUID(), ["stepA", "stepB", "stepC"])
        let base = run(UUID(), ["stepA"])
        let config = AlignmentConfiguration(profile: .strictAuditV1, equivalenceEvaluator: exactEvaluator)
        let fp = WebDiffExport.make(base: base, comparison: comp, configuration: config).summary.structuralFingerprint
        XCTAssertEqual(fp, "6BEC...90F4")
        XCTAssertNotNil(fp.range(of: #"^[0-9A-F]{4}\.\.\.[0-9A-F]{4}$"#, options: .regularExpression))
    }

    func testCorpusRunsIntMinDoesNotTrap() {
        // `grouped()` must be total: `abs(Int.min)` traps, `Int.min.magnitude` does not.
        let base = run(UUID(), ["stepA"])
        let comp = run(UUID(), ["stepA"])
        let config = AlignmentConfiguration(profile: .strictAuditV1, equivalenceEvaluator: exactEvaluator)
        let export = WebDiffExport.make(base: base, comparison: comp, configuration: config, corpusRuns: Int.min)
        XCTAssertEqual(export.summary.runs, "-9,223,372,036,854,775,808")  // handled, not trapped
    }

    func testSlashesInLabelsAreNotEscaped() throws {
        // `.withoutEscapingSlashes` keeps a `/` in a label as a bare slash on every platform.
        let base = run(UUID(), ["a"])
        let comp = run(UUID(), ["http/request"])
        let config = AlignmentConfiguration(profile: .strictAuditV1, equivalenceEvaluator: exactEvaluator)
        let json = try XCTUnwrap(String(data: WebDiffExport.make(base: base, comparison: comp, configuration: config).jsonData(), encoding: .utf8))
        XCTAssertTrue(json.contains("http/request"))
        XCTAssertFalse(json.contains(#"http\/request"#))
    }
}
