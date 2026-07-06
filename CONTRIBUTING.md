# Contributing to DProvenanceKit

Thanks for your interest. This guide covers the mechanics; the *why* behind the
architecture is in [DESIGN.md](DESIGN.md), and the invariants queries and diffs rely
on are in [SEMANTICS.md](SEMANTICS.md).

## Build and test

Requirements: a recent Xcode (26+) — `DProvenanceFoundationModels` imports Apple's
FoundationModels framework, which needs the macOS 26 SDK.

```bash
swift build          # builds all targets, including the OTel/FoundationModels bridges
swift test           # ~260 tests across the core, UI, FoundationModels, and OTel targets
swift run Quickstart # end-to-end tour of the Run → Record → Query → Diff loop
```

The benchmark corpus is the regression gate. Run it the way CI does:

```bash
swift run DProvenanceKitCLI evaluate --gate            # non-zero exit on any failed case
swift run DProvenanceKitCLI evaluate --gate --min-f1=0.95   # also require an F1 floor
```

## Ground rules

- **Preserve the invariants.** Diffing and querying are defined over stable
  `typeIdentifier`s and the authoritative per-run `sequence` clock. Read SEMANTICS.md
  before changing the event model, the alignment engine, or the query compiler.
- **No silent data loss.** A diff/regression tool's worst failure is a false negative.
  Prefer surfacing errors (or a documented, tested soft no-op) over swallowing them.
- **Add a test with behavior changes.** New store behavior should hold across the
  in-memory and SQLite backends (see `QueryParityTests`). Concurrency changes should be
  exercised by the stress/chaos suites, which also run under ThreadSanitizer in CI.
- **Keep the layering honest.** `DProvenanceKit` has no third-party dependencies and the
  OTel bridge is zero-dependency. Cross-module glue (e.g. FoundationModels ↔ OTel) lives
  in its own bridge target so neither base module takes on the other's dependency.

## Pull requests

- Branch from `main`; keep changes focused.
- Make sure `swift build`, `swift test`, the gated corpus, and the iOS build all pass —
  CI runs each of these.
- Note user-facing changes in [CHANGELOG.md](CHANGELOG.md) under `Unreleased`.
- Security issues: please follow [SECURITY.md](SECURITY.md) instead of opening a public PR.
