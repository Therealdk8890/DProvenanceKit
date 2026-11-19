# DProvenanceKit Event Chain v1 — candidate contract

**Status: review draft, NOT frozen.** This is a reconstruction of the six §10 decisions and the existing attestation canonicalizer. The complete original private draft was not available; reconcile it before approving normative fixtures or writing production code. The proposed entry separator, field framing, validation rules and resource limits below are new review decisions, not verified historical text.

## 1. Scope and compatibility

An opt-in per-run SHA-256 chain commits to the recorded event envelope and exact payload bytes. Preserve the frozen Trace Specification v1, its SQLite schema/fingerprints, and the existing DPK-BINARY-V1 attestation/signature preimages. Do not retrofit existing runs or silently label absent chains as verified. Existing applications remain unaffected. Chain v1 is separately versioned. Edges, capture losses and unrecorded activity are outside individual event entries; the optional authenticated closure binds a full trace digest (including supplied edges), not the truth or completeness of capture. A chain with no independently trusted commitment proves only internal consistency.

Primary references:
- https://github.com/Therealdk8890/DProvenanceKitPython/blob/2175ed91825c5b3fb39f89195f9db4e2608d177d/dprovenancekit/attestation.py#L87
- https://github.com/Therealdk8890/DProvenanceKitPython/blob/2175ed91825c5b3fb39f89195f9db4e2608d177d/dprovenancekit/attestation.py#L354
- https://github.com/Therealdk8890/DProvenanceKitPython/blob/main/conformance/TRACE_SPEC_v1.md
- https://github.com/Therealdk8890/DProvenanceKit/blob/main/docs/ATTESTATION.md

## 2. Binary primitives

`U64` and `I64`: exactly eight bytes, unsigned and two's-complement signed big-endian respectively. `UUID`: 16 RFC 4122 network-order bytes (not GUID little-endian). `S`: U64 byte length followed by strict UTF-8; no implicit Unicode normalization. `OS`: 00 for absent; 01 followed by S for present, including empty. `OU64`: 00 for absent; 01 followed by U64 for present. `H`: exactly 32 raw bytes. `D`: exact ASCII domain literal, with no NUL, newline, or length prefix. Domain lengths are fixed by the versioned contract. JSON transport uses lowercase 64-digit hex for H; untrusted input MUST be validated before decoding. Integers must be exact (no booleans or floating point coercion). Never hash hexadecimal text in place of H. Textual run/event UUIDs: at most 128 UTF-8 bytes, only standard 36-character hyphenated ASCII UUID spelling (case-insensitive input), normalized by parsing into 16 bytes. Distinct text spellings of the same UUID are the same identity. This stricter UUID input rule is proposed for chain v1 only.

## 3. Genesis

```
G = SHA256(D("DPROVENANCEKIT-EVENT-CHAIN-GENESIS-V1") || UUID(runID))
```

Empty initialized chain: head G, count 0. A missing chain is not an initialized chain. A run ID must never be silently replaced by an embedded event's run ID.

## 4. Entry preimage

Proposed literal `DPROVENANCEKIT-EVENT-CHAIN-ENTRY-V1`.

```
entryPreimage = D("DPROVENANCEKIT-EVENT-CHAIN-ENTRY-V1")
             || I64(1)
             || U64(chainIndex)
             || H(previousHash)
             || eventBytes
entryHash = SHA256(entryPreimage)
```

Exact eventBytes field order, reusing DPK-BINARY-V1's normalized event record except that chainIndex supplies the attestation array-index role (no duplicated index):

| Field | Encoding |
|---|---|
| eventID | UUID |
| runID | UUID |
| contextID | S |
| engineName | S |
| schemaVersion | I64 |
| eventSequence | U64 |
| spanID | OS |
| parentSpanID | OS |
| typeIdentifier | S |
| priority | I64 |
| payloadJSON | S |
| timestampUnixMicroseconds | I64 |

The first previousHash is G. Later previousHash is the immediately preceding entry's hash. The entryHash itself is not included in the preimage. All raw event adapters must explicitly map into the same normalized attestation event model; nullable raw engine names, schema version source, raw BLOBs that are not valid UTF-8 JSON, and UUID validation must not acquire divergent SDK-specific defaults. Use the exact frozen UTF-8 payloadJSON, not a re-encoded object. Existing Trace Spec v1 allows differing whitespace, so semantic JSON equality does not imply identical evidence. Reject payloads that cannot meet the attestable JSON contract. Propose strict JSON object parsing with duplicate keys and non-finite values rejected; retain the original bytes, never reserialize for verification. The raw-to-attestable normalization mapping and payload/depth/resource bounds must be agreed before production implementation.

## 5. Invariants and errors

- Chain index starts at zero and is contiguous. Sequence is nonnegative and strictly increasing; gaps are allowed and are not evidence of legitimate loss. Never sort input during verification or use timestamp for ordering.
- Every event must match the independently supplied expected run ID. Event IDs must be unique per run; compare parsed UUIDs. Preserve the normalized context invariant of the existing attestation within a run when closing against a full trace.
- Version must equal 1. Unknown versions fail closed. Validate malformed wire, integer ranges, hash size and textual bounds before hashing or mutating storage. Proposed one-fault codes are in the candidate fixture test plan; multi-fault precedence is not yet pinned.
- Verify each stored index, previousHash, unique event ID, increasing sequence, and recomputed entryHash in supplied order. Verify declared head/count against recomputed values. Invalid results must not expose the chain as authenticated or evidence sufficient. Empty valid chains report count zero; required evidence policy returns EMPTY_CHAIN. No auto-repair, silent omission, truncation, or sorting of suspect data.

## 6. Authenticated run closure (candidate)

```
closePreimage = D("DPROVENANCEKIT-RUN-CLOSE-V1")
             || UUID(runID) || I64(1) || OU64(finalChainIndex)
             || H(finalChainHead) || U64(eventCount)
             || H(traceDigest) || H(keyID) || I64(issuedAtUnixMicroseconds)
```

For zero events index is absent and head equals genesis. Otherwise finalChainIndex = eventCount - 1. The `traceDigest` is the existing DPK-BINARY-V1 full trace SHA-256 digest, not a different digest; recompute it over a supplied trace and verify that its normalized event array exactly matches the chain's events. The keyID is SHA-256 of the existing P-256 X9.63 public-key encoding. Use P256-SHA256 ECDSA DER, signing the exact preimage once (or using the prehashed API exactly once); no double hashing. Signature is outside preimage. Obtain independently provisioned trusted key ID and expected run ID; embedded key alone is insufficient. Validate key identity and signature, all closure fields, head and count against recomputed values, the full trace/event coverage, and policy-required evidence. Reject a missing closure when required. No trusted time claim; no anti-rollback guarantee against an older legitimately signed closure without independent expected checkpoint/freshness state. The supplied closure fixtures demonstrate bytes and SHA-256 only; they contain placeholder trace/key digests, no valid signature, and cannot pass full closure verification.

## 7. Persistence and loss (design gate; not implemented)

Use a separate opt-in schema/migration, preserving legacy trace schema and semantics. Define explicit initialized/open/closed lifecycle and capture-loss accounting before integration. Perform event write, chain append and compare-and-update of head/count atomically in one transaction; serialize writers per run, enforce uniqueness, reject append-after-close, and never advance head on invalid append. Crash/restart must recover committed state without rebuilding or blessing missing/tampered data. Persist the exact normalized payload/envelope used by the chain. Define whether only persisted (post-load-shed) events are chained, and how capture-loss counters are authenticated in a separate versioned record; do not silently extend the closure encoding above. Do not claim complete capture or enforcement. Test real concurrent writers, rollback, crash recovery, and truncation against an independently trusted head. Establish resource caps for payloads, all string lengths, event count and total artifact size, plus SQLite integer mapping (signed 64-bit limits), before storage work.

## 8. Candidate conformance materials

`event_chain_v1_candidate.json`: six positive candidate chains, two unsigned closure preimages, and thirteen negative test descriptions. `generate_candidate_vectors.py`: independent stdlib fixture generator, cross-checks every digest with OpenSSL. JSON is a human-readable fixture carrier only, not a canonical event serialization. Negative cases are a test plan, not executed SDK tests. Before freezing, convert each negative case to concrete malformed input/expected code and add malformed wire/UTF-8, zero versus absent, wrong trust root, signature substitution, trace mismatch, loss and crash cases. A second independent byte-layout calculation (Swift or another independent encoder) must reproduce preimages, not only SHA-256. Review and freeze both SDKs' common fixture bytes; neither production SDK may regenerate its own expected outputs.

## 9. Implementation sequence

1. Reconcile the original §10 draft, resolve all candidate decisions and resource/adapter ambiguity, freeze contract and normative fixtures.
2. Python standalone in-memory encoder/append/verifier with standard-library SHA-256; exact fixtures and negative tests.
3. Independent Swift encoder/append/verifier using CryptoKit SHA-256; exact fixtures and reciprocal verification.
4. Authenticated closure with independent trust and full trace binding, opt-in atomic persistence and capture-loss semantics; adversarial tests and legacy regression suite across SDKs.
5. Review DCO, CI and parity evidence before merging. Merkle/log anchoring is future work.

## 10. Decision record

Per-run genesis; reuse existing binary event primitives; strict increasing sequence; empty structurally valid chain; 128-byte textual run/event ID ceiling with 16-byte UUID binary encoding; candidate golden vectors before Python and Swift. Candidate reconstruction is not the missing original draft and not approval to change existing contracts.
