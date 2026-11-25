# DProvenanceKit

[![CI](https://github.com/Therealdk8890/DProvenanceKit/actions/workflows/ci.yml/badge.svg)](https://github.com/Therealdk8890/DProvenanceKit/actions/workflows/ci.yml)
[![Swift versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FTherealdk8890%2FDProvenanceKit%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/Therealdk8890/DProvenanceKit)
[![Platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FTherealdk8890%2FDProvenanceKit%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/Therealdk8890/DProvenanceKit)
[![PyPI](https://img.shields.io/pypi/v/dprovenancekit?label=PyPI)](https://pypi.org/project/dprovenancekit/)
[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)

**Catch AI agent regressions in CI: fail the pull request when your agent skips a step, even when the answer still looks right.**

DProvenanceKit records the steps your agent takes, compares each run with a known-good baseline, and exits non-zero when a step you marked critical disappears or changes. It is local-first and Apache-2.0, with Swift and Python SDKs, and it runs beside LangSmith, Langfuse, and OpenTelemetry rather than replacing them.

## Try it in 60 seconds

Any OS with Python 3. No model, API key, or network service.

```bash
python -m pip install dprovenancekit
dpk demo
```

The demo records a good run and a run that dropped its `verify` step, then shows the gate reporting `REGRESSION` with the removed steps. (`dpk` here is the Python package's command. On Apple platforms, the Swift equivalent is `swift run FoundationModelsRegressionDemo --gate`, below.)

## Gate your own agent in an afternoon

```bash
dpk init my-agent && cd my-agent
python agent_stub.py && dpk record    # record a known-good run, pin it as the baseline
python agent_stub.py && dpk gate      # Regression gate: PASS
# in agent_stub.py, change `is_active = verify_account_status(account)` to `is_active = True`, then:
python agent_stub.py && dpk gate      # REGRESSION / CRITICAL step removed (exit 1)
```

Mark the steps that must never silently disappear with `@traced(priority=TracePriority.CRITICAL)`, commit `.dprovenance/baseline.sqlite`, and run `dpk gate` on every pull request. A copy-paste GitHub Actions workflow and a self-checking script are in [Examples/PythonRegressionGate](Examples/PythonRegressionGate/). For a sticky PR comment with the verdict, use the [regression gate action](https://github.com/marketplace/actions/dprovenancekit-regression-gate).

The Python SDK includes adapters for LangChain/LangGraph, the OpenAI Agents SDK, LlamaIndex, and CrewAI, and can ingest OpenTelemetry GenAI traces. See [DProvenanceKitPython](https://github.com/Therealdk8890/DProvenanceKitPython).

## Why

- **Agents fail quietly.** After a model, prompt, or tool change, an agent can skip a lookup or a check and still produce a fluent answer. Output tests and LLM-judged evals can stay green.
- **Logs show what happened; a gate decides whether it ships.** DProvenanceKit turns "the path changed" into a pass or fail in CI.
- **Evidence you can verify offline.** Runs can be signed (CryptoKit P-256 in Swift; software keys in Python) and checked without sending traces anywhere.

## How it fits with LangSmith, Langfuse, and OpenTelemetry

| Tool | Main question it answers | Use it with DProvenanceKit for |
|---|---|---|
| LangSmith, Langfuse | What happened in this run, and how good was the output? | Inspecting and evaluating traces, while DPK blocks path regressions in CI |
| OpenTelemetry | How do I collect and ship telemetry vendor-neutrally? | Transport; DPK can ingest OTel GenAI traces (Python) and export OTLP spans (Swift) |
| DProvenanceKit | Did the instrumented decision path regress against its baseline? | A local regression gate and signed, offline-verifiable records |

## Swift on Apple platforms: try it in five minutes

DProvenanceKit is an open-source Swift SDK for teams building privacy-sensitive AI features with Apple's on-device [Foundation Models](https://developer.apple.com/documentation/foundationmodels). It records the model interactions and tool steps your application chooses to instrument, compares runs against a known-good baseline, and can produce attestations that are verifiable offline.

It is designed to sit beside your app's existing observability and evaluation stack — not replace it.

> **The short version:** when an OS, model, prompt, or tool change alters an important workflow, DPK helps make that change visible before it ships.

You need Swift 6 and an Apple development environment. The live Foundation Models example requires an OS and device that support Apple's Foundation Models framework (iOS 26, macOS 26, or visionOS 26); model availability also depends on the device and system.

Clone and run the live example:

```bash
git clone https://github.com/Therealdk8890/DProvenanceKit.git
cd DProvenanceKit
swift run FoundationModelsLiveQuickstart
```

The example calls the on-device model when available, records the run, flushes the trace to SQLite, and prints the captured event timeline and database path. Pass a prompt after `--`:

```bash
swift run FoundationModelsLiveQuickstart -- "Summarize this note in one sentence."
```

Want to see why the trace matters? Run the regression scenario:

```bash
swift run FoundationModelsRegressionDemo --gate
```

This compares a baseline weather-assistant transcript that calls a live-data tool with a candidate that silently skips the tool. DPK detects the missing step and the gate exits non-zero — a concrete example of a behavioral regression that can otherwise look like a successful response.

- [Live Foundation Models quickstart source](Sources/FoundationModelsLiveQuickstart/FoundationModelsLiveQuickstart.swift)
- [Foundation Models regression demo source](Sources/FoundationModelsRegressionDemo/FoundationModelsRegressionDemo.swift)
- [End-to-end instrument → gate → attest → verify demo](Examples/E2EDecisionPath/README.md)

## Add DPK to a Swift package

The latest release is **0.11.0** (Nov 22, 2026):

```swift
dependencies: [
    .package(url: "https://github.com/Therealdk8890/DProvenanceKit", from: "0.11.0")
]
```

Then add the products your app uses to its target dependencies:

```swift
.target(
    name: "YourApp",
    dependencies: [
        "DProvenanceKit",
        "DProvenanceFoundationModels"
    ]
)
```

Import the Foundation Models adapter alongside Apple's framework:

```swift
import FoundationModels
import DProvenanceFoundationModels
```

For an existing session, the adapter supports post-hoc transcript capture. For new integrations, use the traced session API to capture prompts, responses, and tool activity as the session runs. The complete runnable integration is in [FoundationModelsLiveQuickstart.swift](Sources/FoundationModelsLiveQuickstart/FoundationModelsLiveQuickstart.swift); API and configuration details are in the [Foundation Models adapter source](Sources/DProvenanceFoundationModels/DProvenanceFoundationModels.swift).

## What it gives your team

| Workflow | What DPK does |
|---|---|
| Instrument | Records the prompts, responses, tool calls, and other events your integration captures |
| Baseline | Stores a known-good decision path for comparison |
| Regression gate | Diffs candidate runs and can fail CI when configured critical steps disappear or change |
| Attest | Signs a recorded trace using the Swift attestation API |
| Verify | Checks the attestation offline, without sending the trace to a hosted service |

DPK is local-first. Your application controls what it records and exports. Review the [attestation threat model](docs/ATTESTATION.md) and configure redaction deliberately before capturing sensitive data.

## Trust boundaries — what DPK does and does not prove

DPK can establish that a particular recorded artifact matches its signed integrity data and can detect changes in the instrumented path that your policies classify as regressions.

It does **not** establish that model reasoning is correct, that evidence or citations are true, that an omitted uninstrumented step never happened, or that a workflow is compliant or regulator-approved. A valid signature alone does not establish signer identity or trusted time. Optional RFC 3161 timestamping is an external time assertion; DPK does not operate a transparency log.

These boundaries are deliberate. See [attestation limitations](docs/ATTESTATION.md#what-it-does-not-establish) and the [external anchor contract](docs/EXTERNAL_ANCHOR_CONTRACT.md).

## Further technical documentation

The README is intentionally optimized for the Foundation Models developer entry point. The expanded reference retains the broader SDK architecture, Swift/Python comparison, observability positioning, Python onboarding example, attestation details, and adoption guidance: **[DProvenanceKit technical overview](docs/TECHNICAL_OVERVIEW.md)**.

The **0.10.0 release** adds portable reasoning-history object/bundle verification
and experimental Structural Alignment v1/configuration authorization APIs. These are
opt-in surfaces; the existing alignment engine remains available. See the
[release checklist](docs/RELEASE_0.10.0.md), [reasoning-history format](docs/REASONING_REPOSITORY.md)
and [configuration contract](ConformanceHarness/CONFIGURATION_AUTHORIZATION_v1.md).

## Platform and language support

Swift and Python use a **shared DProvenanceKit product release version**. Matching version numbers identify a coordinated product release, not identical feature sets or interchangeable package artifacts. Use the capability matrix below and each SDK’s API documentation to determine what is available in that language. See the [cross-language release policy](docs/RELEASE_POLICY.md).

| Capability | Swift | Python |
|---|---|---|
| Record, query, and diff instrumented paths | Yes | Yes |
| Golden-baseline CI regression gate | Yes | Yes |
| Apple Foundation Models adapter | Yes | — |
| Secure Enclave-backed signing keys | Yes, on supported Apple hardware | — |
| Software-key trace attestation | Yes | MVP |
| Proof packs | Yes | Not yet |
| Portable reasoning-history objects and bundle verification | Yes; read-only verification | Yes |
| Local reasoning-history operations and web workbench | Not available | Yes; opt-in |
| Structural Alignment v1 and signed configuration manifests | Experimental, opt-in | Experimental, opt-in |

Python SDK: [DProvenanceKitPython](https://github.com/Therealdk8890/DProvenanceKitPython) — `pip install "dprovenancekit[crypto]"` for the attestation extra (0.7.0+).

## Works with your existing stack

Keep OpenTelemetry and your existing observability, tracing, and evaluation tools. DPK focuses on a different question: **did the instrumented decision path change in a way our team has decided should block release?**

It is a local SDK, not a hosted control plane or a replacement for production monitoring.

## Open-source evidence engine; separate enterprise operations

**DProvenanceKit is the evidence layer**: instrument, compare, gate, attest, and verify AI decision-path records locally. It works without a commercial account or hosted service.

For teams needing a coordinated operational layer, **NobodySystems** is a **separately licensed, proprietary private-alpha platform** combining DProvenanceKit evidence, [WarrantKit](https://github.com/Therealdk8890/WarrantKit) runtime-bound authority, and [AgentContainment](https://github.com/Therealdk8890/AgentContainment) external enforcement. Its current alpha includes a local controller, bounded guarded tools, and separate evidence verification; organization-wide policy lifecycle, cross-run evidence correlation, fleet operations, production enterprise guarantees, and hosted editions are **product direction, not shipped capabilities**.

**Start with the free SDK proof below.** For the engine/platform responsibilities, evaluation checklist, current limitations, and private-alpha inquiry path, see [NobodySystems integration and commercial boundary](docs/NOBODYSYSTEMS.md). See also [commercial services](COMMERCIAL.md) and the [product-layer matrix](docs/PRODUCT_LAYERS.md).

## Adoption and contribution

We're looking for Swift teams building privacy-sensitive on-device AI features — especially in health, finance, and legal applications — to try DPK on one real workflow.

**We will help with an initial integration at no charge.** In return, we'd like candid engineering feedback and, only with your permission, a short public case study describing what worked and what did not. No endorsement or public listing is required.

- [Open an integration discussion](https://github.com/Therealdk8890/DProvenanceKit/issues)
- [Read the documentation](https://dprovenance.dev)
- [Decision-Path Assurance Pilot](https://dprovenance.dev/pilot/) — optional professional services; the SDK remains Apache-2.0

## Status and license

**Public beta — latest published Swift release: [0.10.0](https://github.com/Therealdk8890/DProvenanceKit/releases/tag/0.10.0).** The coordinated Python SDK release [0.10.0](https://github.com/Therealdk8890/DProvenanceKitPython/releases/tag/v0.10.0) is also published on [PyPI](https://pypi.org/project/dprovenancekit/0.10.0/); its [Trusted Publishing workflow](https://github.com/Therealdk8890/DProvenanceKitPython/actions/runs/43797953686) succeeded. Matching versions identify a coordinated product release, not feature parity or interchangeable packages. APIs may continue to evolve before 1.0.

Both 0.10.0 publication paths are verified. The opt-in and experimental capabilities
in the matrix above retain their documented limits; see the
[publication record](docs/RELEASE_0.10.0.md).

Apache License 2.0. Free for commercial use.

---

Copyright 2026 Daniel Paul Kissel
