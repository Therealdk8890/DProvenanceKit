# Structural Alignment Contract v1 (experimental)

**Status:** experimental, separate from frozen Trace Specification v1. This document defines a language-neutral conformance target; it does not assert that either SDK currently implements or passes it.

## Purpose

Detect missing required steps, execution-order drift, and parent/child hierarchy drift in recorded agent traces. This contract concerns recorded events, not the truth of an agent's reasoning or unrecorded internal state.

## Input invariants

Each side is an ordered list of events with a unique, non-empty string `id`, nullable `parent_id`, `type`, and `payload_signature`. Array position is the event sequence used for deterministic ordering. A parent reference must resolve to an event on the same side. Parent graphs must be acyclic. Invalid IDs, duplicate IDs, dangling parent references, or cycles are invalid input and must produce a validation error rather than a partial result.

## Scoring

The three independently scored components are binary:

- `type`: exact event-type agreement.
- `hierarchy`: exact parent relationship agreement.
- `payload`: exact payload-signature agreement.

`node_score = 0.50 * type + 0.30 * hierarchy + 0.20 * payload`

For a target root, hierarchy is 1 only for a candidate root. For a target child whose parent has been mapped, hierarchy is 1 only when the candidate's `parent_id` equals the mapped candidate ID for that target parent. If the target parent has no eligible mapping, hierarchy is 0 for every candidate. This parent-first definition removes circular dependency between parent and child matching.

## Deterministic assignment

Assignment is one-to-one and parent-first:

1. Compute each target event's depth in its validated parent graph.
2. Process target events by ascending depth. Within a depth, target order is input sequence, then target ID lexicographically.
3. For the current depth, score every pair between those target events and **all currently unassigned candidate events**. Candidate events are not restricted to the same depth: a misplaced candidate must remain detectable as a hierarchy-drift suggestion.
4. A pair is eligible when `node_score >= min_node_conformance` (inclusive).
5. Sort eligible pairs by: node score descending; candidate input sequence ascending; candidate ID lexicographically ascending; target input sequence ascending; target ID lexicographically ascending. Greedily accept a pair only when neither endpoint has already been assigned. This is the normative deterministic greedy assignment, not a claim of globally maximum-weight bipartite matching.
6. Continue to the next target depth using the parent mappings established by earlier depths.

All comparisons use unrounded component and weighted scores. The inputs are binary and weights are decimal configuration values; implementations must use a consistent numeric representation and compare the computed weighted score directly to the threshold. Round only for display.

## Diagnostic suggestions and mapping status

A diagnostic suggestion is not a mapping and never contributes to TP. For each target left unmatched after eligible assignment, inspect candidate events that remain unassigned. If any remain with a strictly positive node score, select the best suggestion by node score descending, candidate input sequence ascending, then candidate ID lexicographically ascending.

- `candidate_id`: the actual eligible mapping; null when no mapping exists.
- `suggested_candidate_id`: best rejected diagnostic candidate, or null when none remains.
- Component scores and `node_score` describe the actual mapping when `candidate_id` is non-null; otherwise they describe the suggestion, or are all zero when neither exists.
- An unmatched target with a suggestion whose hierarchy score is 0 receives `PARENT_HIERARCHY_MISMATCH`; otherwise a suggestion below threshold receives `NODE_SCORE_BELOW_THRESHOLD`; with no positive-score suggestion it receives `MISSING_REQUIRED_EVENT`.
- Suggestions are selected only after eligible assignment and cannot reuse a candidate consumed by another mapping.

For a mapped pair, strict node-gate reason precedence is `PARENT_HIERARCHY_MISMATCH`, then `REORDERED_REQUIRED_EVENTS`, then `CONFORMANT`. Mapping eligibility and strict conformance are distinct: an eligible pair can count as TP while failing an independent hierarchy or order gate.

## Aggregate metric

Use standard micro-F1 over one-to-one eligible mappings:

- TP: eligible target/candidate mappings, including mappings that later fail an independent order or hierarchy gate.
- FN: target events without an eligible mapping.
- FP: candidate events not consumed by an eligible mapping.

`F1 = 2 * TP / (2 * TP + FP + FN)`. A zero denominator produces 0.0. Compare unrounded values to `min_global_f1_floor`; round only for display.

## Strict case gates

A case conforms only when all are true:

1. Every required target node has an eligible mapping.
2. Global micro-F1 meets `min_global_f1_floor`.
3. Candidate sequence preserves target sequence for all mapped required nodes (no pairwise inversion).
4. Every mapped required node has the correct parent relationship.

Hierarchy and order are independent gates; a high F1 cannot override either violation. Node verdicts expose target ID, mapped candidate ID or null, suggested candidate ID or null, component scores, weighted score, matched status, node-gate status, and stable reason code.

## Required reason codes

- `MISSING_REQUIRED_EVENT`
- `NODE_SCORE_BELOW_THRESHOLD`
- `REORDERED_REQUIRED_EVENTS`
- `PARENT_HIERARCHY_MISMATCH`
- `CONFORMANT`

## Fixture family

`vectors/structural_alignment_v1.json` covers missing events, reordering, parent shift, combined drift, and inclusive threshold-boundary behavior. A below-threshold hierarchy-shift candidate is diagnostic only and does not count as TP. At the inclusive boundary, a 0.70 pair at a 0.70 threshold is mapped (TP), while its independent hierarchy gate still fails. Fixtures remain contract proposals until both SDK production engines reproduce mappings, suggestions, node verdicts, counts, metrics, and gates.

## Compatibility

Do not edit or regenerate frozen Trace Specification v1 vectors to introduce this behavior. Structural Alignment v1 is independently versioned. Promotion requires implementation in both SDKs, cross-language parity, and an explicit compatibility decision.
