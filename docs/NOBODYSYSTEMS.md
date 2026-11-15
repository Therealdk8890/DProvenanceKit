# DProvenanceKit and NobodySystems: evaluation and licensing boundary

## Choose what you are evaluating

| Layer | Product | What it provides today | What it does not prove |
|---|---|---|---|
| Evidence | **DProvenanceKit** (this Apache-2.0 SDK) | Local instrumentation, decision-path diffing and regression gates, optional signed trace artifacts and offline verification | Truth of model output, complete observation of uninstrumented steps, or trusted identity from a self-supplied signer key |
| Authority | [WarrantKit](https://github.com/Therealdk8890/WarrantKit) (independent Apache-2.0 project) | Scoped Warrants, epoch fencing, guarded adapter/gateway integration | Process isolation or blocking paths bypassing the protected gateway |
| Enforcement | [AgentContainment](https://github.com/Therealdk8890/AgentContainment) (independent Apache-2.0 project) | Controller-owned execution leases, Linux cgroup-v2/eBPF containment integrations and host-boundary tests | Universal isolation across hosts, workloads, or bypass routes |
| Operations | **NobodySystems** (separately licensed, private alpha) | Local controller, bounded guarded tool operations, operator-facing interfaces, and a separately executed evidence verifier under a constrained evaluation profile | A shipped enterprise fleet system, arbitrary hostile-agent isolation, regulated compliance certification, or a production SLA |

NobodySystems is the **operational/control-plane layer for teams**, not a replacement implementation of the open-source verification or enforcement primitives. Its **intended** commercial scope covers organizational policy lifecycle and distribution, evidence correlation across runs/engines, fleet operations, and enterprise tenancy, support, and deployment guarantees. Those are roadmap areas until individually implemented, tested, and contracted. The private alpha is not a generally available SaaS product.

## Reproduce the public evidence-layer result

From a Swift 6-capable Apple development environment:

```bash
git clone https://github.com/Therealdk8890/DProvenanceKit.git
cd DProvenanceKit
swift run FoundationModelsRegressionDemo --gate
```

The deterministic regression example compares a baseline workflow that calls a data tool with a candidate that skips it. The gate should identify the missing instrumented step and exit non-zero. **A non-zero gate is the expected demonstration outcome, not a broken install.** See [regression demo details](foundation-models-regression-demo.md) and the [instrument → gate → attest → verify example](../Examples/E2EDecisionPath/README.md). The latter exercises a separate verification path; assess key provisioning and captured fields before drawing authenticity conclusions.

**Evaluator checklist:** record the exact Git commit/toolchain, run the reproducible example, inspect which trace events were actually instrumented, confirm the intended gate outcome, and verify signed artifacts with a trusted public key obtained independently of the evidence being inspected. Do not infer authority or containment from a valid DProvenanceKit trace.

## OSS versus proprietary boundary

- All code in this public repository remains Apache-2.0; commercial use of its documented core capabilities does not require NobodySystems, an account, or payment.
- NobodySystems private-alpha source and commercial terms are separate. There is no public repository access or self-serve platform signup implied by these links.
- The [DProvenanceKit commercial services offer](../COMMERCIAL.md) is an independent, scoped assurance engagement; it does **not** bundle NobodySystems, hosted fleet operations, compliance certification, or an SLA.
- Local containment, authority checks, and evidence verification must remain functional without connectivity to the management plane. Evidence must not grant execution authority.

## Request a controlled platform evaluation

After validating this OSS SDK, teams seeking a policy/evidence/enforcement orchestration trial can [request a NobodySystems private-alpha discussion](mailto:danielpaulkissel@gmail.com?subject=NobodySystems%20private-alpha%20evaluation). Ask for the supported threat model, pinned engine/alpha revisions, trust-anchor procedure, executable Linux evidence package, explicit unimplemented controls, and written evaluation scope. Access is by approval, not a general release.

See [product layers](PRODUCT_LAYERS.md), [attestation threat model](ATTESTATION.md), and [open-source commercial terms](../COMMERCIAL.md).
