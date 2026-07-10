# Trace Attestation

DProvenanceKit can turn a completed reasoning trace into a signed, self-contained artifact that
can be verified offline. No hosted service, network request, or third-party package is required.

An attestation covers the trace's run and event identifiers, context, engine names, schema and
sequence values, span relationships, payloads, priorities, timestamps, and any lineage edges
supplied when the document is created. Modifying, deleting, or reordering covered data makes
verification fail.

## Sign a trace

```swift
import DProvenanceKit

let signingKey = SoftwareTraceAttestationKey()

// Persist signingKey.rawRepresentation in Keychain. Never write it into the trace artifact.
let document = try TraceAttestationDocument.signed(
    run: completedRun,
    edges: lineageEdges,
    using: signingKey
)

try document.jsonData().write(
    to: URL(fileURLWithPath: "decision.attestation.json"),
    options: .atomic
)
```

The JSON document contains the normalized trace, its SHA-256 digest, the public verification key,
and a P-256 signature. It never contains the private key.

### Secure Enclave-backed keys

On supported Apple hardware, use a non-exportable Secure Enclave key:

```swift
guard SecureEnclaveTraceAttestationKey.isAvailable else {
    // Fall back to a Keychain-protected SoftwareTraceAttestationKey if appropriate.
    return
}

let key = try SecureEnclaveTraceAttestationKey()
let document = try TraceAttestationDocument.signed(run: completedRun, using: key)
```

Persist `key.dataRepresentation` in Keychain to reopen the same Secure Enclave key later. That
value is a protected key reference, not the private scalar, but it should still be treated as
sensitive application state.

## Verify offline

The package exposes the CLI under the short `dpk` product name:

```sh
swift run dpk verify --in=decision.attestation.json
```

A valid signature made by the public key embedded in the document proves integrity, but not the
signer's identity. For an audit or regulated workflow, pin the expected key ID through a trusted
configuration channel:

```sh
swift run dpk verify \
  --in=decision.attestation.json \
  --trusted-key=<trusted-key-id>
```

The same distinction is explicit in the API:

```swift
let decoded = try TraceAttestationDocument.decodeJSON(data)

let integrityOnly = decoded.verify()
// integrityOnly.trust == .embeddedKeyOnly

let identifiedSigner = decoded.verify(trustedKeyIDs: [expectedKeyID])
// identifiedSigner.trust == .trustedKey when valid
```

`swift run dpk attest-demo --out=demo.attestation.json` creates a disposable signed corpus trace
for trying the verifier. A committed [version 1 test vector](test-vectors/attestation-v1.json) is
also checked by the test suite.

## Canonicalization and signature format

Version 1 uses these identifiers:

- Attestation schema: `1`
- Canonicalization: `DPK-BINARY-V1`
- Signature algorithm: `P256-SHA256`

`DPK-BINARY-V1` is a domain-separated, length-prefixed binary encoding. Integers are big-endian;
UUIDs use their 16-byte representation; optional strings carry an explicit presence byte. Event
array order is preserved and its zero-based position is encoded, so reordering otherwise identical
events changes the digest. Lineage edges are sorted by source ID, target ID, and edge type because
their input array order has no semantic meaning.

Payloads are encoded with Swift `JSONEncoder` using sorted keys, unescaped slashes, millisecond
date encoding, Base64 data encoding, and rejection of non-finite floating-point values. Event
timestamps are represented as integer microseconds since the Unix epoch, matching the SQLite
store's persistence precision.

The trace digest is SHA-256 over the canonical trace bytes. The P-256 signature covers a separate,
domain-separated envelope containing the version, algorithms, run identity, counts, trace digest,
issuance time, key ID, and embedded public key. Changing envelope metadata therefore also breaks
the signature.

The key ID is the lowercase SHA-256 digest of the P-256 X9.63 public-key representation. Signatures
use ASN.1 DER representation.

## Threat model

### What a valid, trusted attestation establishes

- The covered trace document has not changed since the holder of the pinned signing key signed it.
- Covered event deletion, insertion, reordering, field modification, payload modification, and
  supplied-edge modification are detected.
- Verification can run entirely on the device or inside an offline build/audit environment.
- A Secure Enclave-backed key is non-exportable and raises the cost of key extraction.

### What it does not establish

- **Truthfulness.** A signature proves what the signer recorded, not that the model really performed
  an uninstrumented internal thought process or that every recorded claim is true.
- **Capture completeness.** Events dropped before the document is built cannot be recovered by a
  signature. Check the store's `dropStats.preservedIntegrity` and operational capture policy before
  signing; version 1 does not embed drop statistics.
- **Signer identity without key pinning.** Anyone can replace a trace, create a new key, and sign the
  replacement. Embedded-key verification detects accidental or post-signing alteration; a trusted
  key ID is required to identify the signer.
- **Trusted time.** `issuedAtUnixMicroseconds` is signed but comes from the signing process's clock.
  It is not an RFC 3161 timestamp or evidence from an external time authority.
- **Application or device attestation.** A Secure Enclave key protects key material; this format is
  not Apple App Attest, DeviceCheck, code-signing validation, or proof of the executing binary.
- **Protection after endpoint compromise.** Malware controlling the authorized process may ask the
  key to sign false data. Key access controls, application hardening, and independent review remain
  necessary.
- **Automatic compliance.** The artifact can support audit, governance, and regulated workflows,
  but it is not by itself certification under any legal or industry framework.

## Privacy boundary

Attestation creation and verification make no network requests. The trace stays where the caller
writes it. However, the resulting JSON document contains the covered payload JSON in plaintext.
Apply the Foundation Models redaction policy or application-specific redaction before creating an
artifact that will leave the device.

OTel and `CloudTraceStore` export remain explicit, optional paths. The accurate guarantee is:
**nothing leaves the device unless the application configures and invokes an export path.**

## Key lifecycle

- Generate one signing identity per application, device, deployment, or policy boundary rather
  than one global key for every customer.
- Store software-key raw representations in Keychain with an access class appropriate to the app.
- Store Secure Enclave key references in Keychain and test restoration before relying on them.
- Distribute trusted key IDs separately from the signed documents they validate.
- Rotate keys deliberately and retain an auditable mapping of key ID to owner and validity period.
- Treat a lost signing key as an identity loss; existing documents remain verifiable, but new ones
  must use a newly trusted key.
