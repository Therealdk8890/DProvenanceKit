# Cross-language release policy

DProvenanceKit Swift and DProvenanceKitPython are language-specific SDKs for one product. Starting with the coordinated **0.9.2** release, both SDKs use the same product release version.

## What a shared version means

- The version identifies the coordinated DProvenanceKit product release.
- Each SDK retains its own package artifact, API surface, dependency requirements, platform support, and release validation.
- A shared version **does not** promise feature parity, source compatibility across languages, or that a capability available in one SDK exists in the other.
- The capability matrix in the Swift README and the Python README is authoritative for language-specific support.

## Release coordination

1. Prepare the Swift and Python release candidates against the same product version.
2. Require each repository's full CI and release-specific checks to pass independently.
3. Merge the release preparation only when both candidates are ready.
4. Publish the Swift Git tag and GitHub Release, and publish the Python vX.Y.Z tag and PyPI distribution using their respective repository workflows.
5. Announce a coordinated release only after both publication paths are confirmed.

If one language's validation or publication fails, report the other SDK's status accurately and do not describe the product release as complete. Never reuse or rewrite an existing release tag or published package version.

## 0.9.2 status

The Swift 0.9.2 release is being prepared to align with the Python 0.9.2 corrective release candidate. This document and the version surfaces do not mean either release has been published. The Swift tag and PyPI publication remain pending their respective CI and release gates.
