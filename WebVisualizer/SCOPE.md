# WebVisualizer scope cap

The WebVisualizer explorer (`dprovenance.dev/explorer`) is a **single-artifact viewer**,
and it stays one — on purpose. This document is the boundary. The viewer's job is to *show*
a finished result, not to *become* the tool that produces or explores it: the library/CLI
computes diffs, and the native app is the interactive workbench over a live corpus. Growing
the viewer into a live, multi-run tool would duplicate those in the browser. Because the
Apache-2.0 grant here is **perpetual and irrevocable** — a superset shipped once cannot be
narrowed later — this scope is set deliberately up front, and PRs that cross it are out of
scope regardless of how well built they are.

## What the explorer is

A read-only, zero-backend renderer for **exactly one pre-computed
[`WebDiffExport`](SCHEMA.md)** document: one already-diffed reasoning tree plus its
summary / metrics / timeline context. The diff — run selection and alignment — is computed
*upstream*, in the free CLI/library, and handed to the viewer as a finished artifact:

```bash
swift run DProvenanceKitCLI web-export --out=run.json   # library does the work
# → load run.json in the explorer
```

Its job is to let someone **share or preview a single before/after diff** in a browser with
nothing to install — the cheapest possible top-of-funnel and a live reference renderer for
anyone embedding the schema.

## Hard boundary — the explorer MUST NOT

These are out of scope. A PR that adds any of them will be closed:

- **Never a live data source.** It consumes one static `WebDiffExport` JSON. It must not open,
  read, or query a `.sqlite` trace database — in the browser (e.g. SQLite-WASM), over the
  network, or otherwise.
- **Never multi-run.** It renders exactly one comparison. No loading a corpus, a folder, or a
  bundle of multiple exports; no browsing a collection of runs.
- **Never arbitrary run selection.** It does not let the user *pick which two runs to diff*.
  That choice, and the alignment it drives, belong upstream in the CLI/library.
- **Never cross-run detection.** No anomaly/warning smart-folders, no scanning across many runs
  for regressions. The single artifact it renders already carries its own summary.
- **Never replay or interactive drill-down beyond one artifact.** Rendering the supplied tree,
  metrics, and timeline is fine; standing up an interactive investigation loop over live data
  is not.

If you want any of the above, it belongs in the **library/CLI** (run selection, alignment,
export) or in the **native app** (the live-corpus workbench) — not here.

## Why this line exists

The [D.P.K Mac app](https://apps.apple.com/us/app/d-p-k-reasoning-traces/id6784076039?mt=12)
is an interactive workbench over a **live** local trace database — it can diff runs you
choose, replay timelines, drill into payloads and span lineage, and surface anomalies across
loaded runs. The Explorer deliberately does none of those jobs. Keeping it a
single-artifact viewer makes it a small, dependable sharing surface instead of a second
live-corpus application.

> **The library computes the diff. The Explorer shows one. The native app is the workbench
> over a live local corpus.**
