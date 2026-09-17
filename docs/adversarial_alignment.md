# Adversarial Alignment Suite

## Purpose

Measure how often the **production** trace matcher (greedy, highest-score-first
bipartite assignment in `DefaultTraceMatcher`) disagrees with a **mathematically
optimal** maximum-weight assignment under the **same** scoring function,
thresholds, and type/priority filtering — and whether disagreement can flip the
regression verdict (especially `HIGH` for critical remove / reorder / changed).

Production engines are **not** rewritten. Optimal assignment lives only in tests.

## Production matcher (both languages)

| Surface | Path | Algorithm |
|---------|------|-----------|
| Python | `dprovenancekit/alignment_matcher.py` | Score all pairs ≥ ambiguity threshold; sort by score desc, base idx, comp idx; greedy claim |
| Swift | `Sources/DProvenanceKit/TraceMatching/DefaultTraceMatcher.swift` | Same greedy policy (with concurrent scan optimizations that preserve exactness) |

Scoring comes from `AlignmentConfiguration.score_match` / Swift `combinedScore`
(type, payload/evaluator, structural, temporal weights from the active profile).

Default bind floor: evaluator `ambiguity_threshold` (typically `0.4`).
Equivalence / “changed beyond” uses `profile.semantic_threshold`
(`0.99` strict_audit, `0.75` developer_debug).

## Optimal reference

- **Python:** pure-Python Hungarian / Munkres in
  `tests/adversarial_alignment/optimal_assignment.py` (no scipy).
- **Swift (implemented):** pure-Swift Hungarian / Munkres in
  `Tests/DProvenanceKitTests/AdversarialAlignment/OptimalAssignment.swift`.

Verdict under optimal pairing reuses `DefaultAlignmentInterpreter` plus a
test-local copy of the engine’s regression-risk derivation (removed / reordered /
changed criticals) — still without patching production sources.

## Pathological generators

Catalog is isomorphic across languages (Python `generators.py` /
Swift `AdversarialAlignment/Generators.swift`), covering:

| Category | Coverage |
|----------|----------|
| `duplicates` | duplicate types, nested/interleaved same-type blocks |
| `near_identical` | trailing whitespace/tab, double space, prefix drift |
| `insert_delete` | decoys, deletes, bulk noise, every-other delete |
| `reorder` | triple swap, full reverse, adjacent swaps |
| `ties` | equal-score grids, ties with exact anchors |
| `collisions` | one-to-many, rotate/chain, graded greedy traps |
| `threshold` | below/at/above semantic threshold + extras |
| `priority_mix` | critical↔structural interactions |
| `long` | ~30 + **50 / 100 / 150 / 200** repeated patterns |
| `semantic_hook` | `SemanticLabel_v1` disagree with payload equality |
| `fuzz` | seeded deterministic families (n∈[50,200]) |

## Metrics

### Python v2 (local, DProvenanceKitPython)

| Metric | Value |
|--------|-------|
| n_cases | 58 |
| disagreement_rate | 0.207 |
| verdict_flip_rate | 0.000 |
| high_none_flip_rate | 0.000 |

### Swift XCTest

Emitted in test logs as `ADVERSARIAL_ALIGNMENT_METRICS` and JSON summary from
`AdvSuiteReport.summaryJSON()` when
`AdversarialAlignmentTests.testSuiteMetricsWithinBudget` runs on macOS CI.

| Metric | Notes |
|--------|-------|
| disagreement_rate | pairing set differs |
| verdict_flip_rate | any risk level flip |
| high_none_flip_rate | `HIGH` ↔ `none` |

### Pass / fail policy

- Pairing disagreements alone: **PASS** (metrics under budget).
- Optimal score must be ≥ production score.
- Unexpected `HIGH`↔`none` flips on **ExactEquality_v1** cases: **FAIL**.
- Graded / semantic-hook cases use separate evaluators.
- Suite size must be ≥ 40 cases.

## Swift suite layout

| Path | Role |
|------|------|
| `Tests/DProvenanceKitTests/AdversarialAlignment/OptimalAssignment.swift` | Hungarian + greedy/optimal binding helpers |
| `Tests/DProvenanceKitTests/AdversarialAlignment/Generators.swift` | Pathological corpus |
| `Tests/DProvenanceKitTests/AdversarialAlignment/Compare.swift` | Metrics + risk-from-bindings harness |
| `Tests/DProvenanceKitTests/AdversarialAlignmentTests.swift` | XCTest entrypoints |

Wired automatically via the existing `DProvenanceKitTests` package test target
(`Package.swift`); no production matcher rewrite and no optional strategy flag.

## Running

```bash
# Python
python -m pytest tests/test_adversarial_alignment.py -v

# Swift (macOS)
swift test --filter AdversarialAlignmentTests
```
