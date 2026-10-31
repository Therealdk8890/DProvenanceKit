# Proof of Work: Local Detection of On-Device AI Behavior Drift

## Thesis

An on-device AI feature can silently change behavior after an OS or model update even when the app's output remains valid. CI cannot reliably reproduce that change: the live model may be unavailable under XCTest, and the behavior change occurs later on a user's device.

**DProvenanceKit provides the trace and structural-diff primitives for detecting a changed execution path locally.** An app can compare a current, privacy-preserving trace with a known-good baseline and surface a meaningful downgrade—such as AI-authored prose being replaced by a deterministic template—without uploading the underlying case data.

This proof demonstrates the trace-diff detection mechanism with deterministic modeled traces. It does **not** yet demonstrate automatic baseline packaging, on-device baseline comparison, or a user-facing drift alert. Those are the product integration steps proposed below.

## The regression

CaseClarity uses Apple's on-device Foundation Models for parts of legal drafting and has a deterministic template fallback. The fallback is useful: it keeps drafting available when the model is unavailable. But a fallback can also conceal a change in product behavior.

The modeled scenario is an OS/model update after which the model no longer supplies fact extraction or demand prose. CaseClarity still creates a complete, grounded letter from explicit user-provided fields and its template path. Output validation remains green, but the source of the work has changed.

| Signal | Before update | After modeled update |
|---|---|---|
| Draft produced | Yes | Yes |
| Demand amount and signature present | Yes | Yes |
| Grounding gate | Pass | Pass |
| Confidence threshold | Not tripped | Not tripped |
| AI fact extraction | Rich | Absent |
| Demand prose source | On-device AI | Template fallback |

This is not a claim that a particular Apple OS release caused this behavior. The two model profiles are deterministic test fixtures, not captures from two live OS versions.

## The trace evidence

The test records the same drafting stages before and after, then compares the traces at the default `.structural` priority floor.

```text
before:
  extractedFactsViaAI.rich
  evaluatedDocumentCount
  demandProseGenerated.ai
  groundingValidated.passed
  draftCompleted

after:
  evaluatedDocumentCount
  demandProseGenerated.template
  groundingValidated.passed
  draftCompleted
```

The structural diff reports:

```text
- demandProseGenerated.ai
- extractedFactsViaAI.rich
+ demandProseGenerated.template
```

The diff does not infer that the output is bad. It shows that the recorded path changed: AI-authored prose disappeared, template-generated prose appeared, and the rich extraction step disappeared. The application can then decide whether that change is acceptable, noteworthy, or blocking.

A second test models partial extraction degradation while AI prose remains enabled:

```text
- extractedFactsViaAI.rich
+ extractedFactsViaAI.sparse
```

That catches a material bucket transition without requiring the output to fail.

## Why not just assert a boolean?

For this exact regression, a direct assertion such as `usedAppleIntelligence == true` would be simpler and cheaper. A metric or “template-generated” badge would also expose this specific fallback. Those are good application-level signals and should not be replaced by trace diffing.

The broader value is different:

- **A boolean answers one preselected question.** A structural trace can expose unanticipated changes across multiple instrumented stages: a missing extraction step, a substituted generation engine, a skipped validation stage, or a changed sequence of work.
- **A metric shows a count or rate.** A trace retains the ordered, contextual path for an individual run, so the app can explain *what changed* rather than only that a rate moved.
- **A badge reports the current mode.** A baseline comparison can report that the current path differs from the previously accepted path, even when the developer did not predict the exact downgrade in advance.

This generalization is bounded: DProvenanceKit can only compare distinctions the application records. It does not discover hidden behavior that has no corresponding event.

## Where detection belongs: on the device

The XCTest fixture validates deterministic mechanics. It cannot validate the live Foundation Models behavior that may change after an OS update. CaseClarity's live model availability check intentionally returns false under XCTest, so a CI run cannot establish what a user's device will do after that update.

The practical deployment model is therefore local runtime comparison:

1. **Capture a known-good baseline.** Record a trace from an accepted app/model/OS configuration for a defined workflow and input class.
2. **Keep the baseline local and versioned.** Bundle or securely retain the baseline with its app version, OS/model context, trace schema version, and input-class metadata.
3. **Record current runs on device.** Emit semantic events for meaningful stages and engine choices. Keep sensitive payloads out of the trace; CaseClarity's current Foundation Models tracing configuration uses hashed redaction.
4. **Compare like with like.** Compare a current trace against the appropriate baseline for the same workflow and compatible input class. Do not treat every difference as a regression.
5. **Surface the result locally.** Show a clear downgrade or drift notice, retain the trace diff for inspection, and let product policy decide whether to warn, request review, or block a workflow.

CaseClarity already has local trace storage and an anomaly-scan entry point. The baseline selection, cross-run runtime comparison, drift classification, and user-facing notification described above are **not established by this proof**. They remain integration work; this document does not claim they are shipped.

## Limits that matter

### Instrumentation is an explicit contract

The diff compares recorded event signatures, not hidden implementation behavior. In this proof, `demandProseGenerated.ai` and `demandProseGenerated.template` are different type identifiers, and `extractedFactsViaAI.rich` and `.sparse` are different identifiers. Those buckets make the distinction visible at the default structural priority.

If the app emits the same event identifier for both paths, omits the event, or records the distinction only in a payload value, the default structural diff may not show it. Instrumentation is therefore a necessary part of the guarantee—not an implementation detail that can be skipped.

### Structural diffing is not payload-level comparison

The default diff compares `typeIdentifier::engineName` signatures for events at `.structural` priority and above. It does not compare payload values. A change from 8 extracted facts to 4 remains invisible if both values map to `.rich`. Use explicit thresholds, finer-grained buckets, or a separate metric/anomaly rule when that distinction matters.

### Input variation can look like drift

A `.rich` to `.sparse` transition may reflect different documents, missing evidence, or user input—not an OS regression. A baseline is meaningful only for comparable runs. In practice, baseline selection should account for workflow, input class, relevant configuration, app version, and OS/model context. Same-input replay is the cleanest comparison; heterogeneous inputs require stratified baselines or carefully defined tolerances.

### This is a mechanism proof, not a field study

The committed tests use one modeled matter and hand-authored model profiles. They establish that, given the emitted event signatures, the default structural diff reports the modeled path change. They do not establish real-world detection rates, false-positive rates, or behavior across live devices and OS releases.

## Reproduce

From the DProvenanceKit repository root:

```bash
swift test --filter FoundationModelUpdateRegression
```

Test file: `Tests/DProvenanceKitTests/FoundationModelUpdateRegressionTests.swift`.

The tests exercise DProvenanceKit's real trace recording, structural diff, and anomaly detector with deterministic profiles. The live Apple model is not invoked.

## What this proves—and what it does not

**Proved here:** a structural trace diff can expose an instrumented path change that leaves the modeled output checks green, including an AI-to-template authoring switch and a rich-to-sparse extraction bucket transition.

**Not proved here:** a live OS-induced regression, automatic on-device baseline comparison, a user-facing alert, broad generalization beyond recorded events, or statistical performance across real user inputs.

The product direction is local-first drift detection: preserve a privacy-conscious record of how the application performed work, compare it against an appropriate accepted baseline on the device, and make unexpected behavior changes visible to the user.
