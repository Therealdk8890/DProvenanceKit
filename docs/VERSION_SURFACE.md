# Version surface

Single source of truth for public version claims. CI checks the candidate package
version against the library constant and active install guidance; the README separately
identifies the latest published release so an unpublished candidate is never presented
as shipped.

| Surface | Value | Source of truth |
|---------|-------|-----------------|
| Swift package release candidate | `0.10.0` (not yet tagged) | `Sources/DProvenanceKit/Version.swift` (`DProvenanceKitVersion.current`) |
| Latest published Swift release | `0.9.2` | [GitHub Releases](https://github.com/Therealdk8890/DProvenanceKit/releases/tag/0.9.2) |
| Python package release candidate | `0.10.0` (not yet on PyPI) | [Python version surface](https://github.com/Therealdk8890/DProvenanceKitPython/blob/release/0.10.0-preparation/docs/VERSION_SURFACE.md) |
| Latest published Python release | `0.9.2` | [PyPI](https://pypi.org/project/dprovenancekit/) |
| Trace Spec | v1 (frozen) | Python `conformance/TRACE_SPEC_v1.md` (oracle) + Swift `ConformanceHarness` |
| Attestation encoding | `DPK-BINARY-V1` | `docs/ATTESTATION.md` / Python `dprovenancekit.attestation` |

Swift and Python share a product release version, not feature parity or interchangeable
artifacts. The capability matrix in `README.md` is authoritative for language-specific
support. Python attestation is **MVP** via `dprovenancekit[crypto]` (software P-256);
proof packs remain Swift-only.

The 0.10.0 candidate supersedes the unpublished Python 0.9.3 preparation. Neither
SDK's 0.10.0 publication is complete. See [the release checklist](RELEASE_0.10.0.md).
