# Alignment Evaluation Framework Validation
### From Benchmark Failure to Reproducible Evaluation

This document records the first complete evaluation cycle for the trace `TraceAlignmentEngine`:
making the benchmark framework trustworthy, using it to locate real engine defects, fixing
those defects at the root, reconciling the corpus, and reaching full corpus coverage — without
sacrificing determinism.

The headline is **not** "F1 = 1.0." The durable achievement is that the evaluation
infrastructure is now trustworthy enough that its numbers mean something, and the engine has
been corrected against it.

---

## 1. Initial State

Once the benchmark harness itself was made sound (correct precision/recall, multiset matching,
evidence-backed fidelity, a real headless runner, and a corpus regression test), the standard
corpus reported:

```
Cases passing: 3/8
Precision:     0.267
Recall:        0.667
F1:            0.381
```

These numbers were *useful*, not embarrassing: the benchmark was successfully exposing real
engine weaknesses rather than producing false failures. Every remaining failure was traced to a
concrete cause below.

---

## 2. Root Cause Analysis

The failures were genuine alignment-engine defects, organized by class.

### Payload Identity Defect
- **Problem:** identical events were downgraded into "semantic evolution" matches whenever a
  structural or temporal penalty pulled their weighted score below the exact-match threshold.
- **Fix:** a payload-aware evaluator (`DProvenanceCorpus.standardEvaluator`) plus exact-match
  classification keyed on payload *identity* (`bEvent.payload == cEvent.payload`) rather than on
  the weighted score.
- **Result:** identical events exact-match again and emit no finding.

### Reorder Detection Defect
- **Problem:** reorders were detected by comparing absolute indices, so an event whose index
  merely shifted because something was inserted or removed around it was falsely flagged as
  reordered.
- **Fix:** relative-order inversion analysis over the set of matched pairs.
- **Result:** insertions/deletions no longer generate spurious reorder findings; genuine swaps
  still are detected.

### Matching Defect
- **Problem:** local, base-order greedy assignment mispaired distinct same-type events (e.g. it
  bound an earlier decision to the only comparison decision and orphaned its true identical
  counterpart).
- **Fix:** a global, score-ordered greedy matcher — strongest pairings are established first.
- **Result:** an exact/strong match always wins its binding over a weaker incidental one.

### Ambiguity Over-Reporting Defect
- **Problem:** a comparison event already bound to its own identical match was still considered
  an "ambiguous alternative" for an unrelated same-type base event.
- **Fix:** exclude already-bound comparison events from ambiguity candidates.
- **Result:** ambiguity is reported only against genuinely unassigned candidates.

---

## 3. Corpus Corrections

Two corpus expectations were inconsistent with the engine's documented classification rules and
were corrected. **These changes align benchmark expectations with the taxonomy — they were not
made to increase scores:**

- **Coding Agent Regression** expected `criticalStepRemoved("tool")`, but tool executions are
  `.structural`; only `.decision` events are `.critical`. The skipped validation step was
  modeled as the critical decision it represents, so the regression is detectable under the
  taxonomy (and the structural tool removals correctly produce no findings).
- **Reordered Execution** expected only one of the two events that genuinely swap positions. The
  second genuine reorder was added to the expected set.

---

## 4. Final Results

| Metric        | Before | After |
| ------------- | ------ | ----- |
| Cases passing | 3/8    | 8/8   |
| Precision     | 0.267  | 1.0   |
| Recall        | 0.667  | 1.0   |
| F1            | 0.381  | 1.0   |
| Tests         | 62     | 63    |

Determinism was preserved throughout: a deterministic engine repeated across iterations reports
exactly zero F1 variance ("Stable"), and the perturbation layer — which injects equivalence-score
noise gated by the `DeterministicBoundary` — demonstrably produces detectable variance when
isolation is lifted. Both directions are covered by tests.

The headless CLI (`DProvenanceKitCLI evaluate|diagnose|stability`) runs the corpus and prints
these metrics directly, so the results are reproducible in CI.

---

## 5. What Is Actually Proven

- The benchmark demonstrates **complete coverage of the current corpus**.
- It does **not** imply universal alignment correctness.

The corpus is small and hand-authored; 8/8 means the engine handles every scenario the corpus
currently encodes, classified consistently with the taxonomy.

### Future work
- **Adversarial Corpus v2** — cases designed to break the current heuristics.
- **Larger trace corpora** — scale beyond a handful of events per case.
- **Multi-branch ambiguity stress tests** — many near-equal candidates.
- **Deep span-nesting scenarios** — structural context beyond a single parent level.

This completes the first formal evaluation cycle. The question shifts from *"can we trust the
benchmark results?"* (infrastructure validation, now done) to *"how well does the engine
generalize beyond the benchmark?"* (research validation).
