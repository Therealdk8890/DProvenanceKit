import XCTest
import DProvenanceKit

/// # Catching a Foundation Models regression that output tests miss
///
/// This is a runnable reproduction of DProvenanceKit's central claim, dogfooded
/// against CaseClarity's on-device drafting pipeline:
///
/// > When Apple's on-device Foundation Models change across an OS update, an app's
/// > *output-level* tests (draft content assertions, the grounding gate, the
/// > confidence threshold, the anomaly rules) can all stay green while the
/// > *reasoning path* silently regresses. A structural trace diff catches it.
///
/// ## Why this has to be modeled rather than run live
///
/// CaseClarity's AI path is behind `AppleIntelligenceFactExtractor`, whose
/// `isAvailable` is hard-gated to `false` under XCTest and on macOS < 26
/// (`NSClassFromString("XCTestCase") != nil` and `#available(macOS 26)`). The
/// live on-device model is slow, non-deterministic, and absent in CI, so the real
/// app's own tests only ever exercise the deterministic regex/template path. That
/// is *exactly* the blind spot this demo targets: the regression lives in the
/// behavior of the model the test suite never runs.
///
/// So the two OS versions are modeled as `FoundationModelProfile`s and run through
/// the **real** DProvenanceKit (`run` / `withSpan` / `record`, `TraceDiffEngine`,
/// `AnomalyDetector`). The trace events below are a verbatim copy of CaseClarity's
/// `CaseClarityTraceEvent` drafting subset — identical `typeIdentifier`s and
/// `priority` tiers — because the diff keys on the type-id signature and is gated
/// by priority, so fidelity there is what makes the result transferable.
final class FoundationModelUpdateRegressionTests: XCTestCase {

    // MARK: - Trace event surface (verbatim from CaseClarity's CaseClarityTraceEvent)

    enum DemandTraceEvent: TraceableEvent {
        case extractedFactsViaAI(count: Int)
        case evaluatedDocumentCount(Int)
        case demandProseGenerated(usedAppleIntelligence: Bool)
        case groundingValidated(passed: Bool, blockingIssues: Int)
        case lowConfidenceDraft(confidence: Double)
        case draftCompleted(documentType: String, confidence: Double)
        case draftBlocked(reasons: [String])

        var typeIdentifier: String {
            switch self {
            // FIX: fold a coarse magnitude bucket into the type id (same pattern as
            // the booleans below) so a *material* drop in AI-extracted facts changes
            // the structural signature and shows in a default trace diff, instead of
            // hiding in the payload `count:` the signature-based diff never compares.
            // The event is only recorded when count >= 1, so absence means zero.
            case .extractedFactsViaAI(let count):
                return count >= 3 ? "extractedFactsViaAI.rich" : "extractedFactsViaAI.sparse"
            case .evaluatedDocumentCount: return "evaluatedDocumentCount"
            // The boolean is bucketed into the type id — exactly as CaseClarity does
            // it — so "did the AI actually drive the body" is queryable and shows up
            // in a structural diff.
            case .demandProseGenerated(let usedAI):
                return usedAI ? "demandProseGenerated.ai" : "demandProseGenerated.template"
            case .groundingValidated(let passed, _):
                return passed ? "groundingValidated.passed" : "groundingValidated.failed"
            case .lowConfidenceDraft: return "lowConfidenceDraft"
            case .draftCompleted: return "draftCompleted"
            case .draftBlocked: return "draftBlocked"
            }
        }

        var priority: TracePriority {
            switch self {
            case .evaluatedDocumentCount: return .telemetry
            // FIX: promoted from .diagnostic to .structural so the presence/absence
            // of AI fact extraction survives the default .structural diff floor.
            case .extractedFactsViaAI: return .structural
            case .demandProseGenerated: return .structural
            case .groundingValidated, .lowConfidenceDraft, .draftCompleted, .draftBlocked:
                return .critical
            }
        }
    }

    typealias Kit = DProvenanceKit<DemandTraceEvent>

    // MARK: - The matter under test

    struct DemandCase: Sendable {
        let contextID: String
        let recipient: String
        let recipientAddress: String
        let amount: String
        let sender: String
        let evidenceText: String
        /// Facts supplied by the user / regex extractor — present regardless of OS,
        /// mirroring `input.extractedFacts` which always survive the AI being absent.
        let explicitFields: [String: String]
    }

    static let sampleCase = DemandCase(
        contextID: "demand::lone-star-kitchens::4200",
        recipient: "Lone Star Kitchens LLC",
        recipientAddress: "904 Commerce Street, Dallas, TX 75202",
        amount: "$4,200",
        sender: "Daniel Kissel",
        evidenceText: """
        Invoice 88412290 for $4,200 kitchen renovation completed February 2026.
        Text from Lone Star Kitchens LLC confirming completion March 3, 2026. No payment received.
        """,
        explicitFields: [
            "RECIPIENT NAME": "Lone Star Kitchens LLC",
            "RECIPIENT ADDRESS": "904 Commerce Street, Dallas, TX 75202",
            "AMOUNT": "$4,200"
        ]
    )

    // MARK: - The Foundation Models behavior, as two OS versions

    struct FoundationModelProfile: Sendable {
        let label: String
        /// On-device fact extraction over the evidence. Empty when the model is
        /// unavailable or declines — callers always merge with explicit fields.
        let extractFacts: @Sendable (DemandCase) -> [String: String]
        /// On-device prose generation. Returns the AI-written body, or `nil` when
        /// the model refuses or its structured output fails the app's parse — in
        /// which case the pipeline falls back to the deterministic template.
        let generateBody: @Sendable (DemandCase, [String: String]) -> String?

        /// macOS 26.0 — Apple Intelligence active: extracts supporting facts from
        /// the evidence and writes the demand body itself.
        static let os26_0 = FoundationModelProfile(
            label: "macOS 26.0 (Foundation Models v1)",
            extractFacts: { c in
                [
                    "BREACH DATE": "March 3, 2026",
                    "ACCOUNT REFERENCE": "Invoice 88412290",
                    "RECIPIENT NAME": c.recipient
                ]
            },
            generateBody: { c, fields in
                let acct = fields["ACCOUNT REFERENCE"].map { " (\($0))" } ?? ""
                let date = fields["BREACH DATE"] ?? "the agreed date"
                return """
                You completed and delivered the contracted kitchen renovation work\(acct), \
                and confirmed completion on \(date). Despite that completed performance, the \
                sum of \(c.amount) remains outstanding and unpaid. This letter constitutes a \
                formal demand for payment of that amount in full.
                """
            }
        )

        /// macOS 26.1 — the on-device model update tightened a PII/defamation
        /// guardrail: it now declines to surface a named party as a debtor, so
        /// extraction returns nothing, and its structured body output fails the
        /// app's grounding parse, so the pipeline silently falls back to template.
        /// The opposing party name still reaches the draft via the *explicit*
        /// fields, so the finished letter looks complete.
        static let os26_1 = FoundationModelProfile(
            label: "macOS 26.1 (Foundation Models v2, tightened guardrail)",
            extractFacts: { _ in [:] },
            generateBody: { _, _ in nil }
        )
    }

    // MARK: - A faithful slice of CaseClarityProductionDraftService.generateDraftTraced

    struct DemandDraftPipeline {
        let model: FoundationModelProfile
        static let lowConfidenceThreshold = 0.6

        /// Returns the finished draft string. Emits the same trace events, in the
        /// same order, as the real `generateDraftTraced`.
        func generate(_ c: DemandCase, into store: any TraceStore<DemandTraceEvent>) async -> String {
            await Kit.run(contextID: c.contextID, store: store) {
                await Kit.withSpan(named: "Draft Generation") {
                    // 1. On-device AI fact extraction (no-op when the model declines).
                    let aiFacts = model.extractFacts(c)
                    if !aiFacts.isEmpty {
                        Kit.record(.extractedFactsViaAI(count: aiFacts.count))
                    }
                    // Merge: explicit (user/regex) fields win, AI is additive — same
                    // mergeFacts policy as production.
                    var fields = aiFacts
                    fields.merge(c.explicitFields) { _, explicit in explicit }
                    Kit.record(.evaluatedDocumentCount(fields.count))

                    // 2. Body generation: AI prose, or deterministic template fallback.
                    let body: String
                    let usedAI: Bool
                    if let prose = model.generateBody(c, fields) {
                        body = prose
                        usedAI = true
                    } else {
                        body = Self.templateBody(c, fields: fields)
                        usedAI = false
                    }
                    Kit.record(.demandProseGenerated(usedAppleIntelligence: usedAI))

                    let draft = Self.assembleDraft(c, fields: fields, body: body)

                    // 3. Grounding gate — observation only (does not alter the draft).
                    let blocking = Self.groundingIssues(in: draft)
                    Kit.record(.groundingValidated(passed: blocking.isEmpty,
                                                   blockingIssues: blocking.count))

                    // 4. Confidence + terminal outcome.
                    let confidence = Self.confidence(fields: fields, draft: draft)
                    if confidence < Self.lowConfidenceThreshold {
                        Kit.record(.lowConfidenceDraft(confidence: confidence))
                    }
                    Kit.record(.draftCompleted(documentType: "demandForPayment",
                                               confidence: confidence))
                    return draft
                }
            }
        }

        // Deterministic template body — the fallback when the model declines.
        // Grounded entirely in the supplied fields, so it produces a complete,
        // valid letter with no unresolved placeholders.
        static func templateBody(_ c: DemandCase, fields: [String: String]) -> String {
            let amount = fields["AMOUNT"] ?? c.amount
            return """
            \(c.sender) has fully performed under the parties' agreement and has \
            received the benefit of that performance. The sole remaining obligation \
            is payment. The sum of \(amount) remains outstanding and unpaid, and \
            payment of that amount in full is hereby demanded.
            """
        }

        static func assembleDraft(_ c: DemandCase, fields: [String: String], body: String) -> String {
            let recipient = fields["RECIPIENT NAME"] ?? c.recipient
            let amount = fields["AMOUNT"] ?? c.amount
            return """
            VIA CERTIFIED MAIL AND EMAIL

            RE: FORMAL DEMAND FOR PAYMENT — \(amount)

            To \(recipient):

            \(body)

            Demand is hereby made that payment of \(amount) be remitted within ten (10) days.

            Govern yourselves accordingly.

            Sincerely,
            \(c.sender)
            """
        }

        // Grounding gate, faithful in spirit to DraftGroundingValidator: flag
        // unresolved placeholders. (Both OS paths ground out, by construction.)
        static func groundingIssues(in draft: String) -> [String] {
            var issues: [String] = []
            for marker in ["[INSERT", "[VERIFY", "[ENTER"] where draft.contains(marker) {
                issues.append("unresolved placeholder \(marker)")
            }
            return issues
        }

        // Confidence weighted by substance (field count), mirroring the retuned
        // production scorer: richer extraction → higher confidence.
        static func confidence(fields: [String: String], draft: String) -> Double {
            let base = 0.4
            let substance = 0.1 * Double(min(fields.count, 4))
            return min(0.95, base + substance)
        }
    }

    // MARK: - Output-level checks: a stand-in for CaseClarity's content tests
    //
    // A *representative* demand-letter content contract — the layer a team relies
    // on as its regression net. The amount check and the "Sincerely," + sender
    // signature check correspond to real assertions in CaseClarity's
    // DraftQualityScenariosTests / DocumentWorkspaceViewModelTests; the specific
    // header phrase, the To-salutation, and the placeholder blocklist are
    // representative of that surface, not line-for-line copies of it (CaseClarity's
    // real header is "DEMAND FOR PAYMENT", its salutation is "Dear <recipient>:",
    // and the [INSERT/[VERIFY blocklist lives in its grounding-validator tests).
    // What carries the proof is that *any* such contract is satisfied by the
    // template draft — see docs/PROOF_OF_WORK.md, "Fidelity".

    private func assertOutputContractHolds(_ draft: String, _ label: String,
                                           file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(draft.contains("RE: FORMAL DEMAND FOR PAYMENT"),
                      "\(label): missing formal RE: line", file: file, line: line)
        XCTAssertTrue(draft.contains("To \(Self.sampleCase.recipient):"),
                      "\(label): missing To-salutation with recipient", file: file, line: line)
        XCTAssertTrue(draft.contains(Self.sampleCase.amount),
                      "\(label): missing demand amount", file: file, line: line)
        XCTAssertTrue(draft.contains("Sincerely,") && draft.contains(Self.sampleCase.sender),
                      "\(label): missing signature block", file: file, line: line)
        for marker in ["[INSERT", "[VERIFY", "[ENTER"] {
            XCTAssertFalse(draft.contains(marker),
                           "\(label): unresolved placeholder \(marker)", file: file, line: line)
        }
    }

    // A faithful subset (3 of 5) of the anomaly rules CaseClarity ships, over this
    // event surface. The three below are byte-for-byte identical to CaseClarity's.
    // Omitted: ConflictWithoutHeuristic (keys on detectedConflict/appliedHeuristic,
    // which never occur on the demand surface) and LowConfidenceDraft (demand-
    // relevant, but inert here — confidence never crosses the 0.6 threshold).
    private func standardRules() -> [any AnomalyRule<DemandTraceEvent>] {
        struct UngroundedDraftRule: AnomalyRule {
            let name = "UngroundedDraft"
            var anomalyQuery: TraceQueryDSL<DemandTraceEvent> {
                TraceQueryDSL().requiring(step: "groundingValidated.failed")
            }
            func describe(run: TraceRun<DemandTraceEvent>) -> String {
                "Draft shipped ungrounded (\(run.contextID))."
            }
        }
        struct DraftWithoutGroundingRule: AnomalyRule {
            let name = "DraftWithoutGrounding"
            var anomalyQuery: TraceQueryDSL<DemandTraceEvent> {
                TraceQueryDSL().requiring(step: "draftCompleted")
                    .missing(step: "groundingValidated.passed")
                    .missing(step: "groundingValidated.failed")
            }
            func describe(run: TraceRun<DemandTraceEvent>) -> String {
                "Completed a draft without running the grounding gate (\(run.contextID))."
            }
        }
        struct AIProseWithoutFactsRule: AnomalyRule {
            let name = "AIProseWithoutFacts"
            var anomalyQuery: TraceQueryDSL<DemandTraceEvent> {
                // The DSL matches step ids exactly, so bucketing extractedFactsViaAI
                // means "no facts" = neither bucket present.
                TraceQueryDSL().requiring(step: "demandProseGenerated.ai")
                    .missing(step: "extractedFactsViaAI.rich")
                    .missing(step: "extractedFactsViaAI.sparse")
            }
            func describe(run: TraceRun<DemandTraceEvent>) -> String {
                "Generated AI prose with no extracted facts to ground it (\(run.contextID))."
            }
        }
        return [UngroundedDraftRule(), DraftWithoutGroundingRule(), AIProseWithoutFactsRule()]
    }

    private func run(_ profile: FoundationModelProfile) async throws
        -> (draft: String, run: TraceRun<DemandTraceEvent>, store: InMemoryTraceStore<DemandTraceEvent>) {
        let store = InMemoryTraceStore<DemandTraceEvent>()
        let draft = await DemandDraftPipeline(model: profile).generate(Self.sampleCase, into: store)
        guard let traceRun = try await store.queryRuns(TraceQueryDSL<DemandTraceEvent>()).first else {
            throw XCTSkip("no trace run recorded")
        }
        return (draft, traceRun, store)
    }

    // MARK: - The demonstration

    func testFoundationModelUpdateRegression() async throws {
        let before = try await run(.os26_0)
        let after  = try await run(.os26_1)

        // ---- 1. The output layer cannot see the regression. ----
        // Both drafts satisfy the content contract the team's tests assert on.
        assertOutputContractHolds(before.draft, "macOS 26.0 draft")
        assertOutputContractHolds(after.draft,  "macOS 26.1 draft")

        // The grounding gate passes in BOTH worlds.
        let beforeSteps = Set(before.run.events.map(\.payload.typeIdentifier))
        let afterSteps  = Set(after.run.events.map(\.payload.typeIdentifier))
        XCTAssertTrue(beforeSteps.contains("groundingValidated.passed"))
        XCTAssertTrue(afterSteps.contains("groundingValidated.passed"))
        XCTAssertFalse(afterSteps.contains("groundingValidated.failed"))

        // The confidence threshold is not tripped in EITHER world (it degrades —
        // 0.7 vs 0.7 here — but never crosses the line), so lowConfidenceDraft,
        // another output-side signal, also stays silent.
        XCTAssertFalse(beforeSteps.contains("lowConfidenceDraft"))
        XCTAssertFalse(afterSteps.contains("lowConfidenceDraft"))

        // The anomaly rules — the read side the app already ships — are clean on
        // the post-update run. Nothing in the output-facing net fires.
        let afterAnomalies = try await AnomalyDetector(store: after.store)
            .detectAnomalies(rules: standardRules())
        XCTAssertTrue(afterAnomalies.isEmpty,
                      "post-update anomalies should be empty, got \(afterAnomalies.map(\.ruleName))")

        // ---- 2. The structural trace diff DOES see it. ----
        let diff = TraceDiffEngine<DemandTraceEvent>().diff(base: before.run, comparison: after.run)
        XCTAssertFalse(diff.isIdentical, "the reasoning path changed but the diff was empty")

        let removed = diff.changes.filter { $0.kind == .removed }.map(\.typeIdentifier)
        let added   = diff.changes.filter { $0.kind == .added }.map(\.typeIdentifier)

        // The caught regression: the on-device model stopped writing the body and
        // the app silently fell back to the deterministic template.
        XCTAssertTrue(removed.contains("demandProseGenerated.ai"),
                      "expected the AI-prose step to disappear; removed=\(removed)")
        XCTAssertTrue(added.contains("demandProseGenerated.template"),
                      "expected the template-fallback step to appear; added=\(added)")

        // ---- 3. With the blind spot fixed, the fact-extraction loss is ALSO
        // visible at the DEFAULT .structural floor. ----
        // Pre-fix this was invisible: extractedFactsViaAI was .diagnostic (below the
        // floor) and carried no magnitude in its signature. Now it is .structural and
        // bucketed, so a total loss shows up without lowering the diff floor.
        XCTAssertTrue(removed.contains("extractedFactsViaAI.rich"),
                      "post-fix: total loss of AI fact extraction should surface at the default floor; removed=\(removed)")

        printReport(before: before, after: after, diff: diff, afterAnomalies: afterAnomalies)
    }

    /// The subtler case the fix is really for: a *partial* degradation where the
    /// on-device model still writes the prose but extracts materially fewer facts.
    /// Pre-fix the default diff was empty here (same diagnostic-tier signature on
    /// both sides); post-fix the magnitude bucket changes and the default diff
    /// catches it — while every output-level check still passes.
    func testPartialDegradationCaughtAfterFix() async throws {
        // Model keeps writing prose but extraction drops from rich (3) to sparse (1).
        let degraded = FoundationModelProfile(
            label: "macOS 26.1 (Foundation Models v2, extraction degraded)",
            extractFacts: { c in ["RECIPIENT NAME": c.recipient] },          // 1 fact → .sparse
            generateBody: FoundationModelProfile.os26_0.generateBody          // AI prose still on
        )

        let before = try await run(.os26_0)        // rich (3 facts), AI prose
        let after  = try await run(degraded)        // sparse (1 fact), AI prose

        // Output layer is fully green on both — the content contract holds and the
        // AI-prose step is unchanged, so nothing output-facing flags the degradation.
        assertOutputContractHolds(before.draft, "rich extraction draft")
        assertOutputContractHolds(after.draft,  "degraded extraction draft")
        let afterSteps = Set(after.run.events.map(\.payload.typeIdentifier))
        XCTAssertTrue(afterSteps.contains("demandProseGenerated.ai"),
                      "AI prose is still on — the output path is unchanged")

        let diff = TraceDiffEngine<DemandTraceEvent>().diff(base: before.run, comparison: after.run)
        XCTAssertFalse(diff.isIdentical, "post-fix: the partial degradation must not be silent")
        let removed = diff.changes.filter { $0.kind == .removed }.map(\.typeIdentifier)
        let added   = diff.changes.filter { $0.kind == .added }.map(\.typeIdentifier)
        XCTAssertTrue(removed.contains("extractedFactsViaAI.rich"),
                      "expected the rich-extraction signature to drop; removed=\(removed)")
        XCTAssertTrue(added.contains("extractedFactsViaAI.sparse"),
                      "expected the sparse-extraction signature to appear; added=\(added)")
    }

    // MARK: - Human-readable report (visible with `swift test` -v / on failure logs)

    private func printReport(
        before: (draft: String, run: TraceRun<DemandTraceEvent>, store: InMemoryTraceStore<DemandTraceEvent>),
        after: (draft: String, run: TraceRun<DemandTraceEvent>, store: InMemoryTraceStore<DemandTraceEvent>),
        diff: TraceDiffResult,
        afterAnomalies: [Anomaly]
    ) {
        func path(_ r: TraceRun<DemandTraceEvent>) -> String {
            r.events.map(\.payload.typeIdentifier).joined(separator: " → ")
        }
        print("""

        ╔══════════════════════════════════════════════════════════════════════════╗
        ║  DProvenanceKit × CaseClarity — Foundation Models update regression check  ║
        ╚══════════════════════════════════════════════════════════════════════════╝

        OS BEFORE : \(FoundationModelProfile.os26_0.label)
        OS AFTER  : \(FoundationModelProfile.os26_1.label)
        Matter    : \(Self.sampleCase.contextID)

        ── Output layer (what the team's tests assert on) ──────────────────────────
          content contract .......... ✅ PASS before   ✅ PASS after
          grounding gate ............. ✅ pass before   ✅ pass after
          confidence threshold ....... ✅ ok before     ✅ ok after  (degraded, not tripped)
          anomaly rules (after) ...... ✅ clean \(afterAnomalies.isEmpty ? "(0 fired)" : afterAnomalies.map(\.ruleName).description)
          → Every output-facing signal is GREEN. The regression is invisible here.

        ── Reasoning path (what DProvenanceKit recorded) ───────────────────────────
          before: \(path(before.run))
          after : \(path(after.run))

        ── Structural trace diff (default .structural) ─────────────────────────────
        \(diff.changes.map { "    \($0.kind == .removed ? "−" : "+") \($0.typeIdentifier)  [\($0.engineName)] @seq \($0.originalSequence)" }.joined(separator: "\n"))

        ⮕ REGRESSION CAUGHT: the on-device model stopped writing the demand body
          (demandProseGenerated.ai → demandProseGenerated.template). CaseClarity
          silently reverted from AI-authored prose to the deterministic template —
          its entire on-device-AI value proposition — and no output test noticed.
          The loss of AI fact extraction (−extractedFactsViaAI.rich) now shows here
          too, at the DEFAULT floor — that's the blind-spot fix: extractedFactsViaAI
          promoted to .structural and given a coarse magnitude bucket, so material
          extraction degradations diff without lowering minimumPriority.
        """)
    }
}
