# DProvenanceKit 0.11.0 release record

Status: **prepared, not published**. Latest published versions remain **0.10.0** for
both SDKs. Swift tag `0.11.0` and Python tag `v0.11.0` do not exist yet. The version
constant and numbered changelog identify this candidate; publication evidence will be
recorded here only after each distribution path is verified.

| Distribution | Status |
|---|---|
| Swift 0.11.0 | Prepared in this repository; not tagged, no GitHub Release |
| Python 0.11.0 | Prepared on DProvenanceKitPython `main` ([`1b573bf`](https://github.com/Therealdk8890/DProvenanceKitPython/commit/1b573bf684876cdf1416226d654d55d9dda91b1d)); not on PyPI |

## Release scope

The full list is in [CHANGELOG.md](../CHANGELOG.md#0110---unreleased). In summary,
since 0.10.0:

- **Xcode 27 / OS 27 SDK fix.** DProvenanceFoundationModels no longer matches
  `Transcript.Segment.custom`, a beta-only case Apple removed before release, so Xcode 27
  consumers build again. CI now compiles the Foundation Models targets on Xcode 27.
- **`DPKGateVerdict` OTel attributes** (DProvenanceOTel): gate verdicts as `dpk.gate.*`
  attributes plus the `gen_ai.evaluation.result` event, pinned by the shared
  `otel_verdict_attributes.json` conformance vector.
- **OTLP `arrayValue`** support via `OTLPAnyValue.array` and
  `OTLPKeyValue.stringArray(_:_:)`.
- **Proof-pack role-binding security fixes.** A v1 pack whose signed trace records the
  artifact digest beside a different role now fails with
  `ProofPackVerificationFailure.artifactRoleMismatch(index:)`; role and digest matching
  is byte-exact UTF-8, matching the Python verifier.
- **Cleartext-credential refusal (default change).** Cloud and OTLP exporters refuse to
  send credentials over plain `http` to non-loopback hosts.
- **Data-integrity and CLI fixes**, including corrupt edge rows surfacing as
  `TraceError.corruptEdgeRow`, refusing newer SQLite schema versions, bounded pending
  lineage edges, `RawTraceStore` UTF-8 handling, terminal-control escaping in
  `dpk verify` output and `dpk verify --out` without `--certificate` exiting 2.

## Source and behavior changes

- **Default change:** `CloudTraceStore`, `CloudWriter` and `OTLPHTTPExporter` refuse to
  send credentials over plain `http` to a non-loopback host
  (`CloudTraceStoreError.insecureEndpoint`, `OTelExportError.insecureEndpoint`). `https`
  and loopback are unaffected. Opt out per instance with `allowInsecureTransport: true`.
- **New enum case `artifactRoleMismatch`:** exhaustive `switch` statements over
  `ProofPackVerificationFailure` without a `default` must handle it. Genuine v1 packs
  whose traces record no role still verify as value-presence-only;
  `requireRoleBinding` still defaults to `false`.
- Other new enum cases (`OTLPAnyValue.array`, `CloudTraceStoreError.insecureEndpoint`,
  `OTelExportError.insecureEndpoint`, `TraceError.corruptEdgeRow`,
  `SQLiteError.unsupportedSchemaVersion`) affect exhaustive `switch` statements in the
  same way. New parameters and properties are defaulted.
- Behavior changes in `SQLiteTraceStore` (corrupt edge rows throw; newer schema versions
  are refused) and `dpk verify --out` are listed in the changelog.

Frozen Trace Specification v1, profile hashes, DPK-BINARY-V1 and proof-pack formats are
unchanged. Recorded integrity and signatures do not establish truth, complete
observation or authority to execute.

## Validation

Run the release-surface guard and its negative self-test:

```bash
sh .github/scripts/check-release-surfaces.sh --self-test
sh .github/scripts/check-release-surfaces.sh
```

Confirm the vector-sync check passes against DProvenanceKitPython `main`, and run the
configured CI on macOS (Xcode 26.x) plus the Xcode 27 Foundation Models job, including:

```bash
swift build
swift test --enable-code-coverage
swift run DProvenanceKitCLI evaluate --gate
swift run --package-path ConformanceHarness
xcodebuild -scheme DProvenanceKit-Package -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -scheme DProvenanceKit-Package -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

A Linux documentation check is not a substitute for executing these Apple builds.

## Publication gates

- [ ] Swift full CI, release guards, conformance and vector parity pass on the prep PR.
- [ ] Merge the prep PR and record the merged commit SHA.
- [ ] Python 0.11.0 is published (tag `v0.11.0`, GitHub Release, Trusted Publishing to PyPI) and the exact PyPI artifacts are confirmed.
- [ ] Confirm Swift `0.11.0` and Python `v0.11.0` tags do not already exist; never reuse or move tags.
- [ ] Tag Swift `0.11.0` on the merged prep commit.
- [ ] Publish the Swift `0.11.0` GitHub Release from that tag.
- [ ] Verify a fresh Swift consumer resolves the tag and its supported library targets build.
- [ ] Flip the docs to published: README / TECHNICAL_OVERVIEW latest-published status, the version surface, the release policy, this record and the changelog date.
- [ ] Announce a coordinated release only after both distribution paths succeed.

Report each SDK's status separately if a path fails. Matching versions do not imply
feature parity.
