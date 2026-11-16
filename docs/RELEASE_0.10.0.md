# DProvenanceKit 0.10.0 release record

Status: **published for Swift and Python**. Latest published versions: **0.10.0**.
Swift tag: `0.10.0`. Python tag: `v0.10.0`. The unpublished Python 0.9.3 preparation is
superseded by 0.10.0. The version constant and numbered changelog identify this build;
the verified publication evidence is recorded below.

## Verified publication

| Distribution | Immutable source / evidence |
|---|---|
| [Swift 0.10.0](https://github.com/Therealdk8890/DProvenanceKit/releases/tag/0.10.0) | `f3b0ff225e15bf3ca075b1fd6f0023dd4834af4c` |
| [Python v0.10.0](https://github.com/Therealdk8890/DProvenanceKitPython/releases/tag/v0.10.0) | `26ca41f9657a8b123673f2de463f3a669a8b8f96` |
| [PyPI 0.10.0](https://pypi.org/project/dprovenancekit/0.10.0/) | [Trusted Publishing run 43797953686](https://github.com/Therealdk8890/DProvenanceKitPython/actions/runs/43797953686) passed tests, build/version checks, provenance attestation and upload |

Both tags resolve to the validated merge commits. Swift's exact source tree passed
macOS/iOS builds, tests, conformance and concurrency checks in GitHub CI. A fresh
consumer build from the published Swift tag was not run in this Linux workspace.
A fresh PyPI install verified version 0.10.0, viewer modules/resources, no core runtime
dependencies and both offline demos, including the bundle round trip. Optional heavy
framework integrations remain skipped as recorded in the release notes. This record
updates main without moving published tags or changing immutable PyPI artifacts.

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

- [x] Record both final candidate SHAs, review the diff and resolve CI/DCO failures.
- [x] Swift full CI, release guards, conformance and vector parity pass at the final SHA.
- [x] Python independently passes its [release checklist](https://github.com/Therealdk8890/DProvenanceKitPython/blob/main/docs/RELEASE_0.10.0.md), including wheel/sdist validation and documented integration skips.
- [x] Merge both preparation PRs, then verify the final main commits and their checks.
- [x] Confirm Swift `0.10.0` and Python `v0.10.0` do not already exist; never reuse or move tags.
- [x] Publish Swift `0.10.0` and GitHub Release from the validated commit.
- [ ] Verify a fresh Swift consumer resolves the tag and its supported library targets build.
- [x] Publish Python through GitHub Release/Trusted Publishing and confirm the exact 0.10.0 PyPI artifacts, provenance and clean-install smoke tests.
- [x] Update latest-published status, candidate install guidance and changelog dates only after each SDK's publication is confirmed.
- [x] Announce a coordinated release only after both distribution paths succeed.

The checklist above is retained as the release procedure; verified publication evidence
is recorded at the top of this page. For future releases, report each SDK's status
separately if a path fails. Matching versions do not imply feature parity.
