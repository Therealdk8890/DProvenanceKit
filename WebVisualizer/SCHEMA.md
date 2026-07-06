# WebVisualizer diff-export schema

The explorer renders **one already-diffed reasoning tree** plus summary/metric/timeline
context. It consumes a single JSON document (today: `mockDiffs.json`). This file is the
contract the Swift side must emit so real runs load without touching the front-end.

> **Status:** the mock is hand-authored. **Nothing in `Sources/` produces this shape yet.**
> The library's diff is `TraceDiffEngine.TraceDiffResult` (a flat list of `.added` / `.removed`
> `Change`s keyed by two run UUIDs); `regressionRisk` comes from `TraceAlignmentEngine`. A small
> Swift transformer must fold those into the envelope below. This doc is that transformer's spec.

## Document shape

```jsonc
{
  "summary": {
    "runs": "2,847",                    // string; display-formatted corpus size
    "regressionRisk": "Medium",         // "Low" | "Medium" | "High"  (RegressionRisk.Level, capitalized)
    "changedLogicPaths": 14,            // int; root→leaf paths touched by a change
    "structuralFingerprint": "8F2A...C91B" // short hash of the comparison run's structure
  },
  "metrics": {
    "driftScore": 23,                   // int 0–100; render as a meter (0 = identical)
    "addedNodes": 4,                    // int (advisory; the UI recomputes from `tree`)
    "removedNodes": 2,
    "changedPaths": 3,
    "risk": "Medium"                    // fallback if summary.regressionRisk is absent
  },
  "timeline": {
    "runA": { "label": "Run A", "date": "Oct 12, 14:02" },  // baseline
    "runB": { "label": "Run B", "date": "Oct 12, 15:30" }   // candidate
  },
  "tree": { /* Node — required; the only field the loader hard-requires */ }
}
```

### Node

```jsonc
{
  "id": "node-4",                       // string; stable, unique within the document
  "label": "Final Decision",            // string; the step / reasoning label
  "type": "changed",                    // "added" | "removed" | "changed" | "unchanged"
  "details": {                          // OPTIONAL; present for "changed" nodes
    "runA": "Approved",                 //   baseline value
    "runB": "Denied"                    //   candidate value  → rendered as A → B
  },
  "children": [ /* Node, … */ ]         // OPTIONAL; omit or [] for leaves
}
```

## Field notes / invariants

- **`tree` is the only required field.** `summary`, `metrics`, and `timeline` degrade
  gracefully (missing values render as `—`). The uploader rejects a document whose
  `tree` has no `type`.
- **Node `type` taxonomy.** `added` / `removed` map to `TraceDiffResult.ChangeKind`.
  `changed` and `unchanged` are **not** in the raw diff — they come from the alignment
  pass (a matched-but-divergent pair is `changed`; a matched-and-equal pair is
  `unchanged`). The transformer must run alignment, not just the structural diff, to
  populate these.
- **`details` before/after** is only meaningful for `changed`; the UI shows
  `runA → runB`. Keep values short (they render inline).
- **Counts** (`addedNodes`, etc.) are advisory — the UI recomputes per-type counts from
  the `tree` for the filter chips, so they cannot drift out of sync on screen. Keep them
  for at-a-glance metrics only.
- **`driftScore`** is a 0–100 display metric; define it however the transformer likes
  (e.g. `100 * changed+added+removed / totalNodes`), but keep it bounded.

## Suggested Swift surface

```swift
// DProvenanceKit (new, e.g. Sources/DProvenanceKit/WebDiffExport.swift)
public struct WebDiffExport: Codable, Sendable { /* summary, metrics, timeline, tree */ }

public extension TraceDiffResult {
    /// Fold a structural diff + alignment result into the WebVisualizer envelope.
    static func webExport(
        base: TraceRun<some TraceableEvent>,
        comparison: TraceRun<some TraceableEvent>,
        alignment: TraceAlignmentResult
    ) -> WebDiffExport
}
```

Emit with `JSONEncoder` (`.sortedKeys` for determinism) and drop the file next to the
built app, or wire a `--web-export` flag onto `DProvenanceKitCLI`.
