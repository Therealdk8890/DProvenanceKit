# Version surface

Single source of truth for public version claims. CI checks the candidate package
version against the library constant and active install guidance; the README separately
identifies the latest published release so an unpublished candidate is never presented
as shipped.

| Surface | Value | Source of truth |
|---------|-------|-----------------|
| Swift package release candidate | `0.9.2` | `Sources/DProvenanceKit/Version.swift` (`DProvenanceKitVersion.current`) |
| Latest published Swift release | `0.9.0` | [GitHub Releases](https://github.com/Therealdk8890/DProvenanceKit/releases) |
| Python package release candidate | `0.9.2` | [DProvenanceKitPython PR #93](https://github.com/Therealdk8890/DProvenanceKitPython/pull/93) |
| Latest published Python release | `0.7.1` | [PyPI](https://pypi.org/project/dprovenancekit/) |
| Trace Spec | v1 (frozen) | Python `conformance/TRACE_SPEC_v1.md` (oracle) + Swift `ConformanceHarness` |
| Attestation encoding | `DPK-BINARY-V1` | `docs/ATTESTATION.md` / Python `dprovenancekit.attestation` |

Swift and Python share a product release version, not feature parity or interchangeable
artifacts. The capability matrix in `README.md` is authoritative for language-specific
support. Python attestation is **MVP** via `dprovenancekit[crypto]` (software P-256);
proof packs remain Swift-only.
