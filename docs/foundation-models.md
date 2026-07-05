# Foundation Models Integration

Apple's FoundationModels framework gives you an on-device LLM. `DProvenanceFoundationModels` gives you its provenance: every prompt, response, tool call, and generation error captured as DProvenanceKit trace events — queryable, diffable, and alignable like any other run. Nothing leaves the device unless you export it.

The module is built around one parity invariant: **live capture and post-hoc ingestion of the same transcript produce byte-exact equal payloads.** Payloads carry no volatile data — no entry ids, no call ids, no timestamps, no UUIDs. The trace envelope owns time; linkage is `(turnIndex, invocationIndex)`. That's what makes FM runs diff cleanly across days, devices, and OS releases.

## The three one-liners

```swift
import DProvenanceFoundationModels
```

**Post-hoc — zero refactor.** After any existing FoundationModels code:

```swift
session.recordProvenance()
```

**Greenfield — live capture, tools traced as child spans:**

```swift
let session = LanguageModelSession.traced(instructions: "Be terse.")
```

**Standalone tool tracing** without a traced session:

```swift
let tool = WeatherTool().traced()
```

All three record into whatever DProvenanceKit run is ambient (`FMTrace.run { ... }`), and are safe no-ops outside one.

## Requirements

Two layers, deliberately split:

| Layer | Availability | Contents |
| ----- | ------------ | -------- |
| Decision layer (ungated) | macOS 13 / iOS 16 — the package floor, no FoundationModels SDK needed | Event vocabulary, payloads, redaction, `FMTranscriptSnapshot` IR, `FMSnapshotMapper`, `FMSnapshotIngestion`, span-path grammar, alignment evaluator |
| SDK bridge (gated) | iOS 26 / macOS 26 / visionOS 26, behind `#if canImport(FoundationModels)`; unavailable on tvOS and watchOS | `TracedLanguageModelSession`, `TracedTool`, `recordProvenance()`, transcript bridging, availability recording |

The split means every mapping, redaction, and pairing decision is testable — and usable, e.g. against serialized transcripts — on machines that have never seen the FoundationModels SDK.

Add the product:

```swift
.product(name: "DProvenanceFoundationModels", package: "DProvenanceKit")
```

The module `@_exported import`s `DProvenanceKit`, so one import gives you both. `FMTrace` is a typealias for `DProvenanceKit<FoundationModelTraceEvent>`.

## Minimal end-to-end example

```swift
import DProvenanceFoundationModels

let store = try SQLiteTraceStore<FoundationModelTraceEvent>(
    fileURL: URL(fileURLWithPath: "traces.sqlite")
)

try await FMTrace.run(contextID: "onboarding-chat", store: store) {
    let session = LanguageModelSession.traced(
        tools: [WeatherTool()],          // wrapped in TracedTool automatically
        instructions: "You are a terse assistant."
    )
    _ = try await session.respond(to: "Should I bring an umbrella tomorrow?")
}

// The run now contains fm_instructions, fm_prompt, fm_tool_call,
// fm_tool_output, and fm_response events — query and diff as usual:
let runs = try await store.queryRuns(
    TraceQueryDSL<FoundationModelTraceEvent>().requiring(step: FMEventType.toolCall)
)
```

## The event vocabulary

`FoundationModelTraceEvent` is the trace vocabulary. Its `typeIdentifier`s and priorities are **frozen** — locked by golden tests, never renamed or reused; payload evolution is additive-optional-fields only.

| `typeIdentifier` | Priority | Payload | Records |
| ---------------- | -------- | ------- | ------- |
| `fm_instructions` | `.structural` | `FMInstructionsPayload` | System instructions, tool names + descriptions (transcript order — sorting would hide reordering regressions) |
| `fm_prompt` | `.critical` | `FMPromptPayload` | Prompt content, `FMGenerationOptionsSnapshot`, response-format name, `turnIndex` |
| `fm_tool_call` | `.critical` | `FMToolCallPayload` | Tool name, raw arguments JSON, `(turnIndex, invocationIndex)` |
| `fm_tool_output` | `.structural` | `FMToolOutputPayload` | Tool name, output content, `isError`, `(turnIndex, invocationIndex)` |
| `fm_response` | `.critical` | `FMResponsePayload` | Response content, asset-ID count |
| `fm_generation_error` | `.critical` | `FMGenerationErrorPayload` | `FMGenerationErrorKind`, redacted message, tool name for tool errors |
| `fm_model_availability` | `.diagnostic` | `FMModelAvailabilityPayload` | Availability, unavailable reason, context size |
| `fm_stream_snapshot` | `.telemetry` | `FMStreamSnapshotPayload` | Snapshot ordinal + content length only — never content |
| `fm_unknown_entry` | `.diagnostic` | `FMUnknownEntryPayload` | Forward-compat for transcript entry kinds this version doesn't know |

`fm_prompt` / `fm_response` / `fm_tool_call` / `fm_generation_error` are `.critical` on purpose: the `TraceAlignmentEngine`'s headline regression rule (removed or reordered steps ⇒ high regression risk) fires only on `.critical` events. Priorities also govern survival under backpressure — stream-snapshot telemetry is shed first, prompts and responses last.

Each event also exposes a `semanticKey` (e.g. `"fm_tool_call:WeatherTool"`, `"fm_generation_error:refusal"`) — compact identity excluding indices and content, for equivalence evaluation.

## The span-path grammar

Span paths are frozen strings, and span ids ARE those strings — the same behavior produces the same `spanID`/`parentSpanID` across runs, which is exactly what the alignment engine's structural term compares:

```
fm.turn.<i>                        turn span (0-based)
fm.turn.<i>.tool.<toolName>.<k>    k-th call of toolName within turn i
fm.tool.<toolName>.<k>             standalone TracedTool invocation
fm[<label>].turn.<i>               with a session label prefix
```

`FMSpanPath` builds these (`turn(_:sessionLabel:)`, `tool(named:invocation:turnIndex:sessionLabel:)`, `standaloneTool(named:invocation:sessionLabel:)`) — it's ungated pure string logic, so trace viewers can parse paths without the SDK. Tracing multiple sessions in one run? Give each a `sessionLabel` in its configuration so their span paths don't collide.

## Capture mode 1: post-hoc ingestion

Zero refactor. Run your existing FoundationModels code, then record the transcript:

```swift
try await FMTrace.run(contextID: "case-review", store: store) {
    let summary = session.recordProvenance()
    print("recorded \(summary.eventCount) events across \(summary.turnCount) turns")
}
```

Also available as `transcript.recordProvenance(...)` and `FMTranscriptIngestion.ingest(_:configuration:startingAt:)` — same path.

The returned `FMIngestionSummary` carries a resume cursor: `nextEntryIndex`. **Plain-session `recordProvenance()` is stateless — calling it twice double-records.** For incremental capture of a growing transcript, feed the cursor back:

```swift
var cursor = 0
// ... after some turns:
cursor = session.recordProvenance(startingAt: cursor).nextEntryIndex
// ... after more turns:
cursor = session.recordProvenance(startingAt: cursor).nextEntryIndex
```

(Or use `TracedLanguageModelSession`, whose `recordProvenance()` dedupes automatically.) When resuming mid-transcript with tool entries involved, resume at turn boundaries — per-turn invocation counters can't be reconstructed mid-turn.

`skippedSegmentCount` in the summary counts transcript segments of kinds this version doesn't understand; nonzero means the SDK grew a segment type the bridge can't yet read.

## Capture mode 2: live sessions

`TracedLanguageModelSession` wraps `LanguageModelSession` by composition (the SDK session is final) and mirrors its full `respond` / `streamResponse` / `prewarm` surface, including the `@PromptBuilder` and `Generable`-typed overloads. Anything not mirrored is reachable through `@dynamicMemberLookup` passthrough, and `session.base` is the untraced escape hatch.

```swift
let session = LanguageModelSession.traced(
    tools: [WeatherTool()],
    instructions: "Be terse.",
    configuration: FMTracingConfiguration(sessionLabel: "planner")
)
let response = try await session.respond(to: "Plan my day.")
```

What a live turn records, in order:

1. On first use (once per session): `fm_model_availability` and `fm_instructions`, both config-gated.
2. The turn span opens (`fm.turn.<i>`); for String prompts, `fm_prompt` is recorded **before** awaiting the model, so it survives a hang or crash.
3. Tool invocations run as child spans (`fm.turn.<i>.tool.<name>.<k>`), recording `fm_tool_call` / `fm_tool_output` live — a tool's own DProvenanceKit events nest under its tool span.
4. On return, the turn is reconciled against the transcript: canonical content always derives from the transcript (the live/post-hoc parity linchpin), and events already recorded live are skipped.
5. On throw, `fm_generation_error` is recorded and the error rethrown unchanged.

One deviation worth knowing: `Prompt` / `@PromptBuilder` overloads have no public text accessor, so their `fm_prompt` is recorded at reconciliation rather than up front. Deterministic per call shape — but migrating a call site from a String prompt to a builder shows a one-time event-order diff in that turn.

Constructors cover every SDK shape: fresh sessions (String, `Instructions`, or `@InstructionsBuilder` instructions), resuming from a `Transcript` (the turn counter seeds from the transcript's prompt count so span paths align with post-hoc ingestion — history is *not* auto-ingested; call `recordProvenance()` for that), and `init(wrapping:)` for a session you already hold. A wrapped session's tools can't be re-wrapped, so its tool events come from post-turn reconciliation instead of live child spans.

### Streaming

`streamResponse` returns a `TracedResponseStream` that yields Apple's cumulative snapshots untouched:

```swift
let stream = session.streamResponse(to: "Write a haiku about SQLite.")
for try await snapshot in stream {
    render(snapshot)
}
// or: let response = try await stream.collect()
```

The turn reconciles exactly once — on natural completion, `collect()`, or a thrown error (`fm_generation_error`, error rethrown). **An abandoned stream records nothing** (no deinit side effects); the documented recovery is `session.recordProvenance()`, which dedupes against everything captured live and backfills the rest.

Per-snapshot telemetry is off by default. Opt in via configuration:

```swift
FMTracingConfiguration(streamSnapshots: .sampled(everyNth: 10))  // or .everySnapshot
```

Snapshots record ordinal and UTF-8 length only — telemetry never carries content.

## Capture mode 3: standalone tools

Any `Tool` can be traced without a traced session:

```swift
let session = LanguageModelSession(tools: [WeatherTool().traced()])
```

`TracedTool` captures the **raw** arguments (`Arguments = GeneratedContent`) before typed decoding — a decode failure is itself evidence and must not lose the `fm_tool_call`; it records the call, a `toolCallError`, and rethrows. The model sees the identical schema because `parameters` forwards the base tool's. Invocations land under `fm.tool.<name>.<k>`.

Standalone mode records via ambient task-locals, which is best-effort: a runtime that detaches tool invocation loses the ambient run. Session-owned wrapping via `TracedLanguageModelSession` is detachment-proof.

## Model availability

```swift
if SystemLanguageModel.default.recordAvailability() {
    // generate
}
```

Records `fm_model_availability` and returns `isAvailable`, so you gate generation on the same check you trace. Unavailable reasons are frozen strings: `"device_not_eligible"`, `"apple_intelligence_not_enabled"`, `"model_not_ready"`, `"unknown"`. Traced sessions record availability automatically on first use (`recordAvailabilityOnFirstUse`).

## Redaction

The default policy is `.full` — on-device capture is the point. If traces leave the device (SQLite exports, cloud stores, [OTel export](otel-bridge.md)), switch to `.hashed`:

```swift
let config = FMTracingConfiguration(redaction: .hashed)
```

Three levels per content field (`FMContentRedaction`):

- `.full` — text, SHA-256, and byte count
- `.hashed` — SHA-256 and byte count only; the text never leaves the process
- `.omitted` — nothing content-derived at all

`FMRedactionPolicy` sets these per field — `promptContent`, `responseContent`, `instructionsContent`, `toolArguments`, `toolOutput`, `errorMessages` — with `.full`, `.hashed`, and `.omitted` presets:

```swift
var policy = FMRedactionPolicy.hashed
policy.errorMessages = .full   // keep error text for debugging
```

The load-bearing detail: **`FMRedactedText` identity is `(sha256, utf8Count)` only.** The hash is SHA-256 over the exact UTF-8 bytes, no normalization, stable across processes and OS releases. So a `.full` trace and a `.hashed` trace of the same content compare *exactly equal* — cross-policy diffing works, including on the alignment engine's exact-equality path. `.omitted` equals only `.omitted`.

## Configuration reference

```swift
FMTracingConfiguration(
    redaction: .full,                    // FMRedactionPolicy
    recorder: .automatic,                // FMEventRecorder — see below
    engineName: "FoundationModels",      // engine attribution when none is ambient
    sessionLabel: nil,                   // span-path prefix: "fm[label].turn.0"
    recordAvailabilityOnFirstUse: true,
    recordInstructions: true,
    streamSnapshots: .off                // .off | .everySnapshot | .sampled(everyNth:)
)
```

A caller-established engine (`withEngine`) is always respected; `engineName` only applies when the engine stack is empty.

### Recorder routes

`FMEventRecorder` decides which typed run FM events land in:

- `.automatic` (default) — tries `DProvenanceKit<FoundationModelTraceEvent>` and `DProvenanceKit<AnyTraceableEvent>`; core's guarded cast guarantees at most one lands.
- `.direct` — `FoundationModelTraceEvent`-typed runs only.
- `.typeErased` — `AnyTraceableEvent` runs, via `eraseToAny()` (deterministic, sorted-keys `rawJSON`).
- `.embedding(MyEvent.self)` — for apps whose own vocabulary embeds FM events as a case:

```swift
enum AppEvent: TraceableEvent, FoundationModelEventEmbedding {
    case foundationModel(FoundationModelTraceEvent)
    case decisionMade(approved: Bool)

    init(foundationModelEvent: FoundationModelTraceEvent) {
        self = .foundationModel(foundationModelEvent)
    }
    // typeIdentifier / priority as usual …
}

let config = FMTracingConfiguration(recorder: .embedding(AppEvent.self))
```

- `FMEventRecorder(record:)` — fully custom routing.

All routes are safe no-ops outside a run.

## Diffing and alignment

`FoundationModelEquivalenceEvaluator` is a deterministic, FM-aware payload similarity for the alignment engine: different `typeIdentifier` scores 0.0; tool events with different names floor at 0.05; equal content identity (hash-based, so it holds cross-policy) scores 1.0; otherwise a token-Jaccard blend with a deliberately weak index term — an inserted early turn shifts every later `turnIndex`, and that alone must not cascade mismatches. Ambiguity thresholds: 0.6 for tool events, 0.5 for prompts/responses, 0.4 otherwise. The evaluator is versioned (`"fm-equivalence-v1"`); a scoring change bumps the identifier.

`FoundationModelAlignment.configuration(profile:)` packages it the way the engine wants:

```swift
let engine = TraceAlignmentEngine(
    configuration: FoundationModelAlignment.configuration(profile: .developerDebugV1)
)
let result = engine.align(base: runA, comparison: runB)
print(result.regressionRisk.level)
```

## Working without the SDK

The decision layer runs anywhere the package does. `FMTranscriptSnapshot` is a Codable, SDK-free mirror of the transcript shape — build one by hand (or decode one that a device serialized), then map or record it:

```swift
let snapshot = FMTranscriptSnapshot(entries: [
    .prompt(text: "What's 2+2?", options: nil, responseFormatName: nil),
    .response(text: "4", assetIDCount: 0)
])

// Pure mapping — payloads + span paths, no recording:
let mapped = FMSnapshotMapper().map(snapshot)

// Or record into the ambient run:
let summary = FMSnapshotIngestion.record(snapshot)
```

On-SDK platforms, `FMTranscriptSnapshot(transcript)` and `FMTranscriptSnapshot(entries:)` bridge from the real types. Entry indices in the snapshot ARE transcript indices.

## Troubleshooting

**Nothing gets recorded.** There's no ambient run — every capture path is a silent no-op outside `FMTrace.run { ... }` (or a compatible run per your recorder route). Check the run's event type against the recorder: `.direct` inside an `AnyTraceableEvent` run records nothing, and vice versa.

**Duplicate events.** Plain-session `recordProvenance()` is stateless; two calls without a `startingAt` cursor record the transcript twice. Use the summary's `nextEntryIndex`, or a `TracedLanguageModelSession` (its `recordProvenance()` dedupes by transcript entry id).

**A stream ended and the response event is missing.** The stream was abandoned before exhaustion/`collect()`. Call `session.recordProvenance()` — that's the documented recovery, and it won't double-record.

**`fm_prompt` order changed after a refactor.** You migrated a String prompt to `Prompt`/`@PromptBuilder`; builder prompts are recorded at reconciliation instead of pre-await. One-time diff, then stable.

**`options` is nil on prompts.** Default `GenerationOptions()` carries no signal and is deliberately omitted. Also note the SDK's `SamplingMode` has no accessors: non-greedy modes map to `.random` with parameters (k / threshold / seed) unrecoverable.

**Tool output paired to the wrong call.** Output pairs to the k-th same-name call in the turn by transcript order — a documented heuristic; the SDK exposes no verified call-id relationship. Distinctly named tools are unambiguous.

**`isError` is always false on post-hoc tool outputs.** Post-hoc ingestion can't observe that a tool threw; only live capture sets `isError: true`.

**`refusalEntryCount` is always nil.** The SDK exposes no accessor for a refusal's transcript entries, and the refusal `explanation` is never fetched — reading it triggers a fresh generation. The field exists for the day the SDK surfaces one.

**`fm_unknown_entry` events or nonzero `skippedSegmentCount`.** A newer OS added transcript entry or segment kinds this module version doesn't know. Unknown entries are preserved (description redacted per the `errorMessages` policy); unknown segments are skipped and counted.
