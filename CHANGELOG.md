# Changelog

All notable changes to DProvenanceKit are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project aims to
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
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

[Unreleased]: https://github.com/Therealdk8890/DProvenanceKit/compare/0.1.0...HEAD
[0.1.0]: https://github.com/Therealdk8890/DProvenanceKit/releases/tag/0.1.0
