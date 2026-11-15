# Product layers — OSS evidence engine vs commercial AI Assurance Platform

This repository is the **Apache-2.0 evidence engine** (Swift SDK). Commercial
platform capabilities live in **separate repositories under a proprietary
license**. They depend on these Apache SDKs; they do **not** relicense them.

> Positioning: DProvenanceKit is an **assurance / evidence layer under**
> Langfuse, OpenTelemetry, LangSmith, and similar tools — not a replacement
> dashboard.

## NobodySystems: adjacent enterprise operations (private alpha)

**NobodySystems** is the separately licensed operational/control-plane product that coordinates the independent **DProvenanceKit (evidence)**, **WarrantKit (authority)**, and **AgentContainment (enforcement)** engines. Its current private alpha provides a local controller, bounded guarded operations, and independent evidence-bundle verification. Planned organizational policy lifecycle and distribution, cross-run evidence correlation and operator workflows, fleet management, enterprise identity and tenancy, support commitments, and hosted editions are **not production features delivered by this alpha**.

This is distinct from the DProvenanceKit-specific `DProvenanceKit-Premium` and `dprovenancekit-server` proposals referenced below. The commercial rows in this document describe product ownership and target capabilities **not a current general-availability or SLA promise**. The current publicly defined paid DProvenanceKit offer remains the scoped services engagement in [COMMERCIAL.md](../COMMERCIAL.md). None of these layers is required for the OSS SDK's tracing, CI gates, signing, or offline verification.

See [NobodySystems integration and evaluation boundaries](NOBODYSYSTEMS.md) for an independently runnable proof, maturity table, and private-alpha inquiry route.

## Free / commercial matrix

| Capability | Layer | License | Where |
|------------|-------|---------|--------|
| Record instrumented decision paths | OSS | Apache-2.0 | This repo / Python twin |
| Local SQLite store (offline-first) | OSS | Apache-2.0 | This repo / Python twin |
| Query / structural diff / align | OSS | Apache-2.0 | This repo / Python twin |
| CI regression gate | OSS | Apache-2.0 | CLI + `dprovenancekit-action` |
| CryptoKit / Secure Enclave attestation + proof packs | OSS | Apache-2.0 | This repo |
| Software attestation (`DPK-BINARY-V1`) | OSS | Apache-2.0 | Python `dprovenancekit[crypto]` |
| OTel / OTLP export | OSS | Apache-2.0 | `DProvenanceOTel` |
| Trace Spec + conformance | OSS | Apache-2.0 | Conformance harness / vectors |
| Cloud federation / multi-tenant sync | Commercial | Proprietary | `dprovenancekit-server`, `DProvenanceKit-Premium` |
| Team workspace | Commercial | Proprietary | Platform repos |
| Evidence retention / lifecycle | Commercial | Proprietary | Platform repos |
| Policy management (org/project) | Commercial | Proprietary | Platform repos |
| Advanced semantic evaluation (hosted) | Commercial | Proprietary | Platform repos |
| Audit workflows (chained, multi-user) | Commercial | Proprietary | Platform repos |
| RBAC / enterprise SSO | Commercial | Proprietary | Platform repos |
| Enterprise deploy, SLA, support | Commercial | Proprietary | Services + Platform |
| Governed AI Deployment Pilot ($4,500) | Services | SOW | [COMMERCIAL.md](../COMMERCIAL.md) |

## Apache-2.0 vs proprietary boundary

- **Everything in this public repository** is Apache-2.0 (`LICENSE`, `NOTICE`).
- **Premium / Platform / Cloud control-plane code** must not be merged here
  (see [CONTRIBUTING.md](../CONTRIBUTING.md) — public/private boundary).
- The commercial license covers only proprietary components and services.
  It does not relicense Apache SDK code.

## Trust model (local-first)

1. **Local-first** — record and gate on-device.
2. **Optionally synced** — push selected evidence when *you* choose.
3. **Cryptographically verifiable** — attest with CryptoKit / SE when needed.

### What will never be required to leave the device

The OSS SDK never requires uploading traces, payloads, or keys to a
DProvenance-operated service in order to record, baseline, diff, gate, export
OTel, or attest/verify locally. Hosted sync is optional and lives outside this
repository.

## Related commercial repositories

| Repo | Role |
|------|------|
| [`DProvenanceKit-Premium`](https://github.com/Therealdk8890/DProvenanceKit-Premium) | Proprietary stubs / premium connectors (private) |
| [`dprovenancekit-server`](https://github.com/Therealdk8890/dprovenancekit-server) | Proprietary cloud control plane (private) |

See also [COMMERCIAL.md](../COMMERCIAL.md) for the live pilot offer.

*Last updated: September 2026*
