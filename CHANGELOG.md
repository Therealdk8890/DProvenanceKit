# Changelog

All notable changes to DProvenanceKit are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project aims to
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.6.1] - 2026-07-15

### Fixed
- **Swift Package Index Xcode compatibility builds now compile the full package on iOS.**
  The Quickstart and Foundation Models regression demo keep their `@main` entry points in
  conventionally named source files instead of `main.swift`, avoiding Xcode's conflicting
  top-level-code interpretation when it builds the generated `DProvenanceKit-Package` scheme.

### Changed
- CI now builds the same generated full-package Xcode scheme that Swift Package Index selects
  for both macOS and iOS, rather than checking only selected iOS library schemes.

## [0.6.0] - 2026-07-13

### Added
- **Proof packs** — a single self-contained JSON document (`ProofPackDocument`) carrying a
  signed trace attestation plus the artifact bytes the trace vouches for (`ProofPackArtifact`,
  utf8 or base64). `verify(trustedKeyIDs:)` checks the attestation exactly as before, then
  fail-closed re-derives each embedded artifact's SHA-256 and requires it to appear as a string
  leaf inside a signed event payload, reporting which event bound each artifact. Wrapping adds
  nothing to the canonical or signed bytes, so existing attestations can be packed without
  re-signing. Verified offline with `dpk verify --in=pack.json --proof-pack [--trusted-key=…]`.
  Format, producer rules, and threat model in `docs/PROOF_PACK.md`; a committed
  `docs/test-vectors/proof-pack-v1.json` vector is checked by the test suite.
- CI now fails loudly if the vendored conformance vectors drift from the canonical
  copies in the Python port (`vector-sync` workflow).

### Fixed
- **Opening a SQLite store no longer races a closing one.** `busy_timeout` is now
  installed immediately after the handle opens — before `journal_mode=WAL`, the first
  pragma that touches the database file. Previously a connection opened while another
  connection to the same store was mid-close (the last close briefly holds the file
  exclusively to checkpoint the WAL) could throw an instant "database is locked" from
  init instead of taking the bounded 5-second wait.
- **Legacy stores with differently-cased columns open cleanly.** The schema backfill
  now checks column presence via `PRAGMA table_info` with case-insensitive comparison
  before issuing `ALTER TABLE ADD COLUMN`, instead of firing the ALTERs unconditionally
  and swallowing failures. A legacy database that declared `span_id`/`parent_span_id`/
  `schema_version` in a different case no longer fails init with "duplicate column
  name", spurious duplicate-column error logs on every launch are gone, and genuine
  migration failures now propagate instead of being silently discarded.

### Changed
- README surfaces the [Python port](https://github.com/Therealdk8890/DProvenanceKitPython)
  at the top: same recording API, query DSL, diff/alignment engines, and CI gate, with
  adapters for LangChain, the OpenAI Agents SDK, LlamaIndex, and CrewAI.

## [0.5.0] - 2026-07-11

> **Breaking release.** Several fixes below are deliberately fail-closed and therefore
> breaking — the cloud `/ingest` wire format, stricter attestation edge validation
> (previously-signed documents containing self/duplicate/dangling edges now fail
> verification, and `TraceAttestationError`/`TraceAttestationVerificationFailure`
> gained cases that break exhaustive switches), and CLI arguments that used to be
> silently ignored now exit 2. Hence 0.5.0 rather than a 0.4.x patch — and note that
> SwiftPM's `from: "0.4.0"` still auto-flows this release to consumers, so the bump
> is a signal, not a shield.

### Fixed
- **CLI trust controls now fail closed.** Unknown, malformed, empty, duplicated, or
  out-of-range arguments exit 2 instead of being silently ignored: `--trusted-key=` with an
  empty or non-64-hex value no longer downgrades `dpk verify` to unpinned verification, and
  `--min-f1=bogus`/`nan`/`-0.1` no longer lets `evaluate --gate` pass without an F1 floor
  (`--min-f1` also requires `--gate`, and `web-export --case=<unknown>` no longer silently
  exports a different case).
- **SQLite round-trips preserve `TraceEvent.schemaVersion`.** A new `schema_version` column
  (auto-migrated on open; read-only legacy files fall back to implicit version 1) means a
  version-2 event can no longer be reloaded as version 1 and signed into an attestation with
  false schema metadata.
- **`RawTraceStore` restores persisted event ids** instead of minting a fresh `UUID` per read,
  so inspector reloads keep stable identity, rows join against lineage edges and exported
  `dpk.event_id`s, and two reads of the same store compare equal. `RawTraceEvent` also exposes
  `schemaVersion`.
- **Cloud ingestion no longer lies.** `CloudTraceStore.record` sends the recorded `event.id`
  (quarantined events round-trip with their original identity) and carries `schema_version`;
  payloads that fail to encode are counted in `dropStats`; lineage edges are drained and
  transmitted with each batch — previously queued forever — and stay attached through retry
  and quarantine (`CloudWriter.getQuarantinedEdges()`); `flush()` waits for pending edges.
- **Lost lineage edges break `preservedIntegrity`.** A failed SQLite batch insert now counts
  its edges as structural losses, including edge-only batches that previously left
  `dropStats` untouched.
- **`SQLiteConnection.transaction` is serialized.** Concurrent transactions on the shared
  connection could interleave BEGIN…COMMIT, letting one thread's failed BEGIN roll back
  another's staged writes while its remaining statements auto-committed piecemeal.
- **Attestations validate edge structure.** Signing and verification reject self-referential
  edges, duplicate edges, and edges with no connection to the attested run (cross-run lineage
  chains that anchor to the run's events remain valid).

### Changed
- **Cloud `/ingest` wire format** is now an `{"events": […], "edges": […]}` envelope instead
  of a bare event array, so lineage edges ship with the events they were drained with (see
  `docs/CLOUD.md` for the full contract).
- Foundation Models quickstarts (README, `docs/foundation-models.md`, dprovenance.dev) now
  include the required `import FoundationModels`; the site and `COMMERCIAL.md` install
  snippets reference `0.4.0`, and the site leads with the attestation positioning.

### Added
- **`SQLiteTraceStore.close()`** — flushes everything pending, stops the background writer,
  checkpoints the WAL, and leaves the store file in rollback-journal mode so it can be archived,
  rotated, or copied as a single complete file. Returns whether that single-file guarantee holds
  (`false` when a concurrent reader pinned the WAL — archive the `-wal`/`-shm` companions too).
  Idempotent, and safe against racing writes: events recorded after `close()` are counted in
  `dropStats` rather than dropped silently, edges linked after `close()` are counted as
  structural losses, and post-close reads go through a read-only connection that cannot modify
  the archived file. The non-destructive attest-then-rotate retention pattern it enables is
  documented in `docs/ATTESTATION.md`.
- **`SQLiteOpenMode`** — `SQLiteConnection` can now open `.readOnly` (fails on a missing file,
  rejects every write) and `.readOnlyImmutable` (reads bare single-file WAL stores that a plain
  read-only connection cannot open).
- A complete, copy-pasteable Keychain persistence recipe for attestation signing keys in
  `docs/ATTESTATION.md`, and a "Tracing multi-session pipelines" guide (labeled span-path
  subtrees, RAG-is-a-tool-call framing) in `docs/foundation-models.md`.

### Changed
- **`RawTraceStore` now opens store files strictly read-only.** Previously it opened with
  `CREATE | READWRITE` and WAL pragmas, so a mistyped path silently created an empty database
  and an inspector could mutate a store file it didn't own. A missing file now throws, and bare
  single-file stores (no `-wal` companion) are read through SQLite's immutable mode.
- Runtime diagnostics (writer flush/insert failures, cloud batch quarantine, live anomaly
  matches, snapshot drift) now go through `os.Logger` under the `com.dprovenancekit` subsystem
  instead of `print`, with payload-bearing text privacy-redacted in release logs.
- Repositioned the README around on-device provenance and cryptographic attestation, added a
  release badge and signed-artifact quickstart, made export explicitly opt-in, replaced the
  generic experimental label with an honest public-beta status, and clarified that the public
  repository is Apache 2.0 with no production-use restriction.
- Restored two useful fixes from the obsolete alignment branch: run-metadata dirty flags now
  clear only after the enclosing SQLite transaction commits, and the SwiftPM sample promotes
  itself to a foreground macOS app when launched from the command line.

## [0.4.0] - 2026-07-10

### Added
- **Offline trace attestation** — canonical, domain-separated trace documents signed with
  CryptoKit P-256/SHA-256. Attestations cover event order, payloads, identifiers, timestamps,
  span relationships, and supplied lineage edges; software and optional Secure Enclave keys
  share one API.
- **`dpk verify`** — an offline verifier for portable attestation JSON, with explicit
  embedded-key integrity mode and trusted-key pinning for signer identity. `dpk attest-demo`
  produces a disposable signed corpus trace for evaluation.
- **Attestation assurance surface** — adversarial modification/deletion/reordering tests, a
  committed public verification vector, canonicalization documentation, key-lifecycle guidance,
  and an explicit threat model covering capture completeness, trusted time, endpoint compromise,
  privacy, and compliance boundaries.

### Changed
- Fidelity scoring now uses typed expected/actual evidence pairs, keeping each evidence item
  tied to its semantic category so diagnostics do not cross-match unrelated finding types.
- Removed the nonexistent `0.3.1` install reference, restored `0.3.0` as the release floor, and called out
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

[Unreleased]: https://github.com/Therealdk8890/DProvenanceKit/compare/0.6.1...HEAD
[0.6.1]: https://github.com/Therealdk8890/DProvenanceKit/compare/0.6.0...0.6.1
[0.6.0]: https://github.com/Therealdk8890/DProvenanceKit/compare/0.5.0...0.6.0
[0.5.0]: https://github.com/Therealdk8890/DProvenanceKit/compare/0.4.0...0.5.0
[0.4.0]: https://github.com/Therealdk8890/DProvenanceKit/compare/0.3.0...0.4.0
[0.3.0]: https://github.com/Therealdk8890/DProvenanceKit/compare/0.2.0...0.3.0
[0.2.0]: https://github.com/Therealdk8890/DProvenanceKit/compare/0.1.0...0.2.0
[0.1.0]: https://github.com/Therealdk8890/DProvenanceKit/releases/tag/0.1.0
