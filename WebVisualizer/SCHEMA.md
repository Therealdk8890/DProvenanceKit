# WebVisualizer diff-export schema

The explorer renders **one already-diffed reasoning tree** plus summary/metric/timeline
context. It consumes a single JSON document (today: `mockDiffs.json`). This file is the
contract the Swift side must emit so real runs load without touching the front-end.

> **Status:** shipped. `WebDiffExport` (in `DProvenanceKit`) produces this exact shape from a
> `TraceAlignmentResult` — the alignment is a superset of the structural diff, so its per-event
> `state` supplies `added`/`removed` (structural) *and* `changed`/`unchanged` (semantic). Generate
> a real document with `swift run DProvenanceKitCLI web-export > run.json` and load it here, or
> call `WebDiffExport.make(...).jsonData()` directly. This doc remains the field-level contract.
> CI validates both the CLI export and the Foundation Models regression-demo export against this
> viewer contract.

## Document shape

```jsonc
{
  "summary": {
    "runs": "2,847",                    // string; display-formatted corpus size
    "regressionRisk": "Medium",         // "None" | "Low" | "Medium" | "High"  (RegressionRisk.Level, capitalized)
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

## Swift surface (`Sources/DProvenanceKit/WebDiffExport.swift`)

```swift
public struct WebDiffExport: Codable, Sendable, Equatable {
    // summary, metrics, timeline, tree — mirrors this document exactly.

    /// Build from an existing alignment result.
    static func make<T: TraceableEvent>(
        base: TraceRun<T>, comparison: TraceRun<T>, alignment: TraceAlignmentResult<T>,
        baseLabel: String = "Run A", comparisonLabel: String = "Run B",
        corpusRuns: Int? = nil, timeZone: TimeZone = .init(identifier: "UTC")!, rootLabel: String? = nil
    ) -> WebDiffExport

    /// Convenience: run the alignment engine, then build.
    static func make<T: TraceableEvent>(
        base: TraceRun<T>, comparison: TraceRun<T>, configuration: AlignmentConfiguration<T>, /* … */
    ) -> WebDiffExport

    /// Deterministic JSON (sorted keys) — feed straight to the uploader.
    func jsonData(prettyPrinted: Bool = true) throws -> Data
}
```

Node ids are positional, dates format in a fixed time zone, and `jsonData()` sorts keys, so the
same comparison always encodes to identical bytes.

### Generate a document

```sh
# any corpus case (default: first); --case=<name> to pick, --out=<path> to write a file
swift run DProvenanceKitCLI web-export > run.json
```

Or in code: `let data = try WebDiffExport.make(base: a, comparison: b, configuration: cfg).jsonData()`.
