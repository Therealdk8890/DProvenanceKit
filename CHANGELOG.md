# Changelog

All notable changes to DProvenanceKit are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project aims to
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.1] - 2026-07-09

### Changed
- Updated the README install snippet to point at the published patch release and called out
  the Apple platform floor (`.macOS(.v13)` / `.iOS(.v16)`) for clean SwiftPM adoption.
- Made the bundled WebVisualizer easier to try from a release: visible sample state,
  one-click sample reset, current JSON download, corrected export command copy, and browser
  smoke coverage for the reset path.
- Silenced local Swift compile warnings in the Foundation Models regression demo and OTel
  integration tests without changing runtime behavior.

## [0.3.0] - 2026-07-09

### Added
- **`WebDiffExport`** — a `Codable` projection of a run comparison into the exact JSON the
  bundled WebVisualizer consumes (summary, metrics, timeline, and a color-coded reasoning tree).
  Built from a `TraceAlignmentResult` — its per-event `state` supplies added/removed *and*
  changed/unchanged — with deterministic output (positional node ids, fixed-time-zone dates,
  sorted keys with `.withoutEscapingSlashes`, and a dependency-free FNV-1a fingerprint).
  `swift run DProvenanceKitCLI web-export [--case=<name>] [--out=<path>]` emits a document for
  any corpus case; contract in `WebVisualizer/SCHEMA.md`.
- **Foundation Models regression demo** — a runnable executable
  (`swift run FoundationModelsRegressionDemo [--gate]`) that ingests two weather-agent
  transcripts (before/after a model update where the agent silently stops calling its tool),
  catches the dropped critical step as a `HIGH`-risk regression via structural diff + semantic
  alignment, fails a CI gate (non-zero exit), and writes a `WebDiffExport` artifact. Runs
  anywhere — no live Apple Intelligence. Walkthrough in `docs/foundation-models-regression-demo.md`.

### Changed
- **CI trust surface** — CI now validates Foundation Models and CLI WebVisualizer exports,
  smoke-tests the browser uploader with Playwright, and makes the ThreadSanitizer concurrency
  suite blocking after a green run.
- **GitHub Actions runtime hygiene** — updated `actions/setup-node` and `gitleaks-action`
  to Node 24-backed major versions to avoid Node 20 deprecation annotations.
- **Public claims discipline** — refreshed platform, benchmark, CloudTraceStore accounting,
  and WebVisualizer command docs so public statements line up with executable checks.

## [0.2.0] - 2026-07-06

### Added
- **Content-aware redaction** — `FMRedactor` masks sensitive substrings *inside* a field
  (SSN, email, …) via regex rules, set on `FMRedactionPolicy.redactor`. Masking runs
  before the field's mode and is deterministic, so live/post-hoc capture stay byte-equal
  and same-rule runs still diff equal; a masked field is a distinct identity from an
  unmasked capture (different content). Includes a `.commonPII` preset; invalid patterns
  are skipped, never fatal. Default `nil` = exact prior behavior.
- **Payload-value queries** — `TraceQueryDSL.matching(step:where:)` filters runs by event
  payload *content* (`score < 0.5`, `approved == false`), not just which steps ran —
  closing the biggest query gap vs. Langfuse/LangSmith. The predicate is a Swift closure
  evaluated in-process, so the in-memory and SQLite stores agree by construction (SQLite
  hydrates a candidate superset, then applies the same evaluator); it's unsupported by the
  cloud query (encoding throws rather than silently dropping the filter). Also adds
  `TraceQueryDSL.excluding(_:)` to negate a sub-query.
- **`record(_:derivedFrom:)`** — records an event and wires its lineage edge(s) in one
  call (single parent or an array; custom `TraceEdgeType`, default `.derivedFrom`), on
  both `DProvenanceKit` (ambient run) and `ActiveTraceRun`. The shipped
  `lineage`/`impact`/`explain` graph is now reachable without manual UUID bookkeeping.
- **OTel lineage export** — lineage edges now surface in the OTLP export as
  `dpk.derived_from` (comma-joined direct-parent event ids) + `dpk.derived_from.type` on
  the derived event's span/span-event, with `dpk.event_id` on every event as the join
  key. Attributes carry 100% of edges regardless of gen_ai promotion, chunking, or
  cross-run references. The store `export` convenience fetches edges and is fault-tolerant
  (a store that can't traverse — e.g. the cloud stub — degrades to no lineage rather than
  failing the export). Determinism (M7) is preserved: `dpk.derived_from` is sorted by
  source id. (OTLP span *links* for the promoted↔promoted subset are a planned follow-up.)
- **Bounded queries** — `TraceStore.queryRuns(_:limit:)` returns at most `limit` runs.
  The SQLite store pushes the bound down so it caps per-run hydration instead of
  materializing the whole result set on a large corpus.

### Changed
- **SQLite reads are isolated from writes** — the SQLite store now reads through a
  dedicated connection. Previously a query could observe the writer's uncommitted rows
  mid-transaction on the shared connection; with a separate connection, WAL gives reads
  a committed snapshot. Reads still flush the writer first, so recent records are visible.

### Fixed
- **SQLite preserves `TraceEvent.id` on read** — `getRun`/`queryRuns` were minting a fresh
  UUID for each hydrated event instead of restoring the recorded id, so id-based joins
  (and the new lineage export) wouldn't line up for SQLite-backed runs.

### Added (OTel)
- **OTel error status** — a generation or tool span whose semantics carry an
  `errorType` now exports with OTLP status `ERROR` and an `error.type` attribute, so
  error-rate dashboards can see failures. `GenAIAttributes` gains an `errorType` field,
  and the FoundationModels bridge maps `generationError` (chat failures and
  `execute_tool` failures) accordingly.
- **OTLP/HTTP gzip** — `OTLPHTTPExporter.Configuration.compression = .gzip` compresses
  the request body and sets `Content-Encoding: gzip`. Zero-dependency (wraps the OS
  Compression framework); falls back to uncompressed if compression fails. Default
  `.none` keeps the prior wire behavior.
- **`DProvenanceFoundationModelsOTel`** — a bridge target that makes FoundationModels
  traces classify as `gen_ai.*` out of the box when exported through the OTel bridge
  (operation name, provider, request model/temperature/max-tokens, and `execute_tool`
  for tool calls). Just link it; the mapping applies with no call-site change. On-device
  FoundationModels exposes no token counts, so this is classification, not cost accounting.
- **`DProvenanceKit.runReturningID(contextID:store:_:)`** — records a run and returns its
  `runID` alongside the block result, closing the Run → Record → Query → Diff loop from a
  single call. `runID` is now on the `AnyActiveTraceRun` protocol.
- **`TraceStore.getRun(id:)`** — fetch a single run by id, on the protocol and implemented
  by the in-memory and SQLite stores (the cloud stub returns nil, matching `queryRuns`).
- **`MissingSupportRule`** — a batteries-included `AnomalyRule` (a run that reached one step
  without a supporting step), so the documented anomaly-detection example compiles verbatim.
- **`Quickstart` executable** — `swift run Quickstart` prints an end-to-end trace, diff, and
  detected regression; it also compile-checks the documented public API.
- **CLI gating** — `DProvenanceKitCLI evaluate --gate [--min-f1=<value>]` exits non-zero on
  a corpus regression so it can fail a CI job; added `--help` and non-zero exit on bad args.
- **CI** — iOS device-SDK build (validates `DProvenanceUI` UIKit-only paths and the new
  bridge), a ThreadSanitizer leg over the concurrency suites, and a gated benchmark run.
- **SQLite** — index on `runs(start_time)` for recency listings; `PRAGMA busy_timeout=5000`
  so a second reader (e.g. the inspector UI) waits on WAL-checkpoint contention instead of
  failing with `SQLITE_BUSY`.

### Changed
- `record(_:)` called outside a `run { }` scope now logs a warning in DEBUG builds (it
  remains a soft no-op in release, unchanged). This was the most common onboarding trap.

### Fixed
- The flagship README anomaly-detection snippet referenced a type that shipped nowhere; it
  now uses the real `MissingSupportRule`.

## [0.1.0]

- Initial tagged release: core Run → Record → Query → Diff loop, `TraceAlignmentEngine`,
  benchmark corpus, in-memory and SQLite stores.

[Unreleased]: https://github.com/Therealdk8890/DProvenanceKit/compare/0.3.1...HEAD
[0.3.1]: https://github.com/Therealdk8890/DProvenanceKit/compare/0.3.0...0.3.1
[0.3.0]: https://github.com/Therealdk8890/DProvenanceKit/compare/0.2.0...0.3.0
[0.2.0]: https://github.com/Therealdk8890/DProvenanceKit/compare/0.1.0...0.2.0
[0.1.0]: https://github.com/Therealdk8890/DProvenanceKit/releases/tag/0.1.0
