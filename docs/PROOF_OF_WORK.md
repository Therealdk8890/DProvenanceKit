# Proof of Work: Catching an Invisible AI-Behavior Regression with a Structural Trace Diff

## Thesis

DProvenanceKit records the *reasoning path* an application took to produce an
output, then diffs that path structurally across two runs. The claim under test
here is narrow and concrete: **a class of AI-behavior regression exists that is
invisible to output-level tests but visible as a structural change in the trace.**
This document walks one such regression end to end — an on-device Foundation
Models OS update that silently downgrades a legal-drafting app from AI-authored
prose to a deterministic template — and shows that every output-facing signal
stays green while the trace diff flags the change. The scenario is modeled on
CaseClarity, a real on-device (Apple Intelligence) legal-drafting app that
consumes DProvenanceKit through a local-path dependency. The reproduction copies
CaseClarity's drafting trace surface (verified identical for seven shared events,
see Fidelity) into DProvenanceKit's own test target; it does not run inside
CaseClarity or invoke its live model. The regression is reproduced in a committed
XCTest; the fidelity to CaseClarity's real trace surface is stated precisely
below — the seven shared drafting events match exactly on type-id and priority,
while the anomaly-rule set is a subset and the output contract is only
representative.

---

## The scenario

CaseClarity drafts formal demand letters on-device using Apple Intelligence
(Foundation Models). When the model is available and behaving, it authors the
demand body from facts it extracted from uploaded documents. When it is not, the
app falls back to a deterministic template so the user still gets a usable draft.
That fallback is a *feature* — it is what keeps the app functional offline, on
older hardware, and under model unavailability.

The regression: an OS update moves the device from macOS 26.0 (Foundation Models
v1) to macOS 26.1 (Foundation Models v2, with a tightened guardrail). The two OS
states are *modeled* as deterministic profiles (see Honest boundaries): under the
profile representing the v2 guardrail, extraction returns nothing and prose
generation returns nil, so the pipeline falls back to the template. This is a
plausible construction of the guardrail's effect, not a live capture of
Apple-model behavior. In the modeled after-state, the on-device model is
represented as declining to author the demand prose for this matter, so
CaseClarity does exactly what it was designed to do — it falls back to the
template — and produces a complete, well-formed, grounded draft. Nothing errors.
Nothing is flagged.

```
OS BEFORE : macOS 26.0 (Foundation Models v1)
OS AFTER  : macOS 26.1 (Foundation Models v2, tightened guardrail)
Matter    : demand::lone-star-kitchens::4200
```

For an on-device-AI app this is the stakes-defining case. The product's
differentiator is that the model wrote the letter. A silent downgrade to a
template means the user is now getting boilerplate while believing they are
getting AI-authored work product — and the downgrade rides in on an OS update the
developer did not ship and cannot pin. There is no crash, no exception, no failing
assertion to page anyone. The behavior changed; the contract did not.

---

## Why output tests can't see it

The proof test asserts on the *output* — a representative demand-letter contract
standing in for CaseClarity's content tests — plus the grounding gate, confidence
threshold, and anomaly rules. On this modeled matter, all of them hold:

```
Output layer (modeled run — stand-in for the team's output tests):
  content contract .......... PASS before   PASS after
  grounding gate ............. pass before   pass after
  confidence threshold ....... ok before     ok after  (0.7 both runs, not tripped)
  anomaly rules (after) ...... clean (0 fired)
  => Every output-facing signal is GREEN. The regression is invisible here.
```

The reason is structural, not incidental. The template path is *good*: it produces
a draft that satisfies the content contract, passes the grounding gate, and stays
above the confidence floor (confidence stays constant — 0.7 before, 0.7 after in
this run — and never crosses the 0.6 threshold, so no `lowConfidenceDraft` is
emitted and no anomaly rule fires). An output test can only assert on properties of
the artifact. Both the AI-authored draft and the template draft have those
properties. The thing that changed — *who wrote the body* — is not a property of
the artifact the output tests inspect. It is a property of the path taken to
produce it.

---

## What DProvenanceKit sees

DProvenanceKit recorded the reasoning path on both runs. The paths differ:

```
before: extractedFactsViaAI.rich -> evaluatedDocumentCount -> demandProseGenerated.ai -> groundingValidated.passed -> draftCompleted
after :                             evaluatedDocumentCount -> demandProseGenerated.template -> groundingValidated.passed -> draftCompleted
```

The default diff is `.structural` — it compares steps at priority `.structural` and
above, keyed on each step's type/engine signature, not on payload values. Run
against these two traces it produces:

```
Structural trace diff (default .structural):
    - demandProseGenerated.ai   @seq 2
    - extractedFactsViaAI.rich  @seq 0
    + demandProseGenerated.template  @seq 1
```

Two structural facts surface here, and both are load-bearing:

- **`demandProseGenerated.ai` → `demandProseGenerated.template`.** The step that
  represents "the on-device model authored the demand body" disappears and is
  replaced by "the template authored it." This is the regression stated in the
  trace's own vocabulary. The signature changed because the bucketed type
  identifier changed (`.ai` vs `.template`), which is exactly the distinction the
  team cares about.

- **`-extractedFactsViaAI.rich`.** The AI fact-extraction step is gone entirely on
  the after-run. With the model declining, there is no rich AI extraction feeding
  the draft. The disappearance of this `.structural` step is itself evidence that
  the AI reasoning path was not taken — the diff shows not just a substituted
  authoring step but a collapsed upstream path.

A second committed test, `testPartialDegradationCaughtAfterFix`, exercises a
subtler variant: the AI prose path stays on, but AI fact extraction degrades from
rich (3 facts) to sparse (1 fact). The output is again fully green, and the default
structural diff still catches it as `-extractedFactsViaAI.rich` /
`+extractedFactsViaAI.sparse`. This works because extraction magnitude is bucketed
into distinct type identifiers (`.rich` / `.sparse`) at `.structural` priority, so
a magnitude change becomes a signature change the diff can see.

---

## Fidelity: why this transfers to the real app

The reproduction is only meaningful if its trace surface, priority tiers, anomaly
rules, and output assertions correspond to CaseClarity's real ones. Here is what
was verified — stated precisely, with the distinction between *identical* and
*representative* called out, because the boundary matters.

**Trace surface — faithful (identical) for the drafting subset.** The test's
`DemandTraceEvent` reproduces the drafting subset of CaseClarity's real
`CaseClarityTraceEvent`. For all seven shared events the `typeIdentifier` bucketing
and `priority` tier match exactly (test
`FoundationModelUpdateRegressionTests.swift:43-76` vs. CaseClarity
`Core/TraceSystem.swift:49-100`):

```
extractedFactsViaAI  : count >= 3 ? ".rich" : ".sparse"      priority .structural   (identical)
demandProseGenerated : usedAI ? ".ai" : ".template"          priority .structural   (identical)
groundingValidated   : passed ? ".passed" : ".failed"        priority .critical     (identical)
lowConfidenceDraft   : "lowConfidenceDraft"                   priority .critical     (identical)
draftCompleted       : "draftCompleted"                       priority .critical     (identical)
draftBlocked         : "draftBlocked"                          priority .critical     (identical)
evaluatedDocumentCount : "evaluatedDocumentCount"             priority .telemetry    (identical)
```

The associated-value payload shapes match too (e.g.
`demandProseGenerated(usedAppleIntelligence:)`,
`groundingValidated(passed:blockingIssues:)`, `draftCompleted(documentType:confidence:)`).
This is a copy of the drafting subset, not the whole enum: CaseClarity's real
`CaseClarityTraceEvent` carries additional cases (conflict detection, strategy
recommendations, viability, etc.) that the demand surface does not touch. That is
what "drafting subset" means and it does not weaken the match for the events in
play.

**Anomaly rules — three of five, faithfully reproduced; the set is a subset, not a
copy.** CaseClarity's shipped `CaseClarityTraceInsights.standardRules()`
(`Core/TraceSystem.swift`) returns **five** rules. The test's `standardRules()`
ships **three** of them, byte-for-byte identical in DSL and using step ids valid on
the demand surface:

- `UngroundedDraftRule` — require `groundingValidated.failed`
- `DraftWithoutGroundingRule` — require `draftCompleted`; miss both
  `groundingValidated.passed` and `groundingValidated.failed`
- `AIProseWithoutFactsRule` — require `demandProseGenerated.ai`; miss both
  `extractedFactsViaAI.rich` and `extractedFactsViaAI.sparse`

It omits two. One omission is faithful: `ConflictWithoutHeuristicRule` keys on
`detectedConflict` / `appliedHeuristic`, which never occur on the demand drafting
surface, so it could never fire here. The other omission is a real gap to
acknowledge: **`LowConfidenceDraftRule` is a shipped, demand-relevant rule that the
test's `standardRules()` drops**, even though the test's own pipeline records
`lowConfidenceDraft` and asserts on it. In this particular run the omission does
not change the result — confidence does not cross the 0.6 threshold (it is 0.7 in
both runs here), so `lowConfidenceDraft` is never emitted and the anomaly set would
be empty with or without the rule. But the honest statement is: the test ships a
*subset* of CaseClarity's anomaly rules, not the same set, and the "anomaly rules
stay clean" claim rests on a rule set that is missing one demand-relevant rule
(which happens to be inert for this input).

**Output assertions — representative, not a faithful mirror.** The proof test's
`assertOutputContractHolds` checks a demand draft for a header, a salutation, the
amount, a signature, and the absence of placeholder tokens. Two of these five
genuinely correspond to CaseClarity's real content tests in
`DraftQualityScenariosTests` / `DocumentWorkspaceViewModelTests`: the **amount**
check and the **"Sincerely," + sender** signature check. The other three do **not**
mirror CaseClarity's actual assertions and should not be read as if they do:

- The test asserts `"RE: FORMAL DEMAND FOR PAYMENT"`. That exact phrase appears
  nowhere in CaseClarity; the real header is `"DEMAND FOR PAYMENT"`, and
  CaseClarity's actual `RE:`-line test checks for invoice number / amount and a
  length bound, not a fixed formal phrase.
- The test asserts a `"To <recipient>:"` salutation. CaseClarity's convention is
  `"Dear <recipient>:"`. A recipient-in-salutation assertion exists in both, but
  the literal differs.
- The test's placeholder blocklist (`[INSERT`, `[VERIFY`, `[ENTER`) does not match
  the named files' token set (`[YOUR NAME]`, `[AMOUNT]`, `[RELIEF REQUESTED]`,
  etc.), and CaseClarity *intentionally permits* `[INSERT AUTHORITIES]` and
  `[ENTER …]` markers. The `[INSERT`/`[VERIFY` blocklist the test uses actually
  lives in CaseClarity's `DraftGroundingValidatorTests` /
  `RealWorldEvidenceDraftingTests`, not the two files the test comment names.

So the output contract in the proof test is a *representative* demand-letter
contract — it plausibly resembles what a demand-letter test would check — but it is
not a line-for-line copy of CaseClarity's regression net. What carries the proof is
not the specific letter surface; it is that *whatever* output contract you assert,
the template draft satisfies it, which is precisely why the regression is invisible
at the output layer. The trace diff is where it becomes visible.

**Library facts — verified.** The mechanics the proof depends on were confirmed in
DProvenanceKit's source:

```
TraceDiffEngine.diff default        : minimumPriority = .structural        (TraceDiffEngine.swift)
priority ordering (low -> high)     : telemetry(0) < diagnostic(1) < structural(2) < critical(3)
structural diff key                 : "<typeIdentifier>::<engineName>"     (payload values NOT compared)
license                             : Apache License 2.0
benchmarks                          : standard corpus 8/8 (P/R/F1 = 1.000);
                                      adversarial suite 5/5 (P/R/F1 = 1.000);
                                      total 13/13 (100%)   [BENCHMARKS.md, post-PR #15]
```

---

## Honest boundaries

This proof establishes a specific thing and not others. Stated plainly:

- **MODELED, not run live.** The live on-device Apple Intelligence model does
  **not** run in this proof. Under CaseClarity's own XCTest suite,
  `AppleIntelligenceFactExtractor.isAvailable` returns `false` before any model
  check because `NSClassFromString("XCTestCase") != nil`, and it also returns
  `false` on macOS < 26 and when Foundation Models is absent. The same
  `XCTestCase` gate is duplicated across the sibling AI services (formalizer,
  demand-body generator, case-brief generator, assistant). So under test, only the
  deterministic regex/template path runs; the live model is never constructed or
  invoked. This is deliberate — the live model is slow and non-deterministic, and a
  regression test must be reproducible. The two OS states in this proof are
  therefore *modeled* trace inputs (`usedAppleIntelligence: true/false`, rich/sparse
  extraction), not captures from two real OS builds. That is the correct choice for
  a deterministic regression test, and it means the proof demonstrates the
  *detection mechanism*, not a live-captured OS regression.

- **Single matter.** The scenario is one matter (`demand::lone-star-kitchens::4200`)
  and two hand-constructed traces per test. It shows the mechanism catches this
  class of change; it is not a statistical claim about false-positive or
  false-negative rates across a corpus of real drafts.

- **Structural (signature-based) diff by design.** The default diff compares
  `typeIdentifier::engineName` signatures at `.structural` priority and above. It
  does not compare payload *values*. That is why magnitude changes only surface
  when they are bucketed into distinct type identifiers (e.g. `.rich` / `.sparse`).
  A degradation that stays within the same bucket, or that lives only in payload
  values below `.structural` priority, would not appear in the default diff. This is
  a design boundary, not a bug — but it means "the diff catches it" depends on the
  app having bucketed the meaningful distinction into the type identifier at a
  visible priority.

What the proof **does** establish: given a drafting trace surface whose type
identifiers and priority tiers are identical to CaseClarity's for the seven shared
events (with a subset of anomaly rules and a representative output contract, as
detailed above), and an output contract that a template draft can satisfy, an
AI-authoring downgrade and an extraction-magnitude degradation both stay green at
the output layer and both appear in the default structural trace diff. What it does
**not** establish: that this was observed on live hardware across a real OS update,
that it generalizes across many matters, or that DProvenanceKit catches regressions
that are not reflected in a step's signature at `.structural` priority or above.

---

## Reproduce it

Run from the DProvenanceKit repository root:

```bash
swift test --filter FoundationModelUpdateRegression
```

Test file:

```
Tests/DProvenanceKitTests/FoundationModelUpdateRegressionTests.swift
```

Both tests pass on current `main` (2/2, 0 failures):
`testFoundationModelUpdateRegression` (the OS-update downgrade) and
`testPartialDegradationCaughtAfterFix` (the rich → sparse extraction degradation).

---

## What this demonstrates about DProvenanceKit

The regression in this proof is invisible at the output layer for a principled
reason: the artifact's properties did not change, only the path that produced it
did. DProvenanceKit's contribution is three concrete mechanisms working together:

1. **Structural diffing** — comparing reasoning paths by step signature, so a
   change in *which* engine did the work (`demandProseGenerated.ai` →
   `.template`) surfaces even when the output is byte-for-byte acceptable.

2. **Priority tiers** — `telemetry < diagnostic < structural < critical`, with the
   default diff drawing the line at `.structural`, so the signal-to-noise ratio is
   controlled by design rather than by hand-filtering every run.

3. **The blind-spot fix, in the app's own instrumentation** — promoting
   `extractedFactsViaAI` to `.structural` and bucketing its magnitude into
   `.rich` / `.sparse` type identifiers. That is what turns a quiet degradation
   into a signature change the default diff can see. The mechanism is only as good
   as the buckets the app draws; this proof shows what the right buckets buy you.
