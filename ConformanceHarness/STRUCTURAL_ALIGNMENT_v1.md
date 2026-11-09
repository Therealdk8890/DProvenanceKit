# Structural Alignment Contract v1 (experimental)

**Status:** experimental, separate from frozen Trace Specification v1. This document defines a proposed conformance target; it does not assert that either SDK currently implements or passes it.

## Purpose

Detect missing required steps, execution-order drift, and parent/child hierarchy drift in an agent trace. The contract is deterministic and language-neutral. It is not a claim about the truth of an agent's reasoning or unrecorded internal state.

## Configuration

The fixture uses three independently scored components:

- `type`: exact event-type agreement.
- `hierarchy`: exact parent identity agreement (including root/null).
- `payload`: exact payload-signature agreement.

The score is the weighted sum:

`node_score = 0.50 * type + 0.30 * hierarchy + 0.20 * payload`

Each component is binary (0 or 1). Candidate events may be assigned to at most one target event. A candidate-target pair is eligible for a mapping when its node score is greater than or equal to `min_node_conformance`. Ties are resolved by candidate sequence, then candidate ID. An implementation must document and reproduce this deterministic assignment rule.

## Aggregate metric

Use standard micro-averaged F1 over the one-to-one eligible mappings:

- TP: eligible target/candidate pairs.
- FN: target events without an eligible candidate mapping.
- FP: candidate events not consumed by an eligible mapping.

`precision = TP / (TP + FP)`; `recall = TP / (TP + FN)`; `F1 = 2 * precision * recall / (precision + recall)`.

A zero denominator produces 0.0. Compare unrounded values to thresholds; round only for display. This definition makes the three-target/two-candidate missing-step example F1 = 0.8 (TP=2, FP=0, FN=1), not 0.666.

## Strict gate

A case conforms only when all are true:

1. Every required target node meets `min_node_conformance`.
2. Global micro-F1 meets `min_global_f1_floor`.
3. The candidate preserves target causal order for all mapped required nodes.
4. The mapped parent relationships match for every required node.

Order and hierarchy are independent constraints: a high F1 score cannot override either violation. Node verdicts must expose the target ID, candidate ID (or null), component scores, weighted score, and stable reason code.

## Required reason codes

- `MISSING_REQUIRED_EVENT`
- `NODE_SCORE_BELOW_THRESHOLD`
- `REORDERED_REQUIRED_EVENTS`
- `PARENT_HIERARCHY_MISMATCH`
- `CONFORMANT`

## Fixture family

`vectors/structural_alignment_v1.json` covers missing required events, reordering, parent shift, combined drift, and inclusive threshold-boundary behavior. The fixture is a contract proposal until both SDK harnesses execute it against their production alignment engines and reproduce every mapping, node verdict, count, metric, and gate result.

## Compatibility

Do not edit or regenerate the frozen Trace Specification v1 vectors to introduce this behavior. This contract is independently versioned. A future promotion into a Trace Spec release requires implementation in both SDKs, cross-language test parity, and an explicit compatibility decision.
