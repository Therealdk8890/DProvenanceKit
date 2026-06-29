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
repo, which is the canonical source. Keeping a copy (rather than a submodule or a cross-repo
CI step) makes this harness self-contained — it builds and runs with only this repo checked
out. When the spec is regenerated there (`python conformance/generate_vectors.py`), re-sync
with one command (shows what changed):

```bash
./sync-vectors.sh                         # defaults to ~/DProvenanceKitPython/conformance/vectors
./sync-vectors.sh /path/to/python/conformance/vectors
```

The alignment vectors carry an explicit `id` on every event; the harness builds its runs
with those ids because the canonical alignment ordering tiebreaks on `(sequence, id)`
(Trace Spec v1 §10.2).
