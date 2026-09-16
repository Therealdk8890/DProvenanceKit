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

Pure-Python Hungarian / Munkres maximizing Σ scores over eligible pairs
(`tests/adversarial_alignment/optimal_assignment.py`). No scipy dependency.

Verdict under optimal pairing reuses `DefaultAlignmentInterpreter` plus a
test-local copy of the engine’s regression-risk derivation (removed / reordered /
changed criticals) — still without patching production sources.

## Pathological generators

Covered in `tests/adversarial_alignment/generators.py`:

- duplicate event types / repeated tool calls
- near-identical payloads
- inserted decoys / deleted events / reorders
- equally scored candidates / one-to-many collisions
- threshold-boundary scores (`0.749999`, `0.75`, `0.750001`)
- critical vs structural priority mix
- semantic evaluator disagreeing with weighted payload equality (hook + `SemanticLabel_v1`)
- long traces with repeated patterns
- graded greedy trap (asymmetric scores where greedy ≠ optimal)

## Metrics

Emitted in pytest output and `adversarial_alignment_report.json`:

- **disagreement_rate** — fraction of cases where pair sets differ
- **verdict_flip_rate** — risk level differs (any levels)
- **high_none_flip_rate** — `HIGH` ↔ `none` specifically
- **categorized_failures** — by generator category

### Pass / fail policy

- Pairing disagreements alone: **PASS** (metrics asserted under budget).
- Optimal score must be ≥ production score (sanity).
- Unexpected `HIGH`↔`none` flips on **ExactEquality_v1** cases: **FAIL**.
- Graded / semantic-hook cases are separate evaluators and do not trip the
  ExactEquality hard invariant.

## Swift hooks

Full XCTest port is deferred (no Mac CI in this change). To mirror the suite:

1. Add `Tests/DProvenanceKitTests/AdversarialAlignmentTests.swift`.
2. Reuse production `AlignmentConfiguration.scoreMatch` / `combinedScore`.
3. Implement Hungarian in a test-only helper (or call a tiny shared fixture).
4. Compare `DefaultTraceMatcher.match` bindings vs optimal; re-run interpretation
   / risk using the same critical remove-reorder-changed rules as
   `TraceAlignmentEngine` (see `RegressionRiskSoundnessTests` /
   `LinearCriticalReorderTests`).
5. Keep generators isomorphic to the Python `Case` catalog for cross-language
   disagreement-rate comparison.

Until then, treat the Python suite + this document as the source of truth for
adversarial coverage.

## Running

```bash
pytest tests/test_adversarial_alignment.py -v
```
