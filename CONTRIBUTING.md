# Contributing to DProvenanceKit

Thanks for your interest. This guide covers the mechanics; the *why* behind the
architecture is in [DESIGN.md](DESIGN.md), and the invariants queries and diffs rely
on are in [SEMANTICS.md](SEMANTICS.md).

## Build and test

Requirements: a recent Xcode (26+) — `DProvenanceFoundationModels` imports Apple's
FoundationModels framework, which needs the macOS 26 SDK.

```bash
swift build          # builds all targets, including the OTel/FoundationModels bridges
swift test           # ~490 tests across the core, UI, FoundationModels, and OTel targets
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

## Public/private boundary

This repository is the **public, Apache-2.0 library**. Anything merged and released here may
be used, modified, embedded, and distributed subject to that license. Do not merge
customer-confidential code or material intended to remain a genuinely separate proprietary
component.

Apply this test before opening a pull request:

> **Is this a capability we intend to release as part of the public Apache-2.0 library?**

- **Yes:** it may belong here after normal review.
- **No:** keep it outside this repository and define its scope, ownership, and license before
  implementation. A future proprietary component must be genuinely separate; it cannot sell
  rights to public code that Apache 2.0 already grants.

Reserved namespaces — do **not** add matching paths to this repo. The historically named
*Free/paid boundary guard* catches accidental inclusion of code marked private, hosted, or
premium:

- `Sources/**/Premium*` and `Sources/**/Hosted*` (directories or files)
- any `*Premium*.swift` / `*Hosted*.swift`
- a top-level `Private/`

A tracked pre-push hook enforces the same rule locally. Activate it once per clone:

```bash
git config core.hooksPath .githooks   # .githooks/pre-push blocks a leak before it's pushed
```

### The web Explorer stays a single-artifact viewer

The [WebVisualizer](WebVisualizer/) explorer is free and open source, but it has a **hard
scope cap** — see [WebVisualizer/SCOPE.md](WebVisualizer/SCOPE.md). It renders exactly one
pre-computed `WebDiffExport` and must **never** become a live or multi-run data source (no
`.sqlite` ingestion, no SQLite-WASM, no corpus loading, no arbitrary run selection, no
cross-run detection). Those verbs belong in the native app or upstream CLI/library; they are
not part of this focused static viewer. A PR that turns the Explorer into a live-corpus
workbench is out of scope even if it is well built.

## Pull requests

- Branch from `main`; keep changes focused.
- Make sure `swift build`, `swift test`, the gated corpus, and the iOS build all pass —
  CI runs each of these.
- Note user-facing changes in [CHANGELOG.md](CHANGELOG.md) under `Unreleased`.
- Security issues: please follow [SECURITY.md](SECURITY.md) instead of opening a public PR.
