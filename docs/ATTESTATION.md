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

// Persist signingKey.rawRepresentation in Keychain — see "Persisting keys in the
// Keychain" below. Never write it into the trace artifact.
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

## Persisting keys in the Keychain

Key custody belongs to the application, not this library: Keychain behavior depends on your
code-signing identity, entitlements, and sandbox, none of which a SwiftPM package can carry for
you (unsigned test binaries, for example, cannot use the data-protection keychain at all — they
fail with `errSecMissingEntitlement`). What the library guarantees is exact round-tripping:
`SoftwareTraceAttestationKey(rawRepresentation:)` and
`SecureEnclaveTraceAttestationKey(dataRepresentation:)` reconstruct the same signing identity —
same key ID — from the bytes you persisted.

The complete recipe below is intended to be pasted into your app target and adapted:

```swift
import DProvenanceKit
import Foundation
import Security

enum AttestationKeyStore {
    /// One Keychain item per signing identity. Pick a service string unique to your app.
    private static let service = "com.yourapp.attestation-keys"

    struct KeyStoreError: Error { let status: OSStatus }

    /// Stores (or replaces) a software key's private scalar.
    static func save(_ key: SoftwareTraceAttestationKey, label: String) throws {
        try save(data: key.rawRepresentation, label: label)
    }

    /// Stores (or replaces) a Secure Enclave key *reference*. The private scalar never
    /// leaves the enclave; this blob only lets you reopen the same key later.
    static func save(_ key: SecureEnclaveTraceAttestationKey, label: String) throws {
        try save(data: key.dataRepresentation, label: label)
    }

    static func loadSoftwareKey(label: String) throws -> SoftwareTraceAttestationKey? {
        try load(label: label).map { try SoftwareTraceAttestationKey(rawRepresentation: $0) }
    }

    static func loadSecureEnclaveKey(label: String) throws -> SecureEnclaveTraceAttestationKey? {
        try load(label: label).map { try SecureEnclaveTraceAttestationKey(dataRepresentation: $0) }
    }

    private static func save(data: Data, label: String) throws {
        var attributes = baseQuery(label: label)
        attributes[kSecValueData as String] = data
        // Signing keys must survive a locked screen for background signing, but never
        // leave this device: a restored or migrated identity would silently sign under
        // the same key ID from different hardware.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(baseQuery(label: label) as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else { throw KeyStoreError(status: updateStatus) }
        } else if status != errSecSuccess {
            throw KeyStoreError(status: status)
        }
    }

    private static func load(label: String) throws -> Data? {
        var query = baseQuery(label: label)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeyStoreError(status: status) }
        return item as? Data
    }

    private static func baseQuery(label: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: label,
            // Never sync signing identities through iCloud Keychain — each device is its
            // own signer, identified by its own key ID. Kept explicit in the query so a
            // synced item with the same label can never shadow the local identity.
            kSecAttrSynchronizable as String: false,
        ]
    }
}
```

Adaptation notes:

- **macOS apps** must add `kSecUseDataProtectionKeychain as String: true` to `baseQuery` for
  this recipe's protections to hold. Without it, items land in the legacy file-based keychain,
  which silently ignores `kSecAttrAccessible` — the save succeeds, but the ThisDeviceOnly
  guarantee promised above is not enforced (a migrated or restored home directory carries the
  identity to new hardware). The data-protection keychain requires a signed app with an
  application identifier — which is why the recipe lives in your app target and not in the
  package.
- **Sandboxed apps sharing an identity across an app group** need `kSecAttrAccessGroup`.
- **Biometry-gated signing** (require Touch ID/Face ID per signature) means creating the item
  with a `SecAccessControl` instead of a plain accessibility class; start from this recipe only
  if you do not need that.

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

## Retention: attest, then rotate

DProvenanceKit deliberately ships no destructive retention API — a provenance store that deletes
its own history is a liability in the audit workflows this library targets. The supported way to
keep on-disk growth bounded is non-destructive rotation:

1. **Attest** what you are about to age out. For each run worth preserving as evidence, write a
   signed document — it is a self-contained, offline-verifiable archive of the run and its
   lineage edges:

   ```swift
   let document = try TraceAttestationDocument.signed(run: run, edges: edges, using: key)
   try document.jsonData().write(to: archiveURL, options: .atomic)
   ```

2. **Close** the store. `await store.close()` flushes every pending event and edge, stops the
   background writer, folds the WAL back into the `.sqlite` file, and leaves the file in
   rollback-journal mode — complete, quiescent, and readable as a single file by any read-only
   client. It returns whether that single-file guarantee holds: `false` means a concurrent
   reader pinned the WAL and the `-wal`/`-shm` companions must be archived alongside the file.

3. **Rotate**: move the closed file to your archive location and start the next
   `SQLiteTraceStore` at a fresh path.

   ```swift
   let complete = await store.close()
   try FileManager.default.moveItem(at: activeURL, to: archivedURL)
   if !complete {
       // A concurrent reader kept the WAL pinned: the companions carry the
       // unfolded frames, so they must travel with the archive.
       for suffix in ["-wal", "-shm"] {
           let companion = activeURL.path + suffix
           if FileManager.default.fileExists(atPath: companion) {
               try FileManager.default.moveItem(
                   at: URL(fileURLWithPath: companion),
                   to: URL(fileURLWithPath: archivedURL.path + suffix)
               )
           }
       }
   }
   store = try SQLiteTraceStore<MyEvent>(fileURL: activeURL)
   ```

Archived store files stay fully queryable — reopen them with `RawTraceStore` (or any store
consumer) at any time. Nothing is exported lossily and nothing is deleted; retention policy
(how long archived files live, and where) stays where it belongs, in the application.

## Key lifecycle

- Generate one signing identity per application, device, deployment, or policy boundary rather
  than one global key for every customer.
- Store software-key raw representations in Keychain with an access class appropriate to the app
  (see [Persisting keys in the Keychain](#persisting-keys-in-the-keychain)).
- Store Secure Enclave key references in Keychain and test restoration before relying on them.
- Distribute trusted key IDs separately from the signed documents they validate.
- Rotate keys deliberately and retain an auditable mapping of key ID to owner and validity period.
- Treat a lost signing key as an identity loss; existing documents remain verifiable, but new ones
  must use a newly trusted key.
