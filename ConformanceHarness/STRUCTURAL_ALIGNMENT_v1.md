# Structural Alignment Contract v1 (experimental)

**Status:** experimental, separately versioned from frozen Trace Specification v1. Both SDK production engines currently have shared-vector tests; conformance remains limited to the published corpus and is not a release claim.

## Purpose and verdict model

Detect missing required steps, extra candidate steps, execution-order drift, and parent/child hierarchy drift in recorded agent traces. This contract concerns recorded events, not the truth of an agent's reasoning or unrecorded internal state.

The result MUST report independent outcomes:
- **Alignment quality:** TP, FP, FN, and per-run micro-F1, plus whether the configured F1 floor passed.
- **Strict conformance:** whether every required target node mapped, the F1 floor passed, and both hierarchy and order gates passed.
- **Empty-input status:** explicitly identifies the case where both traces contain zero nodes. Empty input is not evidence of a successful conformance run and MUST NOT be reported as strict conformance.

A high F1, including 1.0, does not imply strict conformance.

## Input invariants

Each side is an ordered list of events with a unique, non-empty string `id`, nullable `parent_id`, `type`, and `payload_signature`. Array position is the event sequence used for deterministic ordering. A parent reference must resolve to an event on the same side. Parent graphs must be acyclic. Invalid IDs, duplicate IDs, dangling parent references, or cycles are invalid input and must produce a validation error rather than a partial result. Empty arrays are valid inputs.

## Scoring and fixed-point arithmetic

The three independently scored components are binary:
- `type`: exact event-type agreement.
- `hierarchy`: exact parent relationship agreement.
- `payload`: exact payload-signature agreement.

The canonical numeric representation is integer basis points (bps), where 10,000 bps = 1.0. Weights and thresholds MUST be represented as integer bps in the v1 configuration contract. Component weights MUST sum to exactly 10,000 bps. For a pair:

`node_score_bps = type_weight_bps * type + hierarchy_weight_bps * hierarchy + payload_weight_bps * payload`

No floating-point arithmetic or epsilon is used for eligibility, sorting, or gate comparisons. Convert a user-facing decimal to bps only at the API boundary; conversion MUST be exact to one basis point, otherwise reject the value. Floating-point values are not canonical configuration values. Returned display scores may be represented as decimal numbers derived from integer bps.

For a target root, hierarchy is 1 only for a candidate root. For a target child whose parent has been mapped, hierarchy is 1 only when the candidate's `parent_id` equals the mapped candidate ID for that target parent. If the target parent has no eligible mapping, hierarchy is 0 for every candidate. This parent-first definition removes circular dependency between parent and child matching.

## Deterministic assignment

Assignment is one-to-one and parent-first:
1. Compute each target event's depth in its validated parent graph.
2. Process target events by ascending depth. Within a depth, target order is input sequence, then target ID lexicographically.
3. For the current depth, score every pair between those target events and **all currently unassigned candidate events**. Candidate events are not restricted to the same depth: a misplaced candidate must remain detectable as a hierarchy-drift suggestion.
4. A pair is eligible when `node_score_bps >= min_node_conformance_bps` (inclusive).
5. Sort eligible pairs by: node score bps descending; candidate input sequence ascending; candidate ID lexicographically ascending; target input sequence ascending; target ID lexicographically ascending. Greedily accept a pair only when neither endpoint has already been assigned.
6. This is the normative deterministic score-ordered greedy assignment. It is not Hungarian matching or a globally maximum-weight assignment. A greedy result may contain fewer mappings than a globally optimal assignment; that behavior is intentional and fixture-tested.
7. Continue to the next target depth using the parent mappings established by earlier depths.

## Diagnostic suggestions and mapping status

A diagnostic suggestion is not a mapping and never contributes to TP. For each target left unmatched after eligible assignment, inspect candidate events that remain unassigned. If any remain with a strictly positive node score, select the best suggestion by node score bps descending, candidate input sequence ascending, then candidate ID lexicographically ascending.

- `candidate_id`: the actual eligible mapping; null when no mapping exists.
- `suggested_candidate_id`: best rejected diagnostic candidate, or null when none remains.
- Component scores and node score describe the actual mapping when `candidate_id` is non-null; otherwise they describe the suggestion, or are all zero when neither exists.
- An unmatched target with a suggestion whose hierarchy score is 0 receives `PARENT_HIERARCHY_MISMATCH`; otherwise a suggestion below threshold receives `NODE_SCORE_BELOW_THRESHOLD`; with no positive-score suggestion it receives `MISSING_REQUIRED_EVENT`.
- Suggestions are selected only after eligible assignment and cannot reuse a candidate consumed by a mapping.
- A below-threshold pair is **not** a mapping: its target contributes one FN and its unassigned candidate contributes one FP. The diagnostic pair contributes no TP.

For a mapped pair, strict node-gate reason precedence is `PARENT_HIERARCHY_MISMATCH`, then `REORDERED_REQUIRED_EVENTS`, then `CONFORMANT`. Mapping eligibility and strict conformance are distinct: an eligible pair can count as TP while failing an independent hierarchy or order gate.

## Per-run micro-F1 and empty traces

Micro-F1 is computed independently for each single target/candidate trace comparison, not pooled across runs or across the fixture corpus:
- TP: eligible one-to-one target/candidate mappings, including mappings that later fail an independent order or hierarchy gate.
- FN: target events without an eligible mapping.
- FP: candidate events not consumed by an eligible mapping.
- Diagnostic suggestions do not affect any count.

`F1 = 2 * TP / (2 * TP + FP + FN)`. If the denominator is zero (both traces empty), define F1 as **1.0** for the metric only, set `empty_input = true`, and force strict conformance to false. This prevents division by zero without treating absence of evidence as a pass. If exactly one side is empty, F1 is 0.0 and `empty_input = false`. Compare exact integer counts/ratios to the configured F1 floor without rounding; round only for display.

## Strict case gates

A non-empty case conforms only when all are true:
1. Every required target node has an eligible mapping.
2. Per-run micro-F1 meets `min_global_f1_floor`.
3. Candidate sequence preserves target sequence for all mapped required nodes (no pairwise inversion).
4. Every mapped required node has the correct parent relationship.

Hierarchy and order are independent gates. The result MUST expose `f1_gate_passed`, `hierarchy_gate_passed`, `order_gate_passed`, `all_required_nodes_meet_score_threshold`, `empty_input`, and the strict `conforming` verdict separately. Empty/empty has F1=1.0 but `empty_input=true` and `conforming=false`.

Node verdicts expose target ID, mapped candidate ID or null, suggested candidate ID or null, component scores, weighted score, matched status, node-gate status, and stable reason code.

## Required reason codes

- `MISSING_REQUIRED_EVENT`
- `NODE_SCORE_BELOW_THRESHOLD`
- `REORDERED_REQUIRED_EVENTS`
- `PARENT_HIERARCHY_MISMATCH`
- `CONFORMANT`

## Fixture family

The shared vector corpus includes missing and extra events, reordered events, duplicate event types with distinct payload signatures, deterministic tie-breaking, a greedy-vs-optimal counterexample, parent hierarchy drift, below-threshold suggestions, inclusive threshold boundaries, multi-level hierarchy drift, and empty-trace cases. Every fixture is executed by both production engines. Fixture arithmetic-only tests are supplementary and do not establish engine conformance.

## Compatibility

Do not edit or regenerate frozen Trace Specification v1 vectors to introduce this behavior. Structural Alignment v1 is independently versioned. Promotion requires both production implementations to reproduce the shared corpus, complete per-node outputs, metrics and gates, plus an explicit compatibility decision.
