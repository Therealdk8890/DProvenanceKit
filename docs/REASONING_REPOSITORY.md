# Portable local reasoning-history objects

The repository object format is separate from Trace Specification v1,
Structural Alignment v1, DPK-BINARY-V1 attestations and proof packs. Existing
trace and signature bytes are unchanged.

The Python SDK owns local repository operations. Swift supplies standalone
object encoding, decoding, content addressing and read-only bundle verification.
Importing a bundle never executes recorded code, resolves a network URL, opens
recorded paths or changes a branch. An execution trace records instrumented
activity; it does not expose inaccessible model internals or establish that a
decision is true.

## Object API

```swift
let object = ReasoningRepositoryObject(
    type: .blob,
    payload: .map(ReasoningRepositoryMap([
        "data": .bytes(Data("prompt".utf8))
    ]))
)
let bytes = object.canonicalData()
let id = object.id
let restored = try ReasoningRepositoryObject.decodeCanonical(bytes)
```

`ReasoningRepositoryValue` supports null, booleans, signed 64-bit integers,
UTF-8 strings, bytes, arrays and maps. It has no floating-point case. Values
retain their exact UTF-8 spelling. Map keys are sorted by UTF-8 bytes, with no
Unicode normalization; `ReasoningRepositoryMap(fields:)` preserves distinct
canonically equivalent spellings that Swift's native Dictionary would collapse.
No JSON re-encoding participates in object identity.
Use `checkedCanonicalData(limits:)` to bound caller-constructed values before
encoding when their contents come from an untrusted source.

The canonical envelope contains length-prefixed `DPK-OBJECT-V1`, a
length-prefixed object type, an unsigned big-endian 64-bit version (`1`), and
the tagged payload. Tags are null `0`, false `1`, true `2`, integer `3`, string
`4`, bytes `5`, array `6`, map `7`. Lengths/counts use unsigned big-endian
64-bit integers; signed integers use two's-complement 64-bit big endian.
Map keys use length-prefixed strings without an extra value tag. Object IDs
are lowercase SHA-256 hex over the entire envelope.

The allowed types are `blob`, `workflow`, `run`, `commit`, `evaluation` and
`signature`. A codec round trip establishes canonical bytes; bundle verification
also checks the object schemas and reference graph. Content identity is distinct
from semantic equivalence and from a trace's historical structural fingerprint.

## Bundles

```swift
let bundle = try ReasoningRepositoryBundle.verify(bundleBytes)
for root in bundle.roots {
    let object = bundle.objects[root]
    // Display the recorded object. Do not execute its contents.
}
```

A v1 bundle is a stored (uncompressed) ZIP containing `manifest.json` and
`objects/<object-id>.bin`. The manifest declares format
`DPK-REPOSITORY-BUNDLE-V1`, version `1`, sorted unique root/object IDs and
full ref names mapped to object IDs. The manifest uses sorted UTF-8 JSON keys,
unescaped Unicode, and no whitespace. The Swift reader validates the inventory,
object hashes and schemas before returning data. It rejects unsafe names,
duplicate entries, duplicate JSON keys, overlapping entries, truncated values,
CRC mismatches, ZIP64, encryption, compression, descriptors, extras and comments.
It writes no extracted files.

Verification checks typed reference closure, commit/run workflow binding,
recomputed graph-health assertions, capture metadata and evaluation policy
digests. It verifies attached P-256 signatures over the domain-separated commit
digest. `signatureVerifications(trustedKeyIDs:)` reports which verified keys are
also pinned by the caller; a key carried inside an artifact alone is not an
identity trust anchor. Evaluation reports remain recorded assertions, not an
independent rerun of their policy.

Default limits are 64 MiB per object, 256 MiB per bundle, 10,000 objects,
64 nesting levels and 1,000,000 decoded value/container items. Callers may lower
these through `ReasoningRepositoryLimits`. These limits are part of admission;
callers constructing in-memory objects should keep their values within the same
limits before encoding.

## Partial typed traces

`TraceAlignmentResult.inputCompleteness` and `isReliable` distinguish a complete
typed comparison from one with undecodable persisted events. Incomplete inputs
retain diagnostic alignments but receive a conservative high risk with an
explicit indeterminate explanation, so consumers of the historical risk field
fail closed. Complete-input matching and profile hashes are unchanged.
