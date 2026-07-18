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

    func testReorderVerdictAgreesWithReorderFindingsOnUnsortedArrays() {
        // A caller may build a TraceRun whose events array order differs from `sequence`
        // order (nothing sorts it). The reorder VERDICT and the emitted `.reordered` findings
        // must not contradict each other. Here the comparison array order matches the base
        // (A then B) while the two criticals carry swapped sequences — array-index basis sees
        // no inversion, so both must report no reorder. (The earlier sequence-based verdict
        // would have fired a HIGH "reordered" with zero backing `.reordered` findings.)
        let base = run([ev(0, "A", "x"), ev(1, "B", "y")])
        let comp = run([ev(1, "A", "x"), ev(0, "B", "y")])   // array [A,B]; sequences swapped
        let r = engine().align(base: base, comparison: comp)

        // No array-position inversion occurred, and payloads are identical, so there is no
        // regression. The interpreter agrees (no `.reordered` states). The earlier
        // sequence-based verdict fired a spurious HIGH "reordered" here with zero backing
        // `.reordered` findings — this pins that the two now use the same basis.
        XCTAssertFalse(r.alignments.contains { $0.state.isReordered }, "no array-position inversion occurred")
        XCTAssertEqual(r.regressionRisk.level, .none, "verdict must match the (empty) reorder findings, not fire on a sequence-only inversion")
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
