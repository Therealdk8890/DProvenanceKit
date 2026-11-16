# Version surface

Single source of truth for public version claims. CI checks the candidate package
version against the library constant and active install guidance; the README separately
identifies the latest published release so an unpublished candidate is never presented
as shipped.

| Surface | Value | Source of truth |
|---------|-------|-----------------|
| Swift package | `0.10.0` | `Sources/DProvenanceKit/Version.swift` (`DProvenanceKitVersion.current`) |
| Latest published Swift release | `0.10.0` | [GitHub Release](https://github.com/Therealdk8890/DProvenanceKit/releases/tag/0.10.0) |
| Python package | `0.10.0` | [Python release tag](https://github.com/Therealdk8890/DProvenanceKitPython/tree/v0.10.0) |
| Latest published Python release | `0.10.0` | [PyPI](https://pypi.org/project/dprovenancekit/0.10.0/) |
| Trace Spec | v1 (frozen) | Python `conformance/TRACE_SPEC_v1.md` (oracle) + Swift `ConformanceHarness` |
| Attestation encoding | `DPK-BINARY-V1` | `docs/ATTESTATION.md` / Python `dprovenancekit.attestation` |

Swift and Python share a product release version, not feature parity or interchangeable
artifacts. The capability matrix in `README.md` is authoritative for language-specific
support. Python attestation is **MVP** via `dprovenancekit[crypto]` (software P-256);
proof packs remain Swift-only.

The published 0.10.0 release supersedes the unpublished Python 0.9.3 preparation.
Both publication paths are verified; see [the publication record](RELEASE_0.10.0.md).
