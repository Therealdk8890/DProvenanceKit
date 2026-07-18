import XCTest
@testable import DProvenanceKit

/// The alignment engine has two interpretation paths: the legacy pass (used whenever an
/// evidence artifact is being captured) and the candidate-table fast path (used when
/// `captureMode == .disabled`, the default). These tests hold the two paths equal — same
/// alignments, same regression risk, same meta-trace — across randomized traces, profiles,
/// and perturbations, and pin `scoreOnly` bit-identical to `scoreMatch`. Any divergence
/// means the fast path changed semantics, which is never acceptable for a speedup.
final class AlignmentFastPathParityTests: XCTestCase {

    struct ParityEvent: TraceableEvent {
        let type: String
        let body: String
        let tier: TracePriority
        var typeIdentifier: String { type }
        var priority: TracePriority { tier }
    }

    /// Deterministic PRNG so every run exercises the identical traces.
    struct SplitMix64: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    let baseRunID = UUID(uuidString: "60000000-0000-0000-0000-000000000001")!
    let compRunID = UUID(uuidString: "60000000-0000-0000-0000-000000000002")!

    func makeEvent(runID: UUID, seq: UInt64, type: String, body: String,
                   tier: TracePriority, parentSpanID: String?) -> TraceEvent<ParityEvent> {
        TraceEvent(runID: runID, contextID: "parity", engineName: "parity", schemaVersion: 1,
                   sequence: seq, spanID: nil, parentSpanID: parentSpanID,
                   payload: ParityEvent(type: type, body: body, tier: tier),
                   timestamp: Date(timeIntervalSince1970: 1_752_900_000))
    }

    /// A base trace with controllable matching ambiguity (few distinct types = many same-type
    /// candidates per event) and a sprinkling of critical events and span parents.
    func makeBase(n: Int, distinctTypes: Int, rng: inout SplitMix64) -> TraceRun<ParityEvent> {
        let events = (0..<n).map { i -> TraceEvent<ParityEvent> in
            let tier: TracePriority = (i % 7 == 0) ? .critical : .structural
            let parent: String? = (i % 3 == 0) ? "span_\(i % 5)" : nil
            return makeEvent(runID: baseRunID, seq: UInt64(i), type: "step_\(i % distinctTypes)",
                             body: "body_\(i % max(1, distinctTypes / 2))", tier: tier, parentSpanID: parent)
        }
        return TraceRun(runID: baseRunID, contextID: "parity", events: events)
    }

    /// Drifted payloads, dropped events, inserted events, and one adjacent swap — enough to
    /// exercise matched/removed/added/reordered/ambiguous interpretation states.
    func makeComparison(from base: TraceRun<ParityEvent>, rng: inout SplitMix64) -> TraceRun<ParityEvent> {
        var events = base.events.map { e in
            makeEvent(runID: compRunID, seq: e.sequence, type: e.payload.type, body: e.payload.body,
                      tier: e.payload.tier, parentSpanID: e.parentSpanID)
        }
        let n = events.count
        for _ in 0..<max(1, n / 12) {
            let i = Int(rng.next() % UInt64(events.count))
            let e = events[i]
            events[i] = makeEvent(runID: compRunID, seq: e.sequence, type: e.payload.type,
                                  body: e.payload.body + "_drift", tier: e.payload.tier,
                                  parentSpanID: e.parentSpanID)
        }
        for _ in 0..<max(1, n / 15) {
            events.remove(at: Int(rng.next() % UInt64(events.count)))
        }
        for _ in 0..<max(1, n / 15) {
            let i = Int(rng.next() % UInt64(events.count))
            events.insert(makeEvent(runID: compRunID, seq: UInt64(1_000 + i), type: "inserted_\(i)",
                                    body: "new", tier: .structural, parentSpanID: nil), at: i)
        }
        // TraceRun normalizes to ascending sequence, so a genuine reorder must swap the
        // sequence VALUES of two events, not their array positions.
        let i = Int(rng.next() % UInt64(events.count - 1))
        swapSequences(&events, i, i + 1)
        return TraceRun(runID: compRunID, contextID: "parity", events: events)
    }

    func swapSequences(_ events: inout [TraceEvent<ParityEvent>], _ i: Int, _ j: Int) {
        let a = events[i], b = events[j]
        events[i] = makeEvent(runID: a.runID, seq: b.sequence, type: a.payload.type, body: a.payload.body,
                              tier: a.payload.tier, parentSpanID: a.parentSpanID)
        events[j] = makeEvent(runID: b.runID, seq: a.sequence, type: b.payload.type, body: b.payload.body,
                              tier: b.payload.tier, parentSpanID: b.parentSpanID)
    }

    func makeConfiguration(profile: AlignmentProfile) -> AlignmentConfiguration<ParityEvent> {
        AlignmentConfiguration(
            profile: profile,
            equivalenceEvaluator: AnyEquivalenceEvaluator<ParityEvent>(identifier: "parity-eval") { a, b in
                if a == b { return 1.0 }
                if a.type == b.type { return a.body == b.body ? 0.9 : 0.7 }
                return a.body == b.body ? 0.5 : 0.0
            })
    }

    /// A spanAware profile with every weight nonzero, so the structural and temporal terms
    /// participate in parity too.
    let allWeightsProfile = AlignmentProfile(
        strategy: .developerDebug,
        version: 99,
        typeWeight: 0.35,
        payloadWeight: 0.35,
        structuralWeight: 0.2,
        temporalWeight: 0.1,
        semanticThreshold: 0.8,
        maxAmbiguousCandidates: 4,
        ambiguityDeltaThreshold: 0.15,
        alignmentMode: .spanAware
    )

    var profiles: [(String, AlignmentProfile)] {
        [("strictAuditV1", .strictAuditV1), ("developerDebugV1", .developerDebugV1), ("allWeights", allWeightsProfile)]
    }

    // MARK: - scoreOnly ↔ scoreMatch

    func testScoreOnlyIsBitIdenticalToScoreMatch() {
        var rng = SplitMix64(seed: 7)
        for (name, profile) in profiles {
            let config = makeConfiguration(profile: profile)
            let base = makeBase(n: 80, distinctTypes: 6, rng: &rng)
            let comp = makeComparison(from: base, rng: &rng)
            for b in base.events {
                for c in comp.events {
                    let (full, _) = config.scoreMatch(base: b, comp: c)
                    let fast = config.scoreOnly(base: b, comp: c)
                    // Bit-identical, not approximately equal: the matcher's candidate gate and
                    // greedy ordering are >= / > comparisons on these exact values.
                    XCTAssertEqual(full, fast,
                                   "scoreOnly diverged from scoreMatch under profile \(name) for base seq \(b.sequence) vs comp seq \(c.sequence)")
                }
            }
        }
    }

    // MARK: - Fast path ↔ legacy path

    struct MetaProjection: Equatable {
        let kind: String
        let baseSequence: UInt64?
        let compSequence: UInt64?
        let score: Double?
    }

    /// Strips the per-run randomness (decision node UUIDs, timestamps, meta run IDs) that the
    /// legacy path also regenerates every call, keeping everything decision-relevant.
    func project(_ events: [TraceEvent<AlignmentMetaEvent>]) -> [MetaProjection] {
        events.map { event in
            switch event.payload {
            case .evaluatedPair(_, _, let baseSequence, let compSequence, let score):
                return MetaProjection(kind: "evaluatedPair", baseSequence: baseSequence, compSequence: compSequence, score: score)
            case .ambiguityThresholdMet(_, _, let compSequence, let score):
                return MetaProjection(kind: "ambiguityThresholdMet", baseSequence: nil, compSequence: compSequence, score: score)
            case .candidateEvicted(_, _, let compSequence, let reason):
                return MetaProjection(kind: "candidateEvicted(\(reason))", baseSequence: nil, compSequence: compSequence, score: nil)
            case .regressionDetected(_, _, let level, let reasoning):
                return MetaProjection(kind: "regressionDetected(\(level)|\(reasoning))", baseSequence: nil, compSequence: nil, score: nil)
            }
        }
    }

    final class MetaBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [TraceEvent<AlignmentMetaEvent>] = []
        func append(_ event: TraceEvent<AlignmentMetaEvent>) {
            lock.lock(); defer { lock.unlock() }
            storage.append(event)
        }
        var events: [TraceEvent<AlignmentMetaEvent>] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
    }

    func assertAlignmentsEqual(_ fast: TraceAlignmentResult<ParityEvent>,
                               _ legacy: TraceAlignmentResult<ParityEvent>,
                               context: String) {
        XCTAssertEqual(fast.alignments.count, legacy.alignments.count, "alignment count diverged (\(context))")
        for (f, l) in zip(fast.alignments, legacy.alignments) {
            XCTAssertEqual(f.state, l.state, "state diverged (\(context))")
            XCTAssertEqual(f.baseEvent?.id, l.baseEvent?.id, "base event diverged (\(context))")
            XCTAssertEqual(f.comparisonEvent?.id, l.comparisonEvent?.id, "comparison event diverged (\(context))")
            XCTAssertEqual(f.explanation, l.explanation, "explanation diverged (\(context))")
            XCTAssertEqual(f.ambiguousCandidates.count, l.ambiguousCandidates.count, "ambiguity count diverged (\(context))")
            for (fa, la) in zip(f.ambiguousCandidates, l.ambiguousCandidates) {
                XCTAssertEqual(fa.event.id, la.event.id, "ambiguous candidate diverged (\(context))")
                XCTAssertEqual(fa.strength, la.strength, "ambiguous strength diverged (\(context))")
                XCTAssertEqual(fa.explanation, la.explanation, "ambiguous explanation diverged (\(context))")
            }
        }
        XCTAssertEqual(fast.regressionRisk.level, legacy.regressionRisk.level, "risk level diverged (\(context))")
        XCTAssertEqual(fast.regressionRisk.strength, legacy.regressionRisk.strength, "risk strength diverged (\(context))")
        XCTAssertEqual(fast.regressionRisk.reasoning, legacy.regressionRisk.reasoning, "risk reasoning diverged (\(context))")
    }

    func runParity(n: Int, distinctTypes: Int, seed: UInt64, profileName: String, profile: AlignmentProfile) {
        var rng = SplitMix64(seed: seed)
        let base = makeBase(n: n, distinctTypes: distinctTypes, rng: &rng)
        let comp = makeComparison(from: base, rng: &rng)
        let config = makeConfiguration(profile: profile)
        let context = "profile=\(profileName) n=\(n) types=\(distinctTypes) seed=\(seed)"

        let fastMeta = MetaBox()
        let fastEngine = TraceAlignmentEngine(configuration: config, captureMode: .disabled) { fastMeta.append($0) }
        let fastResult = fastEngine.align(base: base, comparison: comp)

        let legacyMeta = MetaBox()
        let legacyEngine = TraceAlignmentEngine(configuration: config, captureMode: .evidenceOnly) { legacyMeta.append($0) }
        let legacyResult = legacyEngine.align(base: base, comparison: comp)

        assertAlignmentsEqual(fastResult, legacyResult, context: context)
        XCTAssertEqual(project(fastMeta.events), project(legacyMeta.events), "meta-trace diverged (\(context))")
        XCTAssertNil(fastResult.verificationArtifacts, "disabled capture grew an artifact (\(context))")
        XCTAssertNotNil(legacyResult.verificationArtifacts, "evidenceOnly capture lost its artifact (\(context))")
    }

    func testFastPathMatchesLegacyAcrossProfilesAndShapes() {
        for (profileName, profile) in profiles {
            for (n, distinctTypes) in [(40, 40), (60, 5), (90, 3), (120, 10)] {
                for seed: UInt64 in [1, 42, 99] {
                    runParity(n: n, distinctTypes: distinctTypes, seed: seed,
                              profileName: profileName, profile: profile)
                }
            }
        }
    }

    func testFastPathMatchesLegacyOnDegenerateTraces() {
        let config = makeConfiguration(profile: .strictAuditV1)
        let empty = TraceRun<ParityEvent>(runID: baseRunID, contextID: "parity", events: [])
        var rng = SplitMix64(seed: 5)
        let populated = makeBase(n: 12, distinctTypes: 4, rng: &rng)

        for (base, comp, label) in [(empty, empty, "empty/empty"),
                                    (populated, empty, "populated/empty"),
                                    (empty, populated, "empty/populated")] {
            let fast = TraceAlignmentEngine(configuration: config, captureMode: .disabled)
                .align(base: base, comparison: comp)
            let legacy = TraceAlignmentEngine(configuration: config, captureMode: .evidenceOnly)
                .align(base: base, comparison: comp)
            assertAlignmentsEqual(fast, legacy, context: label)
        }
    }

    /// Parity where rival ambiguous candidates actually occur — the one shape the random
    /// generator above cannot produce (its comparisons never have MORE same-type events than
    /// the base, so the matcher binds every one and the rival-admission loop never fires; an
    /// adversarial mutation review proved the other parity tests pass even with that loop
    /// deleted). Here the comparison duplicates same-type events beyond the base count:
    /// identical duplicates give delta == 0 rivals (admitted even by strictAudit's 0.0
    /// delta gate), and near-identical bodies give heterogeneous scores inside the wider
    /// profiles' delta gates. The guards assert rivals genuinely surfaced on the legacy
    /// path, so this scenario can never silently degenerate back into triviality.
    func testFastPathMatchesLegacyWithRivalAmbiguousCandidates() {
        for (profileName, profile) in profiles {
            let config = makeConfiguration(profile: profile)

            var events: [TraceEvent<ParityEvent>] = []
            for i in 0..<24 {
                events.append(makeEvent(runID: baseRunID, seq: UInt64(i), type: "step_\(i % 4)",
                                        body: "body_\(i % 2)", tier: i % 7 == 0 ? .critical : .structural,
                                        parentSpanID: i % 3 == 0 ? "span_\(i % 5)" : nil))
            }
            let base = TraceRun(runID: baseRunID, contextID: "parity", events: events)

            var compEvents = base.events.map { e in
                makeEvent(runID: compRunID, seq: e.sequence, type: e.payload.type, body: e.payload.body,
                          tier: e.payload.tier, parentSpanID: e.parentSpanID)
            }
            // Surplus same-type duplicates: identical payloads (score ties → delta 0) and
            // drifted bodies (near-tie scores → inside the 0.10/0.15 delta gates).
            for i in 0..<6 {
                let template = base.events[i]
                compEvents.append(makeEvent(runID: compRunID, seq: UInt64(100 + i), type: template.payload.type,
                                            body: template.payload.body, tier: .structural,
                                            parentSpanID: template.parentSpanID))
                compEvents.append(makeEvent(runID: compRunID, seq: UInt64(200 + i), type: template.payload.type,
                                            body: template.payload.body + "_drift", tier: .structural,
                                            parentSpanID: template.parentSpanID))
            }
            let comp = TraceRun(runID: compRunID, contextID: "parity", events: compEvents)
            let context = "rival ambiguity, profile=\(profileName)"

            let fastMeta = MetaBox()
            let fastResult = TraceAlignmentEngine(configuration: config, captureMode: .disabled) { fastMeta.append($0) }
                .align(base: base, comparison: comp)
            let legacyMeta = MetaBox()
            let legacyResult = TraceAlignmentEngine(configuration: config, captureMode: .evidenceOnly) { legacyMeta.append($0) }
                .align(base: base, comparison: comp)

            // Guards: the scenario must actually exercise the rival-admission loop. The meta
            // event fires per admitted rival BEFORE `maxAmbiguousCandidates` truncation, so it
            // detects the loop under every profile (strictAuditV1 truncates the final list to
            // one entry, so the count check below only applies to profiles that keep >= 2).
            let legacyRivalMeta = project(legacyMeta.events).filter { $0.kind == "ambiguityThresholdMet" }
            XCTAssertFalse(legacyRivalMeta.isEmpty,
                           "scenario degenerated: no ambiguityThresholdMet meta event fired (\(context))")
            if profile.maxAmbiguousCandidates >= 2 {
                let legacyRivalAlignments = legacyResult.alignments.filter { $0.ambiguousCandidates.count >= 2 }
                XCTAssertFalse(legacyRivalAlignments.isEmpty,
                               "scenario degenerated: no alignment carries a rival candidate (\(context))")
            }

            assertAlignmentsEqual(fastResult, legacyResult, context: context)
            XCTAssertEqual(project(fastMeta.events), project(legacyMeta.events), "meta-trace diverged (\(context))")
        }
    }

    /// Content check on the reorder HIGH verdict: the reasoning string must name the
    /// reordered critical type. Both interpretation paths share the risk pass, so parity
    /// alone can't catch this string being corrupted — assert it directly.
    func testCriticalReorderRiskNamesTheReorderedType() {
        let config = makeConfiguration(profile: .strictAuditV1)
        let baseEvents = [
            makeEvent(runID: baseRunID, seq: 0, type: "authorize", body: "a", tier: .critical, parentSpanID: nil),
            makeEvent(runID: baseRunID, seq: 1, type: "filler", body: "f", tier: .structural, parentSpanID: nil),
            makeEvent(runID: baseRunID, seq: 2, type: "commit", body: "c", tier: .critical, parentSpanID: nil),
        ]
        let base = TraceRun(runID: baseRunID, contextID: "parity", events: baseEvents)
        // Same events, but authorize and commit swap execution order.
        let compEvents = [
            makeEvent(runID: compRunID, seq: 2, type: "authorize", body: "a", tier: .critical, parentSpanID: nil),
            makeEvent(runID: compRunID, seq: 1, type: "filler", body: "f", tier: .structural, parentSpanID: nil),
            makeEvent(runID: compRunID, seq: 0, type: "commit", body: "c", tier: .critical, parentSpanID: nil),
        ]
        let comp = TraceRun(runID: compRunID, contextID: "parity", events: compEvents)

        for captureMode in [VerificationCaptureMode.disabled, .evidenceOnly] {
            let result = TraceAlignmentEngine(configuration: config, captureMode: captureMode)
                .align(base: base, comparison: comp)
            XCTAssertEqual(result.regressionRisk.level, .high, "capture=\(captureMode)")
            XCTAssertEqual(result.regressionRisk.reasoning,
                           "Critical reasoning steps reordered: authorize",
                           "capture=\(captureMode)")
        }
    }

    // MARK: - Matcher ↔ naive reference

    /// The original matcher algorithm, reimplemented naively (full `scoreMatch`, no interning,
    /// no chunking, Set-based greedy) as the oracle for the optimized scan.
    func referenceMatch(config: AlignmentConfiguration<ParityEvent>,
                        base: [TraceEvent<ParityEvent>],
                        comparison: [TraceEvent<ParityEvent>]) -> [AlignmentBinding] {
        var candidates: [(baseIdx: Int, compIdx: Int, score: Double)] = []
        for (i, bEvent) in base.enumerated() {
            let threshold = config.equivalenceEvaluator.ambiguityThreshold(for: bEvent.payload)
            for (j, cEvent) in comparison.enumerated() {
                let (score, _) = config.scoreMatch(base: bEvent, comp: cEvent)
                if score >= threshold {
                    candidates.append((baseIdx: i, compIdx: j, score: score))
                }
            }
        }
        candidates.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.baseIdx != b.baseIdx { return a.baseIdx < b.baseIdx }
            return a.compIdx < b.compIdx
        }
        var bindings: [AlignmentBinding] = []
        var usedBase = Set<Int>()
        var usedComp = Set<Int>()
        for cand in candidates {
            if usedBase.contains(cand.baseIdx) || usedComp.contains(cand.compIdx) { continue }
            usedBase.insert(cand.baseIdx)
            usedComp.insert(cand.compIdx)
            bindings.append(AlignmentBinding(baseEventID: base[cand.baseIdx].id,
                                             comparisonEventID: comparison[cand.compIdx].id,
                                             similarityScore: cand.score))
        }
        return bindings
    }

    /// Pins the optimized matcher (score-only scan, type interning, chunked concurrency,
    /// candidate-table stitch) to the naive reference across profiles, seeds, and chunk
    /// counts — including chunk counts that force empty and single-row chunks.
    func testMatcherMatchesNaiveReferenceAcrossChunkCounts() {
        for (profileName, profile) in profiles {
            let config = makeConfiguration(profile: profile)
            for (n, distinctTypes, seed) in [(70, 5, UInt64(3)), (45, 45, UInt64(17)), (12, 3, UInt64(29))] {
                var rng = SplitMix64(seed: seed)
                let base = makeBase(n: n, distinctTypes: distinctTypes, rng: &rng)
                let comp = makeComparison(from: base, rng: &rng)
                let expected = referenceMatch(config: config, base: base.events, comparison: comp.events)
                let context = "profile=\(profileName) n=\(n) types=\(distinctTypes)"

                var serialIndex: AlignmentCandidateIndex? = nil
                for chunkCount in [1, 3, 8, 64] {
                    let (bindings, index) = DefaultTraceMatcher<ParityEvent>.matchAndIndex(
                        config: config, base: base.events, comparison: comp.events,
                        evidenceCollector: NullEvidenceCollector(), scanChunkCount: chunkCount)
                    XCTAssertEqual(bindings, expected, "bindings diverged from reference (\(context) chunks=\(chunkCount))")
                    XCTAssertEqual(index.rowStart.count, base.events.count + 1, "malformed rowStart (\(context) chunks=\(chunkCount))")
                    XCTAssertEqual(index.rowStart.last, index.compIndices.count, "malformed rowStart total (\(context) chunks=\(chunkCount))")
                    if let serial = serialIndex {
                        XCTAssertEqual(index.compIndices, serial.compIndices, "candidate columns diverged across chunk counts (\(context) chunks=\(chunkCount))")
                        XCTAssertEqual(index.scores, serial.scores, "candidate scores diverged across chunk counts (\(context) chunks=\(chunkCount))")
                        XCTAssertEqual(index.rowStart, serial.rowStart, "rowStart diverged across chunk counts (\(context) chunks=\(chunkCount))")
                    } else {
                        serialIndex = index
                    }
                }
            }
        }
    }

    /// Regression-risk parity on traces engineered to trip each verdict branch: a removed
    /// critical, a critical-vs-critical reorder, and a critical changed beyond equivalence.
    func testFastPathMatchesLegacyOnCriticalRegressions() {
        let config = makeConfiguration(profile: .strictAuditV1)
        func run(_ label: String, mutate: (inout [TraceEvent<ParityEvent>]) -> Void) {
            var rng = SplitMix64(seed: 11)
            let base = makeBase(n: 30, distinctTypes: 30, rng: &rng)
            var events = base.events.map { e in
                makeEvent(runID: compRunID, seq: e.sequence, type: e.payload.type, body: e.payload.body,
                          tier: e.payload.tier, parentSpanID: e.parentSpanID)
            }
            mutate(&events)
            let comp = TraceRun(runID: compRunID, contextID: "parity", events: events)
            let fast = TraceAlignmentEngine(configuration: config, captureMode: .disabled)
                .align(base: base, comparison: comp)
            let legacy = TraceAlignmentEngine(configuration: config, captureMode: .evidenceOnly)
                .align(base: base, comparison: comp)
            assertAlignmentsEqual(fast, legacy, context: label)
        }

        run("removed critical") { events in
            events.removeAll { $0.payload.tier == .critical && $0.sequence == 0 }
        }
        run("reordered criticals") { events in
            let criticals = events.indices.filter { events[$0].payload.tier == .critical }
            if criticals.count >= 2 {
                self.swapSequences(&events, criticals[0], criticals[1])
            }
        }
        run("changed critical") { events in
            if let idx = events.firstIndex(where: { $0.payload.tier == .critical }) {
                let e = events[idx]
                events[idx] = makeEvent(runID: compRunID, seq: e.sequence, type: e.payload.type,
                                        body: "tampered", tier: e.payload.tier, parentSpanID: e.parentSpanID)
            }
        }
    }
}
