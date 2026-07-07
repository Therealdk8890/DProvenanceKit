# Catching a Foundation Models regression

> A runnable end-to-end scenario: an on-device agent silently stops calling its tool
> after an OS/model update, and DProvenanceKit catches it in CI.

This is the failure mode DProvenanceKit exists for. A traditional test suite stays green —
nothing crashes, no error is thrown, the reply is fluent and plausible. But the agent
quietly dropped a step and started answering from the model's prior instead of live data.

Run it:

```sh
swift run FoundationModelsRegressionDemo          # prints the analysis, exits 0
swift run FoundationModelsRegressionDemo --gate   # CI mode: exits non-zero on regression
```

## The scenario

A weather agent, traced through the [Foundation Models adapter](foundation-models.md) via
**post-hoc transcript ingestion** — the same zero-refactor path as
`session.recordProvenance()`, so the demo runs anywhere with no live model required.

- **Before** an OS/model update, the model called `getWeather`, read the live conditions,
  and answered from them.
- **After** the update, the same prompt was answered straight from the model's prior — no
  tool call, no live data. Same shape of reply, silently wrong.

## What it prints

```
BASELINE  (macOS 26.0 · model 2025-09):
  → instructions
  → prompt
  → tool call · getWeather
  → tool output · getWeather
  → response

CANDIDATE (macOS 26.1 · model 2025-11):
  → instructions
  → prompt
  → response

Structural diff (baseline → candidate):
  removed: tool call · getWeather
  removed: tool output · getWeather

Semantic alignment:
  regression risk: HIGH — Critical reasoning steps removed: fm_tool_call

CI gate: ❌ FAILED — reasoning regression detected
```

Two layers catch it:

1. **Structural diff** (`TraceDiffEngine`) — the `getWeather` tool call and its output are
   gone from the candidate's reasoning.
2. **Semantic alignment** (`TraceAlignmentEngine` with the FM equivalence model) — a tool
   call is a `.critical` step, so removing it raises **regression risk `HIGH`**. That's the
   signal a CI gate acts on.

## Failing the build

`--gate` exits non-zero when the risk is `medium` or `high`, so it drops straight into a CI
job — the dropped reasoning step breaks the build the same way a failing test would:

```yaml
# .github/workflows/agent-regression.yml
- run: swift run FoundationModelsRegressionDemo --gate
```

## Seeing the diff

The demo also writes `fm-regression.json` — a [`WebDiffExport`](../WebVisualizer/SCHEMA.md)
document. Open the [WebVisualizer](../WebVisualizer/), click **Load JSON**, and select it to
see the reasoning tree with the dropped tool call struck through in red and the changed
response in amber, alongside the `HIGH` regression-risk pill and drift score.

## How it maps to your code

The demo constructs two `FMTranscriptSnapshot`s by hand so it needs no live model. In a real
app you already have the transcripts — capture them live with `LanguageModelSession.traced`,
or ingest an existing `session.transcript` after the fact with `recordProvenance()`. Either
way you get a `TraceRun<FoundationModelTraceEvent>`, and the rest of this pipeline —
`diff`, `align`, `WebDiffExport.make`, the gate — is identical.

Source: [`Sources/FoundationModelsRegressionDemo/main.swift`](../Sources/FoundationModelsRegressionDemo/main.swift).
