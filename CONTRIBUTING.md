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

## Free vs. paid boundary

This repository is the **public, Apache-2.0 core** — in-process, single-machine features
only. Its license grant is *perpetual and irrevocable*: anything merged and released here is
free forever and cannot be relicensed or clawed back. The boundary is therefore enforced
*before* code lands, not after.

Apply the same test [COMMERCIAL.md](COMMERCIAL.md) uses:

> **Does it deliver its value standalone, in the user's own process, as part of the core
> library?**

- **Yes → it belongs here**, free under Apache 2.0.
- **No — its value only exists hosted, cross-machine, or managed**, *or* it's something
  we intend to sell as software you run (on-prem/custom) → it belongs in the private premium
  repository under a separate commercial license. **Never commit it here.**

Reserved namespaces — do **not** add matching paths to this repo; CI (the *Free/paid boundary
guard* job) rejects them so an accidental `git add` fails the build instead of shipping paid
code for free:

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
cross-run detection). Those verbs are the paid native app's job; run selection and alignment
belong upstream in the CLI/library. A PR that marches the explorer toward a live-corpus
workbench will be closed even if it's well built — under Apache 2.0 that step can't be undone.

## Pull requests

- Branch from `main`; keep changes focused.
- Make sure `swift build`, `swift test`, the gated corpus, and the iOS build all pass —
  CI runs each of these.
- Note user-facing changes in [CHANGELOG.md](CHANGELOG.md) under `Unreleased`.
- Security issues: please follow [SECURITY.md](SECURITY.md) instead of opening a public PR.
