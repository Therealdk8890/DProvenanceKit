# Verification Receipt

A **Verification Receipt** is a human-facing *projection* of an existing
[`ProofPackDocument`](../Sources/DProvenanceKit/ProofPack.swift) and its embedded
[`TraceAttestation`](../Sources/DProvenanceKit/TraceAttestation.swift) /
`TraceAttestationDocument`. It does **not** introduce a new cryptographic primitive.

```
ProofPackDocument
        │
        ▼
TraceAttestationDocument  (signature + trace digest)
        │
        ▼
bound artifacts + VerificationInvariant checks
        │
        ▼
VerificationReceipt projection   ← this document
        │
        ├─► CaseClarity UI (consumer)
        └─► dprovenancekit-action / CI (consumer)
```

CaseClarity and the CI Action must not invent independent meanings of "verified."
Both consume the same receipt projection rules and the same machine-readable
invariant.

## What Verified means (and does not)

| Status | Meaning |
| --- | --- |
| `verified` | Required steps occurred in the required order **and** cryptographic integrity checks passed. |
| `incomplete` | An artifact or claim text may exist, but required provenance / invariant evidence is missing (for example, a missing `verify` step). |
| `tampered` | Previously bound evidence or attestation no longer validates (digest mismatch, failed signature, or equivalent). |

**Verified does not mean the claim is objectively true.**

It means:

> The claim has a valid, integrity-protected provenance record that satisfies the
> declared verification requirements.

That boundary matters for legal / evidence applications. Cryptography can protect
integrity of a recorded path; it cannot certify factual truth of the claim text.

## Schemas and fixtures

| Path | Role |
| --- | --- |
| [`schemas/verification-receipt.schema.json`](../schemas/verification-receipt.schema.json) | JSON Schema for the receipt projection |
| [`schemas/verification-invariant.schema.json`](../schemas/verification-invariant.schema.json) | JSON Schema for shared invariants |
| [`fixtures/verification-receipt/invariant-claim-path-v1.json`](../fixtures/verification-receipt/invariant-claim-path-v1.json) | Canonical `claim-path-v1` invariant instance |
| [`fixtures/verification-receipt/verified.json`](../fixtures/verification-receipt/verified.json) | Golden: full chain, integrity OK |
| [`fixtures/verification-receipt/incomplete.json`](../fixtures/verification-receipt/incomplete.json) | Golden: `verify` missing |
| [`fixtures/verification-receipt/tampered.json`](../fixtures/verification-receipt/tampered.json) | Golden: integrity failure |

Digests and key IDs in fixtures are **examples** for the test matrix, not live
signing material.

## Machine-readable invariant

`claim-path-v1` (see the fixture) declares:

- `required_steps`: `evidence`, `extract`, `verify`, `claim`
- `must_include`: `verify`
- `ordering`: `evidence < extract < verify < claim`

The **same** invariant definition is intended to drive:

1. DPK runtime validation (when projecting a receipt)
2. CaseClarity receipt status
3. `dprovenancekit-action` / synthetic regression
4. Golden-vector tests in Swift and Python

If UI and CI disagree on status for the same inputs, that is a bug in a consumer —
not a license to fork the semantics.

### Evaluating status (normative sketch)

Given a proof pack (or equivalent attestation + bound artifacts), an invariant, and
current source bytes:

1. Verify the attestation (`TraceAttestation` / document verify). If invalid →
   `tampered` (integrity.trace = false).
2. Verify proof-pack artifact digests and bindings. If invalid → `tampered`
   (integrity.evidence = false and/or files_unchanged = false).
3. Recompute source file hashes; if they diverge from bound digests → `tampered`
   (files_unchanged = false).
4. Project ordered `steps` from the instrumented path. If `required_steps` /
   `must_include` / `ordering` fail → `incomplete` (even when integrity is true).
5. Otherwise → `verified`.

Integrity flags on the receipt are a **summary of those checks**, not a second
crypto layer.

## Field map (projection → existing types)

| Receipt field | Existing DPK surface |
| --- | --- |
| `sources[].content_hash` | `ProofPackArtifact.sha256` |
| `sources[].role` | `ProofPackArtifact.role` |
| `attestation.run_id` | `TraceAttestation.runID` |
| `attestation.context_id` | `TraceAttestation.contextID` |
| `attestation.trace_digest` | `TraceAttestation.traceDigest` |
| `attestation.key_id` | `TraceAttestation.keyID` |
| `projection.proof_pack_version` | `ProofPackDocument.proofPackVersion` |
| `steps[].type` | Projected from instrumented event `typeIdentifier` / roles (consumer mapping tables live with the app / Action) |

`receipt_id` / `short_hash` are projection identifiers for UI and correlation; they
are not a new signature envelope.

## Non-goals (Phase 0)

- No new signing scheme, digest algorithm, or attestation envelope
- No CaseClarity UI in this change set
- No Swift/Python encoder required to land the contract (implementations come next)
- No generalized multi-domain receipt framework — one invariant (`claim-path-v1`)
  and three fixtures are enough to lock the shared meaning of Verified

## Next

Once this contract is merged: implement the smallest CaseClarity claim path that
emits a `VerificationReceipt` by projecting a real proof pack through
`claim-path-v1`, then wire the Action to the same invariant for the
missing-`verify` failure mode.
