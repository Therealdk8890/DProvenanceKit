# OpenTelemetry Bridge

DProvenanceKit is the on-device capture layer. `DProvenanceOTel` is how those traces reach the infrastructure you already run: it turns trace runs into standard OTLP/JSON documents and ships them to Langfuse or any OTLP/HTTP collector — zero dependencies, deterministic output, honest receipts.

One `TraceRun` becomes one OTel trace: a root span, child spans for every DPK span, span events for every trace event. IDs are derived deterministically from DPK identifiers, so the same run always maps to the same trace and re-exports are byte-identical (scope of that claim below).

This is the open-source, in-process exporter, licensed Apache 2.0 like the rest of the library. The hosted/managed pipeline — shared team traces, CI gates, monitoring — is the separate commercial layer described in [COMMERCIAL.md](../COMMERCIAL.md).

## Backend support matrix

OTLP/JSON is a first-class OTLP encoding, but per-backend acceptance varies:

| Backend | Direct export | Notes |
| ------- | ------------- | ----- |
| **Langfuse** | ✅ | Accepts OTLP HTTP/JSON directly — cloud (all regions) and self-hosted ≥ v3.22.0. Use `Configuration.langfuse`. |
| **otel-collector** | ✅ | The stock collector's OTLP/HTTP receiver accepts JSON. Use `Configuration.collector`. |
| **Arize Phoenix** | ❌ | Its `/v1/traces` handler returns HTTP 415 for any Content-Type other than `application/x-protobuf`. Route through a collector relay (recipe below). |

The collector relay is the universal fallback for any backend that rejects OTLP/JSON.

## Minimal end-to-end example

```swift
import DProvenanceKit
import DProvenanceOTel

let exporter = OTLPHTTPExporter<MyAIDecision>(
    configuration: .langfuse(
        publicKey: "pk-lf-...",
        secretKey: "sk-lf-..."
    )
)

let receipt = try await DProvenanceOTelExport.export(from: store, using: exporter)
print("exported \(receipt.runsExported) runs as \(receipt.spanCount) spans")
```

`DProvenanceOTelExport.export(from:matching:using:)` queries the store (an empty `TraceQueryDSL` matches every run), orders runs deterministically by first-event timestamp, and hands them to the exporter. To export a subset:

```swift
let receipt = try await DProvenanceOTelExport.export(
    from: store,
    matching: TraceQueryDSL<MyAIDecision>().filter(contextID: "Case-12345"),
    using: exporter
)
```

Or drive an exporter directly with hand-picked runs: `try await exporter.export(runs)`.

## Wiring: Langfuse

`Configuration.langfuse` encodes exactly what Langfuse's OTLP endpoint expects:

- **Endpoint:** `<host>/api/public/otel/v1/traces`
- **Auth header:** `Authorization: Basic base64("<publicKey>:<secretKey>")` — HTTP Basic over the project key pair, not a bearer token.

```swift
// EU (default host, cloud.langfuse.com):
let config = OTLPHTTPExporter<MyAIDecision>.Configuration.langfuse(
    publicKey: "pk-lf-...", secretKey: "sk-lf-..."
)

// US region:
let usConfig = OTLPHTTPExporter<MyAIDecision>.Configuration.langfuse(
    host: URL(string: "https://us.cloud.langfuse.com")!,
    publicKey: "pk-lf-...", secretKey: "sk-lf-..."
)
```

| Region | Host |
| ------ | ---- |
| EU (default) | `https://cloud.langfuse.com` |
| US | `https://us.cloud.langfuse.com` |
| Japan | `https://jp.cloud.langfuse.com` |
| HIPAA | `https://hipaa.cloud.langfuse.com` |
| Self-hosted (≥ v3.22.0) | your base URL |

Langfuse classifies spans as *generations* from `gen_ai.*` **span** attributes — which is why GenAI promotion (below) defaults to dedicated child spans.

## Wiring: otel-collector and friends

```swift
let config = OTLPHTTPExporter<MyAIDecision>.Configuration.collector(
    endpoint: URL(string: "http://localhost:4318")!,
    headers: ["x-api-key": "..."]        // sent verbatim
)
```

The endpoint is normalized: trailing slashes trimmed, `/v1/traces` appended iff not already the suffix — so both `http://host:4318` and `http://host:4318/v1/traces` work. Headers are sent verbatim; `Content-Type: application/json` is owned by the exporter and always set.

## Wiring: Arize Phoenix (via relay)

Phoenix only accepts protobuf, so re-encode through a stock otel-collector:

```yaml
receivers:
  otlp:
    protocols:
      http:            # accepts this exporter's JSON
exporters:
  otlp/phoenix:
    endpoint: phoenix:4317   # protobuf out
service:
  pipelines:
    traces:
      receivers: [otlp]
      exporters: [otlp/phoenix]
```

Point `Configuration.collector` at the relay's HTTP port.

## Exporting to a file

`OTLPFileExporter` writes one OTLP/JSON document per export — useful for CI artifacts, offline inspection, or feeding a collector's file receiver:

```swift
let exporter = OTLPFileExporter<MyAIDecision>(
    destination: URL(fileURLWithPath: "run-export.json")
)
let receipt = try await exporter.export(runs)
```

Byte-stable re-exports require: identical runs in identical order, same options (including the `dropStats` snapshot), and the same OS/Foundation version — `Double` formatting is stable per Foundation release, not across them.

## How runs map to traces

The mapper (`OTelSpanMapper`) is pure, non-throwing, and deterministic:

- **One run, one trace.** The root span is named by `options.rootSpanName` (default: the run's `contextID`; an empty result falls back to `"run "` + the first 8 hex of the traceId).
- **DPK spans become child spans.** DPK spans exist only as `(spanID, parentSpanID)` stamps on member events, so a `withSpan` wrapper that recorded nothing appears only in its children's `parentSpanID` — such parents are *synthesized* as placeholder spans (flagged `dpk.synthesized`) rather than dropped, preserving the recorded nesting. Self-parents, member disagreement, and hand-assembled cycles are broken deterministically and flagged `dpk.parent_conflict`.
- **Events become span events** on their span (or promoted to spans — next section), ordered by sequence.
- **The output is always a tree** rooted at the root span — nothing dangles.
- **Ordering never depends on dictionary iteration:** root first, then spans by minimum sequence over members-or-descendants (ties broken by spanId hex), span events by sequence, attributes in fixed documented orders. Combined with sorted-keys JSON encoding, this is what makes re-exports byte-identical.
- **Timestamps** are uint64 nanoseconds as decimal strings, truncated (never rounded) to match `SQLiteTraceStore`'s microsecond write path — in-memory and SQLite-backed exports of the same event agree.
- **A payload that fails re-encoding never fails the export:** the span event carries `dpk.payload_error = "encoding_failed"` instead, mirroring DPK's record-never-throws philosophy.

### Deterministic identity

`OTelTraceIdentity` derives every ID as a pure function of DPK identifiers — any tool can compute a run's OTel traceId offline, and a span that was synthesized in one export keeps its ID if it gains events in a later one:

```
traceID(forRun:)              SHA256("dpk-otel:v1:trace:" + runID)[0..<16]   32 hex
rootSpanID(forRun:)           SHA256("dpk-otel:v1:root:"  + runID)[0..<8]    16 hex
spanID(forRun:dpkSpanID:)     SHA256("dpk-otel:v1:span:"  + runID + ":" + dpkSpanID)[0..<8]
eventSpanID(forRun:sequence:) SHA256("dpk-otel:v1:event:" + runID + ":" + sequence)[0..<8]
```

Preimages use the lowercased UUID. The `v1` prefix is `OTelBridge.idSchemeVersion`, frozen by known-answer tests; every document is stamped with the instrumentation scope `OTelBridge.scopeName` / `OTelBridge.version`.

### The `dpk.*` attribute namespace

All keys live in `DPKOTelAttribute` — dashboards should reference the constants, not string literals:

| Attribute | Where | Meaning |
| --------- | ----- | ------- |
| `dpk.run_id`, `dpk.context_id`, `dpk.schema_version`, `dpk.event_count` | root span | Run identity |
| `dpk.type_identifier`, `dpk.sequence`, `dpk.priority`, `dpk.engine` | span events | Event envelope |
| `dpk.payload`, `dpk.payload_truncated`, `dpk.payload_error` | span events | Re-encoded payload JSON; truncation/encode-failure flags |
| `dpk.span_id`, `dpk.parent_span_id` | child spans | Original DPK span strings (survive any `childSpanName` override) |
| `dpk.synthesized`, `dpk.parent_conflict` | child spans | Structural repair flags |
| `dpk.drop_stats.telemetry` / `.diagnostic` / `.structural` / `.critical` / `.total`, `dpk.drop_stats.preserved_integrity` | resource | Opt-in drop-accounting snapshot |

Payload inclusion is configurable: `.full`, `.truncated(maxBytes:)` (default, 32 KiB, cut on a UTF-8 boundary; `dpk.payload_truncated` appears only when a cut actually happened), or `.omitted`. Pair `.omitted` or DPK-side [hashed redaction](foundation-models.md#redaction) with exports when trace content shouldn't reach the backend.

Mirror the store's drop tally onto the resource so the backend can see whether an export is structurally complete:

```swift
var options = OTelExportOptions<MyAIDecision>()
options.dropStats = store.dropStats   // store-scoped snapshot at export time
```

## GenAI semantic conventions

Backends like Langfuse recognize LLM activity through `gen_ai.*` semantic-convention attributes. Two ways to attach them:

**1. Conformance** — your payload type adopts `OTelSemanticsProviding`:

```swift
extension MyAIDecision: OTelSemanticsProviding {
    var otelSemantics: GenAIAttributes? {
        guard case .promptGenerated = self else { return nil }
        return GenAIAttributes(operationName: "chat", providerName: "my-engine")
    }
    var otelEventName: String? { nil }   // optional display-name override
}
```

**2. Closure fallback** — for payload types you can't extend:

```swift
options.semanticAttributes = { event in
    event.payload.typeIdentifier == "llm_response"
        ? GenAIAttributes(operationName: "chat")
        : nil
}
```

Conformance wins; the closure is consulted only when `otelSemantics` returns nil.

`GenAIAttributes` covers `gen_ai.operation.name`, `gen_ai.request.model`, `gen_ai.response.model`, `gen_ai.tool.name`, `gen_ai.provider.name`, `gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens`, plus an `extra` list for anything else (strings/ints/bools/doubles only — no arrays or kvlists in v1).

**Promotion.** By default (`GenAIPromotion.dedicatedChildSpan`), each semantics-bearing event is materialized as its *own child span* — because Langfuse and other GenAI-aware backends read `gen_ai.*` from span attributes only; on span events they're invisible. Promoted inference spans are `CLIENT` kind; `execute_tool` operations are `INTERNAL` (tool execution happens in-process). `GenAIPromotion.attachedToEventOnly` is the escape hatch that merges the attributes onto the span event instead — correct OTLP, invisible to Langfuse's generation mapping.

## Export options reference

```swift
var options = OTelExportOptions<MyAIDecision>()
options.serviceName        // "dprovenancekit"          — service.name resource attribute
options.resourceAttributes // []                        — appended after the fixed set
options.dropStats          // nil                       — opt-in drop tally snapshot
options.rootSpanName       // { $0.contextID }
options.childSpanName      // identity                  — dpk.span_id survives any override
options.payloadInclusion   // .truncated(maxBytes: 32_768)
options.genAIPromotion     // .dedicatedChildSpan
options.semanticAttributes // nil                       — closure fallback for gen_ai.*
options.rootStatus         // nil                       — nil means UNSET; children always UNSET
```

Pass options to any exporter init, or use `OTelSpanMapper(options:)` directly for the document without transport: `mapper.document(for: runs)` / `mapper.spans(for: run)`. `OTLPJSON.encode(_:deterministic:)` produces the bytes.

## Transport behavior (HTTP exporter)

- **Chunking:** runs ship in independent documents of `maxRunsPerRequest` (default 50), POSTed separately.
- **Timeout:** 30 s per request by default.
- **Retries:** `retryAttempts` (default 0) applies only to the OTLP retryable set — 429/502/503/504 and transport errors — with exponential backoff, jitter, and `Retry-After` honored. Other 5xx and all other 4xx fail fast *on purpose*: retrying a 500 re-POSTs documents that may have been partially ingested, which duplicates spans on non-upserting backends.
- **Partial success:** a 200 whose body carries OTLP `partialSuccess` is not silently a success — rejected-span counts and messages land in the receipt.
- **Zero-event runs** are skipped and counted (`runsSkipped`), never sent.

Every export returns an `OTelExportReceipt`: `runsExported`, `runsSkipped`, `spanCount`, `spanEventCount`, `encodedBytes`, `traceIDsByRun` (jump straight from a DPK run to its trace in the backend UI), `rejectedSpans`, and `partialSuccessMessages`.

Failures throw `OTelExportError`. The transport cases — `.transport(description:completed:)` and `.httpFailure(statusCode:body:completed:)` — carry the aggregate receipt of chunks **already delivered** before the failure, so a caller can resume without re-sending what landed. `.encodingFailed`, `.fileWriteFailed`, and `.invalidEndpoint` cover the rest.

## Troubleshooting

**HTTP 415.** The backend rejects OTLP/JSON (Phoenix does this for anything but protobuf). Route through the collector relay above.

**HTTP 401/403 from Langfuse.** Check the key pair and the region host — keys are region-scoped, and the default host is the EU cloud. The header must be Basic auth over `publicKey:secretKey` (the `.langfuse` factory builds this for you).

**Traces arrive but Langfuse shows no generations.** The `gen_ai.*` attributes aren't reaching *span* attributes: either no event resolves `GenAIAttributes` (no conformance, no closure), or promotion was switched to `.attachedToEventOnly`. Keep the default `.dedicatedChildSpan`.

**A 200 response but spans are missing in the backend.** Check `receipt.rejectedSpans` and `receipt.partialSuccessMessages` — the collector admitted rejecting some spans.

**Export threw mid-way; what already landed?** Inspect the `completed` receipt inside `.transport` / `.httpFailure` and resume with the runs that weren't covered.

**Two exports of "the same" data differ byte-wise.** The byte-stability contract is: identical runs, identical order, identical options (including the `dropStats` snapshot, which moves as the store ingests), same OS/Foundation version. `DProvenanceOTelExport.export` handles the ordering; a moved `dropStats` or an OS update explains the rest.

**Payload JSON is cut off.** That's `.truncated(maxBytes: 32_768)` doing its job — `dpk.payload_truncated = true` marks it. Raise the limit or use `.full` if your backend tolerates large attributes.
