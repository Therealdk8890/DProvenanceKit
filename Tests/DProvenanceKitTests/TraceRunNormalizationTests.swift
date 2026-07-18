import XCTest
@testable import DProvenanceKit

/// Pins the `TraceRun` construction invariant: `events` is always in ascending `sequence`
/// order (ties keep the caller's relative order), so causal analysis can never depend on
/// the order a caller assembled the array. DESIGN.md §2 declares `sequence` authoritative;
/// this is the choke point that makes a hand-assembled run and a store-loaded run holding
/// the same events analyze identically.
final class TraceRunNormalizationTests: XCTestCase {

    private struct Step: TraceableEvent {
        let name: String
        let body: String
        var typeIdentifier: String { name }
        var priority: TracePriority { .critical }
    }

    private func ev(_ seq: UInt64, _ name: String, _ body: String = "b") -> TraceEvent<Step> {
        TraceEvent(runID: UUID(uuidString: "40000000-0000-0000-0000-000000000001")!,
                   contextID: "ctx", engineName: "e", schemaVersion: 1, sequence: seq,
                   spanID: nil, parentSpanID: nil, payload: Step(name: name, body: body), timestamp: Date())
    }

    func testOutOfOrderArrayIsSortedBySequence() {
        let run = TraceRun(runID: UUID(), contextID: "ctx",
                           events: [ev(2, "C"), ev(0, "A"), ev(1, "B")])
        XCTAssertEqual(run.events.map(\.sequence), [0, 1, 2])
        XCTAssertEqual(run.events.map(\.payload.name), ["A", "B", "C"])
    }

    func testAlreadySortedArrayIsPreservedVerbatim() {
        let sorted = [ev(0, "A"), ev(1, "B"), ev(2, "C")]
        let run = TraceRun(runID: UUID(), contextID: "ctx", events: sorted)
        XCTAssertEqual(run.events.map(\.id), sorted.map(\.id))
    }

    func testDuplicateSequencesKeepAssemblyOrder() {
        // Ties must not shuffle: the caller's relative order is the only signal left.
        let first = ev(1, "dup", "first"), second = ev(1, "dup", "second")
        let run = TraceRun(runID: UUID(), contextID: "ctx",
                           events: [ev(2, "tail"), first, second, ev(0, "head")])
        XCTAssertEqual(run.events.map(\.sequence), [0, 1, 1, 2])
        XCTAssertEqual(run.events[1].payload.body, "first")
        XCTAssertEqual(run.events[2].payload.body, "second")
    }

    func testAlignmentIsAssemblyOrderInvariant() {
        // The same events assembled in two different array orders must produce the
        // identical alignment verdict — the property the normalization exists to hold.
        let base = TraceRun(runID: UUID(), contextID: "ctx",
                            events: [ev(0, "authorize", "a"), ev(1, "charge", "c")])
        let shuffled = TraceRun(runID: UUID(), contextID: "ctx",
                                events: [ev(1, "authorize", "a"), ev(0, "charge", "c")])
        let preSorted = TraceRun(runID: shuffled.runID, contextID: "ctx",
                                 events: [ev(0, "charge", "c"), ev(1, "authorize", "a")])

        let config = AlignmentConfiguration(profile: .strictAuditV1,
            equivalenceEvaluator: AnyEquivalenceEvaluator<Step>(identifier: "eq") { a, b in a == b ? 1.0 : 0.0 })
        let engine = TraceAlignmentEngine(configuration: config)

        let fromShuffled = engine.align(base: base, comparison: shuffled)
        let fromSorted = engine.align(base: base, comparison: preSorted)
        // Anchor the expected verdict first — equal-but-both-broken must not pass.
        // Causally, both comparisons ran charge before authorize while the base ran
        // authorize first: a critical inversion, so HIGH.
        XCTAssertEqual(fromShuffled.regressionRisk.level, .high)
        XCTAssertEqual(fromShuffled.regressionRisk.level, fromSorted.regressionRisk.level)
        XCTAssertEqual(fromShuffled.regressionRisk.reasoning, fromSorted.regressionRisk.reasoning)
        XCTAssertEqual(fromShuffled.alignments.map(\.state), fromSorted.alignments.map(\.state))
    }

    func testDiffIsAssemblyOrderInvariant() {
        // The diff engine is the other order-sensitive consumer (it walks the events
        // array with an ordered-collection difference). The same event set assembled
        // out of sequence order must diff as identical to its store-loaded twin —
        // pre-normalization this produced spurious added+removed pairs.
        let sorted = TraceRun(runID: UUID(), contextID: "ctx",
                              events: [ev(0, "authorize", "a"), ev(1, "charge", "c")])
        let shuffled = TraceRun(runID: UUID(), contextID: "ctx",
                                events: [ev(1, "charge", "c"), ev(0, "authorize", "a")])
        let diff = TraceDiffEngine().diff(base: sorted, comparison: shuffled)
        XCTAssertTrue(diff.isIdentical, "same events, same causal order — assembly order must not manufacture changes")
    }
}
