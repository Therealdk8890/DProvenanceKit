import XCTest
@testable import DProvenanceKit

/// Pins the SEMANTICS.md Def 5 / Invariant A/E contract that the `RegressionRisk` verdict
/// must honor: a critical reference step that is removed, reordered relative to another
/// critical, OR bound to a NON-equivalent counterpart is a regression. Before this was
/// enforced here, a materially-changed or skipped critical step bound to a same-type event
/// (type match alone clears the matcher threshold) was filed `.ambiguous` and escaped the
/// verdict entirely — the engine's headline signal missed the regressions it exists to catch.
final class RegressionRiskSoundnessTests: XCTestCase {

    private struct Dec: TraceableEvent {
        let type: String
        let body: String
        let critical: Bool
        var typeIdentifier: String { type }
        var priority: TracePriority { critical ? .critical : .structural }
    }

    private func ev(_ seq: UInt64, _ type: String, _ body: String, critical: Bool = true) -> TraceEvent<Dec> {
        TraceEvent(runID: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
                   contextID: "ctx", engineName: "e", schemaVersion: 1, sequence: seq,
                   spanID: nil, parentSpanID: nil, payload: Dec(type: type, body: body, critical: critical), timestamp: Date())
    }

    /// Payload-equality evaluator: identical ⇒ 1.0, else 0.0. Same-type-different-body pairs
    /// therefore score below the strict threshold — the exact miss condition.
    private func engine() -> TraceAlignmentEngine<Dec> {
        let config = AlignmentConfiguration(profile: .strictAuditV1,
            equivalenceEvaluator: AnyEquivalenceEvaluator<Dec>(identifier: "eq") { a, b in a == b ? 1.0 : 0.0 })
        return TraceAlignmentEngine(configuration: config)
    }

    private func run(_ events: [TraceEvent<Dec>]) -> TraceRun<Dec> {
        TraceRun(runID: UUID(), contextID: "ctx", events: events)
    }

    func testMateriallyChangedCriticalStepFiresHigh() {
        // authorize alice/$100  ->  authorize attacker/$1,000,000 (same type, changed payload).
        let base = run([ev(0, "authorize_payment", #"{"user":"alice","amount":100}"#)])
        let comp = run([ev(0, "authorize_payment", #"{"user":"attacker","amount":1000000}"#)])
        let r = engine().align(base: base, comparison: comp)
        XCTAssertEqual(r.regressionRisk.level, .high, "a tampered critical decision must fire HIGH, not be swallowed as ambiguous")
        XCTAssertTrue(r.regressionRisk.reasoning.contains("changed"))
    }

    func testSkippedCriticalStepMaskedByDecoyFiresHigh() {
        // validate_permissions was skipped and replaced by send_receipt; charge_card unchanged.
        let base = run([ev(0, "decision", "validate_permissions"), ev(1, "decision", "charge_card")])
        let comp = run([ev(0, "decision", "send_receipt"),         ev(1, "decision", "charge_card")])
        let r = engine().align(base: base, comparison: comp)
        XCTAssertEqual(r.regressionRisk.level, .high, "a skipped critical step masked by a same-type decoy must still fire HIGH")
    }

    func testReorderedCriticalWithPayloadDriftFiresHigh() {
        // Canonical Invariant E inversion (invoice before customer), with minor payload drift
        // so each swapped pair scores below the strict threshold (previously => ambiguous => none).
        let eval: @Sendable (Dec, Dec) -> Double = { a, b in
            guard a.type == b.type else { return 0.0 }
            return a.body == b.body ? 1.0 : 0.8
        }
        let config = AlignmentConfiguration(profile: .strictAuditV1,
            equivalenceEvaluator: AnyEquivalenceEvaluator<Dec>(identifier: "e", evaluator: eval))
        let base = run([ev(0, "createCustomer", "alice"), ev(1, "generateInvoice", "100")])
        let comp = run([ev(0, "generateInvoice", "101"), ev(1, "createCustomer", "bob")])
        let r = TraceAlignmentEngine(configuration: config).align(base: base, comparison: comp)
        XCTAssertEqual(r.regressionRisk.level, .high, "a reordered critical pair that also drifts must still fire HIGH")
    }

    func testEquivalentCriticalStepDoesNotFire() {
        // Identical critical step in the same position => equivalent => no regression.
        let base = run([ev(0, "authorize_payment", "same")])
        let comp = run([ev(0, "authorize_payment", "same")])
        let r = engine().align(base: base, comparison: comp)
        XCTAssertEqual(r.regressionRisk.level, .none, "an unchanged critical step must not fire a regression")
    }

    func testSequenceInversionFiresRegardlessOfArrayAssemblyOrder() {
        // A caller may hand the initializer an events array whose order differs from
        // `sequence` order (e.g. events decoded from the caller's own JSON). `sequence`
        // is authoritative (DESIGN.md §2): `TraceRun.init` normalizes the array, so the
        // engine sees the same causal order a store-loaded run would produce. Here the
        // comparison's criticals genuinely inverted causally — B ran before A per
        // `sequence` — even though the caller assembled the array as [A, B]. The verdict
        // must fire, WITH backing `.reordered` findings here: verdict and findings share
        // one index basis over the normalized array, so the verdict can only fire when an
        // array-position inversion exists. (The state label is not always `.reordered` —
        // an inverted pair whose score also falls below the threshold files `.ambiguous`;
        // with identical payloads, as here, the reorder label is guaranteed.)
        let base = run([ev(0, "A", "x"), ev(1, "B", "y")])
        let comp = run([ev(1, "A", "x"), ev(0, "B", "y")])   // assembled [A,B]; causally B ran first
        let r = engine().align(base: base, comparison: comp)

        XCTAssertTrue(r.alignments.contains { $0.state.isReordered }, "the causal inversion must surface as `.reordered` findings")
        XCTAssertEqual(r.regressionRisk.level, .high, "a causal inversion of two criticals must fire HIGH regardless of array assembly order")
        XCTAssertTrue(r.regressionRisk.reasoning.contains("reordered"), "the verdict must name the reorder the findings report")
    }

    func testBenignStructuralReorderDoesNotFireFalseHigh() {
        // A STRUCTURAL (non-critical) step moves past a stationary critical step. The critical
        // step's order relative to other criticals is unchanged, so this must NOT fire HIGH.
        let base = run([ev(0, "log", "x", critical: false), ev(1, "authorize", "a")])
        let comp = run([ev(0, "authorize", "a"),            ev(1, "log", "x", critical: false)])
        let r = engine().align(base: base, comparison: comp)
        XCTAssertEqual(r.regressionRisk.level, .none, "a benign structural move past a stationary critical must not fire a false HIGH")
    }
}
