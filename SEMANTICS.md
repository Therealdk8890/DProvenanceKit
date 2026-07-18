# Behavioral Equivalence Specification

This document formally defines the semantic model underlying `TraceAlignmentEngine`. It explicitly describes how DProvenanceKit evaluates whether two executions are behaviorally equivalent relative to a configurable equivalence evaluator. 

DProvenanceKit uses a **deterministic, threshold-based equivalence evaluator**. It evaluates event similarity against a strict `semanticThreshold` boundary, and the entire evaluator itself is extensible via the `AnyEquivalenceEvaluator` protocol. **Determinism applies to the evaluation procedure, not to metaphysical semantic correctness.** The engine guarantees a reproducible scoring function over your model.

Equivalence is defined relative to an explicit observation model parameterized by an `AlignmentProfile`. **Each configuration defines a distinct equivalence relation over the space of execution traces, corresponding to a specific observation model.**

## Scope Boundary

To prevent misinterpretation of equivalence guarantees, DProvenanceKit explicitly bounds what is evaluated:
- **Trace-observable behavior only:** Equivalence is determined strictly through the recorded causal graph. External real-world effects not captured in the trace are fundamentally out of scope.
- **Uninstrumented state:** Hidden internal system states, variables, or environment conditions that are not explicitly represented in the recorded events cannot be verified for equivalence.
- **Abstracted variance:** Stochastic model variance (such as LLM nondeterminism) or non-observable side channels are abstracted away by the equivalence evaluator provided the observable outputs satisfy the semantic threshold.
## Core Definitions

### Definition 1: Event Identity
Two events are identical if they share the exact same `typeIdentifier`, span context, engine namespace, and their underlying payload structures evaluate as exactly equal.

### Definition 2: Event Equivalence
Two events are considered semantically equivalent under an `AnyEquivalenceEvaluator` if their evaluated similarity score meets or exceeds the `semanticThreshold` defined in the active `AlignmentProfile`.

### Definition 3: Trace Equivalence
Two traces are trace-equivalent if there exists a causality-preserving alignment between their critical semantic events such that:
1. Every required (structural or critical) event in the reference trace has an equivalent counterpart.
2. The dependency structure between matched events is preserved.
3. No matched event violates causal ordering.

### Definition 4: Behavioral Equivalence
Two executions are behaviorally equivalent when their trace alignment satisfies the requirements of Trace Equivalence and preserves all observable semantic outcomes relative to an explicitly defined semantic model.

### Definition 5: Non-Equivalence (Regression)
Two executions are non-equivalent if the causality-preserving alignment fails to map one or more critical events in the reference trace to an equivalent counterpart in the comparison trace.

---

## Formal Invariants

The alignment engine adheres to the following invariants when determining equivalence:

### Invariant A — Observable Outcome Preservation
Equivalent traces must preserve all observable outputs and critical decisions. An execution that skips a critical step (e.g., authorization, validation) cannot be considered equivalent to one that performed it.

### Invariant B — Implementation Independence
Equivalent traces may differ in internal implementation details. Semantic substitution (e.g., substituting one network-fetching tool for a semantically equivalent tool or cache lookup) is permitted, provided the observable outcome is preserved under the evaluator.

### Invariant C — Independent Reordering
Equivalent traces may reorder independent operations. If Event X and Event Y have no causal dependency between them, they may execute in either order without breaking trace equivalence.

### Invariant D — Telemetry and Diagnostic Immunity
The injection, removal, or modification of telemetry, logging, or non-structural diagnostic events cannot cause non-equivalence.

### Invariant E — Causal Preservation
Equivalent traces must preserve the dependency graph between critical events.
- **Independent events** may reorder.
- **Dependent events** may not reorder.
A trace where an invoice is generated *before* a customer is created is not equivalent to a trace where the customer is created first, even if the exact same events occurred.

The engine has no dependency graph, so it enforces this conservatively: a relative-order inversion of any **critical** step is treated as non-equivalent and drives `RegressionRisk.high`, in *every* alignment mode — including the `.linear` profiles (`strictAuditV1`). `.linear` only suppresses reorder detection for non-critical (structural/telemetry) events, where order shifts are the common benign case. This is critical-*order* sensitivity, not true dependency inference: it may flag a genuinely independent pair of critical events, which is the safe direction for a regression gate.

Relative order is measured over the run's normalized event arrays: `TraceRun` sorts events by ascending `sequence` at construction, so the positions the verdict and the `.reordered` findings are computed from coincide with the authoritative causal order — regardless of the order a caller assembled the array.

### Invariant F — Temporal Variance
Execution duration does not affect behavioral equivalence unless timing itself is an explicit semantic requirement modeled in the payload. A sequence executing in 10ms is behaviorally equivalent to the same sequence executing in 200ms.

### Invariant G — Alignment Explainability
Every equivalence determination must be supported by an auditable alignment rationale. The engine must emit verifiable evidence (e.g., "Event A ↔ Event X (similarity = 0.95), causal constraints preserved") rather than an opaque boolean result.

The `ExplainabilityAuditor` fidelity scores (coverage, completeness, causal ordering, no-hallucinations) check this invariant *structurally*: they verify the engine's evidence chain is internally coherent — every claim backed by a recorded binding, evaluation, and verdict. Because the audited evidence is co-produced by the same engine run, the scores are self-consistency diagnostics, not independent verification: on the shipped pipeline, coverage and completeness are 1.0 by construction, and a wrong-but-coherently-recorded alignment scores 1.0. No score gates any engine result; the check that *does* gate equivalence is the semantic model itself (Definitions 1–5).

### Invariant H — Representation Invariance
Equivalent executions remain equivalent under permitted trace transformations that preserve semantic content. True behavioral differences are distinct from instrumentation artifacts. Changes in logging granularity, event grouping, or structurally benign representation shifts do not break equivalence provided the underlying causal relationships and semantic payloads satisfy the explicit model bounds.
