# Proof Packs

A **proof pack** is a single, self-contained JSON document that carries a signed trace
attestation **plus the artifact bytes the trace vouches for** — a report, a generated
document, a dataset extract — so a reviewer can verify the whole bundle offline with one
command:

```bash
dpk verify --in=pack.json --proof-pack --trusted-key=<64-hex-key-id>
```

The attestation proves the trace is intact and signed; the pack proves each embedded
artifact is **the** artifact that trace refers to, because the artifact's SHA-256 appears
inside the signed event payloads. Verification needs no network, no original store, and no
knowledge of the producing tool.

## Format (`proofPackVersion: 1`)

```jsonc
{
  "proofPackVersion": 1,
  "attestation": { /* a complete TraceAttestationDocument (see ATTESTATION.md) */ },
  "artifacts": [
    {
      "role": "claim-proof-report",       // producer-defined label, non-empty
      "mediaType": "application/json",     // informational
      "encoding": "utf8",                  // "utf8" | "base64"
      "content": "…artifact bytes…",       // per encoding
      "sha256": "…64 lowercase hex…"       // SHA-256 of the decoded bytes
    }
  ]
}
```

- `attestation` is an unmodified `TraceAttestationDocument`. Proof packs add nothing to
  the canonical or signed bytes — an attestation signed before proof packs existed can be
  wrapped in one, and unwrapping never invalidates it.
- `artifacts` must contain at least one entry. A pack with no artifacts is just an
  attestation; use `dpk verify --in=<attestation.json>` for that.
- `sha256` is declared by the producer and re-derived by the verifier; it is the binding
  key, not a trust anchor by itself.

## Producer rules

1. Compute the SHA-256 (lowercase hex) of the exact artifact bytes you will embed.
2. **Before attesting**, record an event whose payload carries that hex string as a value
   (e.g. `{"proofPackArtifact":{"role":"claim-proof-report","sha256":"…"}}`). Any event
   type works; the verifier matches the value, not the schema.
3. Attest the run as usual (`TraceAttestationDocument.signed(run:…)`).
4. Assemble the pack: attestation + artifact entries. Embed bytes exactly as hashed.

If the artifact's hash is not in the trace before signing, the pack cannot verify — by
design. Binding is only meaningful when the signature covers it.

## Verification algorithm (fail-closed)

Given a pack and an optional trusted-key set:

1. Decode the document. `proofPackVersion` must be `1`; unknown versions are rejected,
   never skipped.
2. `artifacts` must be non-empty and each entry well-formed (`role` non-empty, decodable
   `content`, `sha256` = 64 lowercase hex).
3. Verify `attestation` exactly as `dpk verify` does today, including trusted-key pinning
   semantics. Any attestation failure fails the pack.
4. For each artifact:
   a. Decode `content` per `encoding`; recompute SHA-256; it must equal `sha256`
      (declared-digest check — catches corrupted or substituted bytes).
   b. Parse every attested event's `payloadJSON` and walk all string leaves. The
      artifact's `sha256` must appear as a leaf value in at least one payload
      (binding check — ties the bytes to the signed run).
5. All artifacts must bind. Exit codes match `verify`: `0` valid, `1` invalid or
   unreadable, `2` malformed arguments.

The verifier reports, per artifact, which event (index and `typeIdentifier`) bound it.

## What a valid proof pack does — and does not — establish

Everything in ATTESTATION.md's threat model applies unchanged. In addition:

- **It establishes:** the embedded artifact bytes are the ones whose SHA-256 the signer
  placed inside the trace before signing (artifact-to-run binding), and the trace itself
  is intact (and from a pinned signer, when `--trusted-key` is used).
- **It does not establish:** that the artifact's *contents* are true, complete, or
  correctly produced; that the events describing the artifact are honest; or anything
  about wall-clock time. A proof pack wraps integrity around an artifact — it does not
  audit the artifact.

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
