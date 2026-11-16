# DProvenanceKit 0.10.0 release preparation

Status: **unpublished candidate**. Latest published Swift and Python versions: **0.9.2**.
Swift tag: `0.10.0`. Python tag: `v0.10.0`. The unpublished Python 0.9.3 preparation is
superseded by 0.10.0. The version constant and numbered changelog identify this build;
they do not establish that a release tag exists.

## Release scope

- Experimental Structural Alignment v1: deterministic integer basis-point scoring and
  separate F1, hierarchy and order gates, covered by shared production-engine fixtures.
- Experimental deterministic configuration fingerprints and Ed25519 manifests checked
  against caller-supplied trusted-key policy using CryptoKit.
- Canonical reasoning-history objects and bounded, read-only portable bundle/signature
  verification. Python owns local history operations, storage, CLI and web workbenches.
- Provenance-metadata validation, conservative incomplete-input comparisons, shared
  malformed-attestation fixtures and stricter RFC 3161 certificate-profile validation.

Existing complete-input matching, frozen Trace Specification v1, profile hashes,
DPK-BINARY-V1 and proof-pack formats are unchanged. Experimental APIs remain opt-in;
this package release does not promote their independent contracts to stable.
Stricter timestamping-only EKU and certificate-validity checks can reject tokens accepted
by 0.9.2. CMS authentication remains macOS-only with explicit pinned-TSA trust; iOS
structural checks do not authenticate the signer. General PKI-chain validation is
not delivered. Recorded integrity and signatures do not establish truth, complete
observation or authority to execute.

## Validation

Run the release-surface guard and its existing negative self-test:

```bash
sh .github/scripts/check-release-surfaces.sh --self-test
sh .github/scripts/check-release-surfaces.sh
```

Check every `ConformanceHarness/vectors/*.json` file byte-for-byte against the matching
Python `conformance/vectors/` file. Compare
`docs/test-vectors/attestation-malformed-v1.json` with Python's
`tests/fixtures/attestation-malformed-v1.json`. Record both source SHAs.

On macOS 26/Xcode 26.5, run the configured CI, including:

```bash
swift build
swift test --enable-code-coverage
swift run DProvenanceKitCLI evaluate --gate
swift run --package-path ConformanceHarness
swift run Quickstart
xcodebuild -scheme DProvenanceKit-Package -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -scheme DProvenanceKit-Package -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

The full CI also exercises CLI fail-closed handling, Foundation Models demos/builds,
WebVisualizer exports/build/smoke tests, secret scanning and the OSS boundary guard.
Require the Swift 6.1 library-target floor and concurrency tests under ThreadSanitizer.
A Linux documentation/vector check is not a substitute for executing these Apple builds.

## Publication gates

- [ ] Record both final candidate SHAs, review the diff and resolve CI/DCO failures.
- [ ] Swift full CI, release guards, conformance and vector parity pass at the final SHA.
- [ ] Python independently passes its [release checklist](https://github.com/Therealdk8890/DProvenanceKitPython/blob/release/0.10.0-preparation/docs/RELEASE_0.10.0.md), including wheel/sdist validation and documented integration skips.
- [ ] Merge both preparation PRs, then verify the final main commits and their checks.
- [ ] Confirm Swift `0.10.0` and Python `v0.10.0` do not already exist; never reuse or move tags.
- [ ] Publish Swift `0.10.0` and GitHub Release from the validated commit.
- [ ] Verify a fresh Swift consumer resolves the tag and its supported library targets build.
- [ ] Publish Python through GitHub Release/Trusted Publishing and confirm the exact 0.10.0 PyPI artifacts, provenance and clean-install smoke tests.
- [ ] Update latest-published status, candidate install guidance and changelog dates only after each SDK's publication is confirmed.
- [ ] Announce a coordinated release only after both distribution paths succeed.

Release preparation leaves these publication gates open. If a path fails, report each
SDK's status separately. Matching versions do not imply feature parity.
