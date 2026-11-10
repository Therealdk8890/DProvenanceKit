# Trace Specification v1 — Swift conformance harness

Proves this Swift SDK reproduces the language-neutral **Trace Specification v1** golden
vectors (the Python reference oracle's frozen output). This is the Swift end of the
`Trace Specification → Swift / Python / …` conformance model.

```bash
swift run --package-path ConformanceHarness
```

Expected tail:

```
ALL VECTORS REPRODUCED ✓  — Swift conforms to Trace Specification v1
```

It is a small, self-contained SwiftPM package with a **relative** path dependency on the
parent `DProvenanceKit` package (`.package(path: "..")`), so it runs from any checkout with
no machine-specific paths. It drives the real SDK for each category:

| Category | Driven through |
| --- | --- |
| Payload encoding (§2) | `JSONEncoder(.sortedKeys)` + semantic / round-trip checks |
| Run fingerprint (§5) | the real `SQLiteTraceStore`: record → `flush()` → read `runs.fingerprint` |
| Query semantics (§6) | `TraceQueryNode.evaluate(run:)` over the corpus |
| Profile hash (§10.1) | `AlignmentExecutionContract.computeProfileHash(…)` |
| Alignment verdict (§10.2) | `TraceAlignmentEngine.align(…)` + `canonicalSort` |

## Vectors

[`vectors/`](vectors) is a **vendored copy** of `conformance/vectors/*.json` from the Python
repo, which is the canonical source. The Swift repository currently vendors all six shared
Trace Specification v1 vector files, including `attestation-v1.json`. Keeping this copy
makes the harness self-contained — it builds and runs with only this repo checked out.
The vector-sync workflow compares the vendored files against the Python canonical source
and fails when they drift.

When the spec is regenerated in Python (`python conformance/generate_vectors.py`), re-sync
with one command:

```bash
./sync-vectors.sh                         # defaults to ~/DProvenanceKitPython/conformance/vectors
./sync-vectors.sh /path/to/python/conformance/vectors
```

The alignment vectors carry an explicit `id` on every event; the harness builds its runs
with those ids because the canonical alignment ordering tiebreaks on `(sequence, id)`
(Trace Spec v1 §10.2).

## Swift-only surfaces (not in this harness)

Crypto attestation / proof-pack vectors under `docs/test-vectors/` are Swift-specific
surfaces and are not part of the shared Trace Specification v1 corpus. They do not yet
have a Python oracle. See the Python repo's `conformance/CROSS_LANGUAGE_GAPS.md` for the
tracked gap list.

This harness covers Trace Spec v1 golden vectors and fails closed on vector drift via
`.github/workflows/vector-sync.yml`.
