# External Evidence Anchor Contract

## Purpose

DProvenanceKit attestation and proof-pack verification establish the integrity of
the bytes that were signed and the provenance relationships recorded in that
signature. They do not, by themselves, establish when those bytes first
existed or prevent a producer with a valid signing key from creating a new,
cryptographically valid history.

An **external evidence anchor** is a separate system's record that commits to
the exact digest of an evidence artifact and provides an independently
verifiable ordering/existence signal.

This document defines the narrow interoperability boundary. It does **not**
define or require a particular anchoring service, ledger, timestamp authority,
database, or network protocol.

## Portable anchor record

An anchor exchanged across the boundary MUST carry, at minimum:

- `artifact_sha256`: lowercase SHA-256 digest of the exact evidence bytes;
- `anchored_at`: an externally assigned timestamp or equivalent ordering value;
- `anchor_id`: an identifier unique within the external anchoring system;
- `anchor_system`: identifier for the external anchoring system or authority.

An implementation MAY carry additional fields, signatures, inclusion proofs,
or ordering metadata.

The anchor MUST be treated as a statement by the external anchoring system,
not as evidence produced by DProvenanceKit or the runtime.

## Verification semantics

A verifier SHOULD keep these properties separate:

| Property | Established by |
|---|---|
| Bytes match their declared digest | Artifact verification |
| Signature is valid | DProvenanceKit attestation verification |
| Runtime identity/epoch binding is valid | WarrantKit runtime contract |
| Artifact digest was externally anchored | External anchor verification |
| Anchor ordering/existence claim is valid | External anchor authority/proof |

A valid signature is therefore not an anchor. A valid anchor for a digest does
not make the artifact's semantic claims true.

The combined result is intentionally compositional:

`runtime evidence -> DPK provenance -> external anchor -> independent verification`

## Adversarial requirement

Interoperability tests SHOULD include both:

1. **Byte mutation:** change the evidence bytes while retaining the original
   anchor. Verification MUST fail because the recomputed artifact digest no
   longer equals the anchored digest.

2. **Forged-but-valid replacement:** create a new artifact and a new,
   cryptographically valid DProvenanceKit attestation over it, but present the
   original anchor. DPK signature verification MAY succeed; external-anchor
   verification MUST fail because the new artifact digest is not the anchored
   digest.

The second case is the important boundary test. It demonstrates why internal
cryptographic validity and external existence/ordering are distinct properties.

## What this contract does not claim

This contract does not make an assertion about the trustworthiness of an
external anchor authority. It also does not establish a universal wall-clock
truth, causality beyond the anchor system's documented ordering semantics, or
truth of the underlying evidence.

The anchor is an additional trust boundary, not a replacement for the
runtime-binding or provenance checks.
