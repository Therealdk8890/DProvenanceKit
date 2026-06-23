# DProvenanceKit Benchmarks

This document describes the methodology, datasets, and performance of the DProvenanceKit semantic alignment engine. Rather than relying purely on structural diffs, DProvenanceKit verifies behavioral equivalence relative to an explicitly defined semantic model.

## Evaluation Methodology

The `DProvenanceKitCLI` runs an automated evaluation suite against the **DProvenance Standard Corpus**, a collection of simulated real-world AI agent behaviors. The benchmark measures how accurately the engine identifies identical runs, semantic evolution, noise injection, regressions, and causal divergence.

### Performance Metrics
The system is scored using standard classification metrics (Precision, Recall, F1) against expected structural and semantic findings.
- **True Positives (TP)**: Correctly identified semantic divergence or expected non-equivalence.
- **False Positives (FP)**: Flagged regression or structural changes that did not occur.
- **False Negatives (FN)**: Missed an expected finding (e.g., failed to detect a skipped critical step).
- **Fidelity**: Assesses whether the trace equivalence decision is backed by an auditable causal rationale.

## Failure Taxonomy

DProvenanceKit is a diagnostic validation suite, not a statistical generalization benchmark. We explicitly define and test against known failure modes to provide an auditable understanding of the system's limits.

### Tier 1 — Structural Failures
- **Trace Truncation**: Abrupt drops in a trace before critical outcomes are reached.
- **Missing Events**: Structural or critical events that were present in the base run but absent in the comparison.

### Tier 2 — Causal Failures
- **Dependency Inversion Trap**: Swapping the order of dependent events (e.g., executing an action before its prerequisite).
- **Reorder Violations**: Breaking strict temporal or sequence constraints when explicitly required.

### Tier 3 — Semantic Failures
- **Semantic Substitution Ambiguity**: False friend equivalence (e.g., `FetchUserProfile` vs `RecomputeProfileFromEvents`) where outcomes appear similar but correctness paths diverge.
- **Multi-tool Collapse**: Replacing multiple granular steps with a single opaque step, stressing structural mapping.
- **Semantic Drift**: Output matches structurally, but payload semantics drift beyond the defined threshold.

## Current Benchmark Results

Below is the evaluation output from `DProvenanceKitCLI evaluate`, separated into standard and adversarial suites:

```text
=== STANDARD DATASET ===
Dataset: DProvenance Standard Corpus  (8 cases, 8 passed)
Precision: 1.000  Recall: 1.000  F1: 1.000
Avg fidelity: 1.000  Avg runtime: 0.17ms  p95: 0.56ms
  [PASS] Coding Agent Regression  TP=2 FP=0 FN=0  fidelity=1.00
  [PASS] Semantic Evolution  TP=1 FP=0 FN=0  fidelity=1.00
  [PASS] Reordered Execution  TP=2 FP=0 FN=0  fidelity=1.00
  [PASS] Branch Collapse  TP=0 FP=0 FN=0  fidelity=1.00
  [PASS] Meaning-Preserving Mutation  TP=1 FP=0 FN=0  fidelity=1.00
  [PASS] Noise Injection  TP=0 FP=0 FN=0  fidelity=1.00
  [PASS] Semantic Drift  TP=1 FP=0 FN=0  fidelity=1.00
  [PASS] Degenerate Traces  TP=0 FP=0 FN=0  fidelity=1.00

=== ADVERSARIAL DATASET ===
Dataset: DProvenance Adversarial Robustness Suite  (5 cases, 3 passed)
Precision: 0.833  Recall: 0.714  F1: 0.769
Avg fidelity: 1.000  Avg runtime: 0.08ms  p95: 0.11ms
  [FAIL] Dependency Inversion Trap  TP=2 FP=0 FN=1  fidelity=1.00
  [PASS] Causal Ambiguity Trap  TP=0 FP=0 FN=0  fidelity=1.00
  [FAIL] Partial Trace Truncation  TP=1 FP=1 FN=1  fidelity=1.00
  [PASS] Semantic Substitution Trap  TP=1 FP=0 FN=0  fidelity=1.00
  [PASS] Multi-tool Semantic Collapse  TP=1 FP=0 FN=0  fidelity=1.00

=== SUMMARY ===
Total Cases: 13
Total Passed: 11 (84.6%)
```

*(Note: The adversarial dataset runs under a stricter `AlignmentProfile` with a higher semantic threshold and tighter bounds to isolate edge-case failures. The explicit failures on Dependency Inversion and Truncation highlight the exact boundaries of the engine's current assertion capabilities. **Adversarial configuration adjustments do not alter equivalence semantics; they adjust sensitivity thresholds for stress evaluation only.**)*

## The Corpus Scenarios

### Standard Scenarios
1. **Coding Agent Regression**: Tests dropping a critical step (`ValidateAPI`) while retaining structural non-critical steps.
2. **Semantic Evolution**: Tests replacing one tool (`SearchDocumentation`) with an equivalent one (`LookupAPIDocs`).
3. **Reordered Execution**: Tests swapping independent, side-effect-free steps.
4. **Branch Collapse**: Tests dropping an un-selected branch of investigation.
5. **Meaning-Preserving Mutation**: Tests substituting a network fetch with a cached fetch.
6. **Noise Injection**: Tests introducing telemetry and planning logs.
7. **Semantic Drift**: A substitution attack where an authorization step is replaced with a precheck step.
8. **Degenerate Traces**: Tests edge cases such as evaluating empty executions.

### Adversarial Scenarios
1. **Dependency Inversion Trap**: Swaps order of two dependent critical events.
2. **Causal Ambiguity Trap**: Multiple identical events to confuse bipartite matching.
3. **Partial Trace Truncation**: Trace drops off before final critical decision.
4. **Semantic Substitution Trap**: False friend equivalence, caching vs computing from scratch.
5. **Multi-tool Semantic Collapse**: Two distinct tools replaced by one overarching tool.
