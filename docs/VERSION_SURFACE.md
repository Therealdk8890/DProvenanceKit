# Version surface

Single source of truth for public version claims. The CI script
`scripts/check_version_surface.sh` fails if README install pins disagree with
`Sources/DProvenanceKit/Version.swift`.

| Surface | Value | Source of truth |
|---------|-------|-----------------|
| Swift package | `0.9.0` | `Sources/DProvenanceKit/Version.swift` (`DProvenanceKitVersion.current`) |
| Python package | `0.7.0+` (attestation MVP) | [DProvenanceKitPython](https://github.com/Therealdk8890/DProvenanceKitPython) `pyproject.toml` |
| Trace Spec | v1 (frozen) | Python `conformance/TRACE_SPEC_v1.md` (oracle) + Swift `ConformanceHarness` |
| Attestation encoding | `DPK-BINARY-V1` | `docs/ATTESTATION.md` / Python `dprovenancekit.attestation` |

Capability matrix in `README.md` must match these rows. Python attestation is **MVP** via
`dprovenancekit[crypto]` (software P-256) from Python **0.7.0**; proof packs remain Swift-only.
