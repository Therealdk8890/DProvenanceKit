# Proof Packs

A **proof pack** is a single, self-contained JSON document that carries a signed trace
attestation **plus the artifact bytes the trace vouches for** — a report, a generated
document, a dataset extract — so a reviewer can verify the whole bundle offline with one
command:

```bash
dpk verify --in=pack.json --proof-pack --trusted-key=<64-hex-key-id>
```

The attestation proves the trace is intact and signed; the pack proves each embedded
artifact is **the** artifact that trace refers to, because the artifact's SHA-256 — and, in
v2, its `role` alongside it — appears inside the signed event payloads. Verification needs
no network, no original store, and no knowledge of the producing tool.

## Format (`proofPackVersion: 2`)

```jsonc
{
  "proofPackVersion": 2,
  "attestation": { /* a complete TraceAttestationDocument (see ATTESTATION.md) */ },
  "artifacts": [
    {
      "role": "claim-proof-report",       // producer-defined label, non-empty; SIGNER-VOUCHED in v2
      "mediaType": "application/json",     // informational; NOT covered by any check
      "encoding": "utf8",                  // "utf8" | "base64"
      "content": "…artifact bytes…",       // per encoding
      "sha256": "…64 lowercase hex…"       // SHA-256 of the decoded bytes
    }
  ]
}
```

- `attestation` is an unmodified `TraceAttestationDocument`. Proof packs add nothing to
  the canonical or signed bytes — an attestation signed before proof packs existed can be
  wrapped in one, and unwrapping never invalidates it. v2 strengthens the *binding check*,
  not the signed bytes, so no re-signing is needed as long as the trace already records the
  role co-located with the digest (which the producer rules below have always prescribed).
- `artifacts` must contain at least one entry. A pack with no artifacts is just an
  attestation; use `dpk verify --in=<attestation.json>` for that.
- `sha256` is declared by the producer and re-derived by the verifier; it is the binding
  key, not a trust anchor by itself.

### Versions and binding strength

| Version | Binding check | `role` / `mediaType` | Status |
|---|---|---|---|
| **2** (default) | a signed payload object has a `role` key = the artifact's role **and** a `sha256` key = its digest | `role` signer-vouched; `mediaType` informational | current |
| **1** | digest present as a string leaf anywhere in a signed payload | both producer-asserted, **not** signature-covered | accepted, labeled |

The verifier still accepts v1 packs, but reports their binding as **value-presence only** —
`ProofPackVerification.bindingStrength == .valuePresenceOnly`, and `dpk verify` prints a
warning. In a v1 pack, someone who can rewrite the sidecar can change `role` (or `mediaType`)
to anything without invalidating the signature, because those fields were never covered.
**Re-issue as v2** to make the role signer-vouched. `mediaType` is informational in both
versions; do not treat it as vouched.

A consumer that integrates on the pass/fail bit can require the strong binding and reject v1
outright: `pack.verify(requireRoleBinding: true)` fails a value-presence-only pack with
`ProofPackVerificationFailure.roleBindingRequired`, and the CLI exposes this as
`dpk verify --proof-pack --require-role-binding` (exit 1 on a v1 pack).

## Producer rules

1. Compute the SHA-256 (lowercase hex) of the exact artifact bytes you will embed.
2. **Before attesting**, record an event whose payload carries an object with a `role` key
   (the artifact's role) and a `sha256` key (the hex digest) **together in the same object**,
   e.g. `{"proofPackArtifact":{"role":"claim-proof-report","sha256":"…"}}`. Any event type
   works and the object may sit at any depth, but v2 matches these two specific keys — the
   `role` key is what makes the role signer-vouched (a digest sitting next to some other
   string, like a `status`, does not bind that string as the role). The object may carry
   other keys freely.
3. Attest the run as usual (`TraceAttestationDocument.signed(run:…)`).
4. Assemble the pack: attestation + artifact entries, using the same `role` you recorded.
   Embed bytes exactly as hashed. New packs default to v2.

If the artifact's hash (v1) or its hash-plus-role (v2) is not in the trace before signing,
the pack cannot verify — by design. Binding is only meaningful when the signature covers it.

## Verification algorithm (fail-closed)

Given a pack and an optional trusted-key set:

1. Decode the document. `proofPackVersion` must be within the supported range
   (`1`…`2` today); anything outside is rejected, never skipped.
2. `artifacts` must be non-empty and each entry well-formed (`role` non-empty, decodable
   `content`, `sha256` = 64 lowercase hex).
3. Verify `attestation` exactly as `dpk verify` does today, including trusted-key pinning
   semantics. Any attestation failure fails the pack.
4. For each artifact:
   a. Decode `content` per `encoding`; recompute SHA-256; it must equal `sha256`
      (declared-digest check — catches corrupted or substituted bytes).
   b. Parse every attested event's `payloadJSON`. **v2:** some object in a payload must have
      a `role` key equal to the artifact's `role` and a `sha256` key equal to its digest
      (binding check — ties the bytes *and their role* to the signed run). **v1:** the
      `sha256` must appear as a string leaf in at least one payload (digest presence only).
5. All artifacts must bind. With `--require-role-binding`, a v1 pack is rejected here even
   though its digests are present. Exit codes match `verify`: `0` valid, `1` invalid or
   unreadable, `2` malformed arguments.

The verifier reports, per artifact, which event (index and `typeIdentifier`) bound it, and
the overall binding strength (`role signer-vouched` for v2, a warning for v1).

## What a valid proof pack does — and does not — establish

Everything in ATTESTATION.md's threat model applies unchanged. In addition:

- **It establishes:** the embedded artifact bytes are the ones whose SHA-256 the signer
  placed inside the trace before signing (artifact-to-run binding) — and, in **v2**, under
  the `role` the signer recorded next to that digest, so the role cannot be relabeled after
  signing. The trace itself is intact (and from a pinned signer, when `--trusted-key` is
  used).
- **It does not establish:** that the artifact's *contents* are true, complete, or
  correctly produced; that the events describing the artifact are honest; or anything
  about wall-clock time. A proof pack wraps integrity around an artifact — it does not
  audit the artifact. In a **v1** pack it additionally does *not* establish the `role` or
  `mediaType`: those are producer-asserted and outside the signature (re-issue as v2). In
  both versions `mediaType` is informational only.

Embedded artifacts, like payloads, are carried in plaintext. Redact before a pack leaves
the device.

## Layering note: domain fingerprints vs. file digests

Producing tools often have their own *content* fingerprints (for example, ClaimProofKit's
report fingerprint hashes claim/verdict pairs, deliberately ignoring timestamps and
formatting). Proof packs do not replace or interpret those: the pack binds **bytes**;
domain fingerprints prove **semantic identity** and remain the producing tool's contract.
A consumer that understands the artifact format is free to additionally recompute the
domain fingerprint from the embedded bytes and match it against the same trace — both
values can, and should, live in the signed payloads.
