# Deterministic Configuration Authorization v1

**Status:** experimental, versioned independently from Trace Specification v1 and Structural Alignment v1.

## Security model

A configuration fingerprint identifies canonical configuration bytes. It does not authenticate the author, authorize execution, prove that a configuration is safe, or prove that a trace is true.

Authorization has two layers:

1. **Pinned fingerprint:** compute SHA-256 over canonical bytes and compare it with an independently reviewed expected fingerprint. A mismatch fails closed.
2. **Signed manifest:** verify an Ed25519 signature over domain-separated canonical configuration bytes using a public key obtained from an independently trusted key policy. A valid signature authenticates the signer relative to that trust policy; it does not establish that the configuration is safe.

A computed hash must never be treated as its own authorization. The expected hash or trusted public key must not be sourced from the configuration or manifest being verified.

## Canonical configuration schema

The v1 configuration is a closed object with exactly these fields:

- `algorithm`: ASCII identifier; v1 structural alignment uses `structural-alignment-v1`.
- `min_global_f1_bps`: integer in [0, 10000].
- `min_node_conformance_bps`: integer in [0, 10000].
- `schema_version`: exactly `dpk-config-v1`.
- `weight_hierarchy_bps`: integer in [0, 10000].
- `weight_payload_bps`: integer in [0, 10000].
- `weight_type_bps`: integer in [0, 10000].

All numeric values are integer basis points (10000 = 1.0). Floating-point JSON values are forbidden, including values that happen to be mathematically integral. NaN and infinities are invalid. Negative values, out-of-range values, missing fields, unknown fields, non-ASCII identifiers, and weights that do not sum to exactly 10000 must be rejected before hashing.

This integer representation avoids cross-runtime floating-point formatting differences. Convert user-facing decimal settings to basis points only at the API boundary, using a documented rounding rule; the canonical contract accepts integers only.

## Canonical byte serialization

The canonical representation is UTF-8 JSON with exactly the seven schema fields, keys in ascending Unicode code-point order, no insignificant whitespace, ASCII identifiers, base-10 integers, no trailing newline, and no byte-order mark.

The canonical property order is:

`algorithm`, `min_global_f1_bps`, `min_node_conformance_bps`, `schema_version`, `weight_hierarchy_bps`, `weight_payload_bps`, `weight_type_bps`.

Implementations hash these exact bytes, not a language-native description or debug string. Both SDKs consume the same golden and negative vectors.

## Fingerprint

The fingerprint is lowercase hexadecimal SHA-256 of the canonical UTF-8 bytes. It is an identifier, not a signature. Pinned mode compares it with an expected value supplied separately from the candidate configuration.

## Signed manifest v1

The detached manifest is a closed JSON object with exactly:

- `manifest_version`: `dpk-config-manifest-v1`.
- `algorithm`: `Ed25519`.
- `key_id`: ASCII identifier resolved only through trusted policy.
- `configuration_fingerprint`: 64-character lowercase SHA-256 hex.
- `signature`: 128-character lowercase hex encoding of the 64-byte Ed25519 signature.

The signed message is exactly:

```text
DPK-CONFIG-MANIFEST-V1\n
```

followed immediately by the canonical configuration bytes. The newline above is one byte (LF, 0x0A); it is not the two characters backslash and n.

Verification order is fixed:

1. Validate the configuration and produce canonical bytes.
2. Validate the closed manifest schema and encodings.
3. Recompute the configuration fingerprint and compare it with the manifest value.
4. Resolve `key_id` only in the caller-supplied trusted-key policy.
5. Reject unknown or revoked keys and enforce any key validity bounds.
6. Verify the Ed25519 signature over the domain separator plus canonical bytes.

The trusted-key policy contains a raw 32-byte public key, a revocation flag, and optional Unix-second `not_before` and `expires_at` bounds. `not_before` is inclusive; `expires_at` is exclusive. If either bound is configured, the caller must provide an explicit verification time. The manifest cannot add a public key or modify the trust policy.

Python keeps the core package standard-library-only. Ed25519 verification uses the existing optional `cryptography` backend; install `dprovenancekit[crypto]` to use signed manifests. Swift uses CryptoKit. No private signing key is included in either repository or in test fixtures.

## Required shared vectors

The shared vector includes canonical bytes and digest, invalid configuration cases, and an Ed25519 manifest signed by a test-only private key whose public key and detached signature are published. Tests supply that public key separately as a trusted policy entry. The private seed is not included.

Both SDKs must verify the same signature and reject unknown, revoked, not-yet-valid, and expired keys; missing policy time; invalid signatures; unknown manifest fields; and configuration/manifest fingerprint mismatches.

## Compatibility and rollout

This contract does not modify frozen Trace Specification v1 vectors or existing alignment profile hashes. Signed manifests are additive to pinned-fingerprint verification. Promotion from experimental status requires matching Python/Swift results, negative tests, and explicit compatibility review.
