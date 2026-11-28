# Xcode-native regression integration: compatibility contract and implementation plan

Status: design foundation; no existing runtime behavior changes.

## Goal

Expose DProvenanceKit's existing deterministic regression verdicts in Xcode build/test workflows without introducing Xcode-only dependencies into the core SDK or changing Swift/Python trace semantics.

## Existing surfaces to reuse

- `DProvenanceKit`: trace capture, comparison, attestation and verification.
- `DProvenanceFoundationModels`: opt-in Apple Foundation Models instrumentation.
- `DProvenanceUI`: trace inspection.
- `DProvenanceKitCLI` / `dpk`: existing regression gate and export.
- Existing `FoundationModelsRegressionDemo` and conformance harness.

## Compatibility invariants (merge blockers)

1. Existing public APIs, product names, CLI exit codes and defaults remain unchanged.
2. Existing deterministic alignment cost, threshold and tie-break behavior remain unchanged.
3. Existing trace and attestation formats, signature verification and offline operation remain unchanged.
4. Existing Python/Swift conformance fixtures remain identical; no parallel normalization implementation.
5. The integration is opt-in; core, CLI and Python users do not require Xcode or macOS.
6. Do not claim that recorded evidence proves uninstrumented behavior, truth of model outputs or trusted signer identity.

## Phase 1: Xcode-facing diagnostics (additive)

- Start with a small standalone formatter consuming the **existing** gate verdict and structured diff/export, not a new comparison engine.
- Output Xcode-compatible issue lines in the form `path:line: error: message` only when a validated source location is present; otherwise output a plain, deterministic diagnostic without fabricated file/line information.
- Escape untrusted labels and paths, prevent newline/control-character injection, cap diagnostic lengths, and avoid printing trace payloads or sensitive prompts by default.
- Keep the underlying gate's exit code authoritative: formatter failure must not turn a regression into success.
- Document an opt-in Xcode Run Script / SwiftPM invocation, with a reproducible Foundation Models demo.

## Phase 2: UI (additive)

- Present baseline and candidate trace trees with deterministic added/removed/changed/unchanged markers.
- Link to source only when captured source metadata is validated; never infer line numbers.
- Preserve current viewer and export formats.

## Phase 3: sparse hierarchical alignment (experimental only)

- Keep existing dense alignment as default and reference oracle.
- Benchmark worst-case repeated events, retries, concurrency-order changes, empty traces, adversarial candidate pruning, and 10k+ events.
- An experimental backend must report pruning/incompleteness explicitly and never silently claim equivalence when a valid path may have been pruned.
- No default switch until exact conformance parity and measured performance wins are demonstrated.

## Required gates before implementation PR can merge

- `swift build`, `swift test`, existing conformance harness, CLI regression gate, Xcode macOS/iOS builds and relevant Swift floor / SDK jobs.
- Add formatter unit tests for stable ordering, escaping, missing source locations, severity, exit status, and privacy redaction.
- Run lint/type gates where configured; add explicit gates only after verifying available tooling.
- DCO sign-offs must use **Daniel Paul Kissel <Therealdk8890@gmail.com>** for authored commits.

## First code task

Inspect the CLI's current structured regression output and export schema; implement the smallest optional formatter/command that maps verified regression findings to Xcode diagnostics, with fixture-based tests. Avoid modifying alignment or cryptography in this first increment.
