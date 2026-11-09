# Deterministic Configuration Authorization v1

**Status:** experimental, versioned independently from Trace Specification v1 and Structural Alignment v1.

## Security model

A configuration fingerprint identifies canonical configuration bytes. It does not authenticate the author, authorize execution, prove that a configuration is safe, or prove that a trace is true.

Authorization has two supported layers:

1. **Pinned fingerprint (initial CI mode):** compute SHA-256 over the canonical bytes and compare it with an independently reviewed, repository-pinned expected fingerprint. A mismatch fails closed.
2. **Signed manifest (stronger authorization mode):** verify an Ed25519 signature over the domain-separated canonical configuration bytes using a public key obtained from an independently trusted key policy. A valid signature authenticates the signer relative to that trust policy; it does not establish that the configuration is safe.

A computed hash must never be treated as its own authorization. The expected hash or trusted public key must not be sourced from the configuration being verified.

## Canonical configuration schema

The v1 configuration is a closed object with exactly these fields:

- `algorithm`: ASCII identifier; v1 structural alignment uses `structural-alignment-v1`.
- `min_global_f1_bps`: integer in [0, 10000].
- `min_node_conformance_bps`: integer in [0, 10000].
- `schema_version`: exactly `dpk-config-v1`.
- `weight_hierarchy_bps`: integer in [0, 10000].
- `weight_payload_bps`: integer in [0, 10000].
- `weight_type_bps`: integer in [0, 10000].

All numeric values are integer basis points (10000 = 1.0). Floating-point JSON values are forbidden, including values that happen to be mathematically integral. NaN and infinities are invalid JSON/configuration values. Negative values, out-of-range values, missing fields, unknown fields, non-ASCII identifiers, and weights that do not sum to exactly 10000 must be rejected before hashing.

This integer representation deliberately avoids cross-runtime floating-point formatting differences (for example, `1` versus `1.0`, exponent notation, and binary rounding). Convert user-facing decimal settings to basis points only at the API boundary, using a documented rounding rule; the canonical contract accepts integers only.

## Canonical byte serialization

The canonical representation is UTF-8 JSON with:

- exactly the seven schema fields above;
- object keys in ascending Unicode code-point order (all v1 keys are ASCII);
- no insignificant whitespace;
- JSON strings restricted to the documented ASCII identifier grammar;
- base-10 integer numbers with no leading zeroes (except zero);
- no trailing newline or byte-order mark.

The canonical property order is:

`algorithm`, `min_global_f1_bps`, `min_node_conformance_bps`, `schema_version`, `weight_hierarchy_bps`, `weight_payload_bps`, `weight_type_bps`.

Implementations must hash these exact bytes, not a language-native description or debug string. The golden vector file publishes the canonical byte string and SHA-256 digest. Both SDKs must reproduce them byte-for-byte.

## Fingerprint

The configuration fingerprint is lowercase hexadecimal SHA-256 of the canonical UTF-8 bytes. The fingerprint is an identifier, not a signature.

CI pinned mode must compare the computed fingerprint to an expected value committed separately from the candidate configuration and reviewed as policy. A candidate must not be allowed to update both the configuration and its expected fingerprint in the same unreviewed change.

## Signed manifest

The optional v1 signed manifest uses Ed25519. The signed message is the UTF-8 byte sequence:

`DPK-CONFIG-MANIFEST-V1\n` followed by the canonical configuration bytes.

The manifest carries the configuration fingerprint, key identifier, algorithm identifier (`Ed25519`), and detached signature. The verifier must:

1. validate the configuration schema and canonicalize it;
2. recompute and compare the fingerprint in the manifest;
3. resolve the key identifier only through an independently trusted key policy;
4. verify the Ed25519 signature over the domain-separated message;
5. reject unknown, revoked, expired (where policy defines expiry), or untrusted keys.

A signature embedded beside an untrusted public key is not sufficient authentication. Key rotation and revocation policy are deployment responsibilities and must be explicit. Private signing keys must never be committed to either repository or included in fixtures.

## Required shared vectors

The shared vectors cover canonical bytes and digest, reordered input keys, changed thresholds, negative and out-of-range weights, floating-point values, missing/unknown fields, and invalid weight sums. Invalid configurations must fail validation before a digest is emitted. Both SDKs must consume the same vectors.

## Compatibility and rollout

This contract does not modify the frozen Trace Specification v1 vectors or silently change existing alignment configuration APIs. Initial adoption is validation + canonical fingerprinting + pinned CI comparison. Signed manifests are an additive verification path. Promotion from experimental status requires matching Python/Swift results, negative tests, and explicit compatibility review.
