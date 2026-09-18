# 🚀 DProvenanceKit

## Tamper-evident records of instrumented AI decision paths — offline-verifiable, CI-gated

For teams in healthcare, finance, and legal building AI systems that need a local-first record of *which instrumented steps ran*, a regression gate when that path drifts, and (on Swift) a signed attestation they can verify without calling home.

> Working in Python? **[DProvenanceKitPython](https://github.com/Therealdk8890/DProvenanceKitPython)** — `pip install "dprovenancekit[crypto]"` (attestation MVP on main / **0.7.0+**; older PyPI wheels lack it). Same recording, diff, CI gate, and `DPK-BINARY-V1` software attestation; adapters for LangChain, OpenAI Agents, LlamaIndex, and CrewAI. Proof packs and Secure Enclave remain Swift-only (see matrix below).

---

## The gap request-level observability leaves open

Your AI makes a decision that impacts a customer. The decision is challenged.

**Lender:** "Why did you reject this applicant?"
**Doctor:** "Why did you recommend that treatment?"
**Lawyer:** "What's the basis for this legal argument?"
**Auditor:** "Has this recorded decision path been altered since it was written?"

Request-level observability (OpenTelemetry, LangSmith, Langfuse, Datadog) remains essential for what happened in production. It does not, by itself, give you a **queryable, diffable, locally retained record of the instrumented decision path** — or a CI check that refuses merge when that path regresses. For regulated workflows, that gap matters: sensitive reasoning often cannot leave your infrastructure.

DProvenanceKit is built to close that gap: **record the instrumented path, diff it against a golden baseline, gate CI when it drifts, and (Swift) attach an offline-verifiable attestation to what was recorded.**

It does **not** prove that model reasoning was “sound,” that every claim in a payload is true, or that a regulator will accept the artifact as sufficient evidence. For the signed-artifact threat model, read [docs/ATTESTATION.md — What it does not establish](docs/ATTESTATION.md#what-it-does-not-establish).

---

## Built for teams in regulated industries

### Healthcare
Diagnostic-support and clinical decision tools need a durable record of which checks ran and what evidence was attached — retained locally, comparable across releases, and (when attested) integrity-checked offline.

### Financial Services
Lending and underwriting workflows need an auditable trail of the instrumented factors that entered a decision, plus a CI gate when that trail changes after a model or prompt update.

### Legal
Brief-generation and citation workflows need a retained chain of verification steps your team instrumented — not a promise that citations are correct, but a record you can review, diff, and (Swift) attest.

### Insurance
Claims workflows need a consistent, queryable decision path for appeals and internal audit — and a regression signal when automation drifts.

### Government
Eligibility and records workflows often cannot ship raw reasoning to a hosted SaaS. Local-first recording keeps data where policy requires; attestation (Swift) adds integrity for exports you choose to share.

---

## How It Works

**DProvenanceKit is not a SaaS platform. It's a local-first SDK.**

1. **Your AI system runs normally.** Everything stays on your infrastructure.

2. **Each instrumented decision path is recorded locally.**
   - Reasoning steps you wrap or emit
   - Evidence and tool calls you record
   - Intermediate results you choose to capture

3. **Compare and gate.**
   - Diff a candidate run against a golden baseline
   - Fail CI when the path regresses beyond policy
   - Keep using your existing eval and observability stack

4. **Attest (Swift).**
   - Canonicalization: `DPK-BINARY-V1` (domain-separated binary encoding — **not** JCS/RFC 8785)
   - Signature: ECDSA P-256 over SHA-256, ASN.1 DER (CryptoKit; Secure Enclave keys optional on supported Apple hardware)
   - Self-contained attestation JSON + optional [proof packs](docs/PROOF_PACK.md) binding artifact digests
   - Offline verification with no network dependency

Python shares recording, query, diff, the CI gate, and **MVP `DPK-BINARY-V1` software attestation** via `dprovenancekit[crypto]` (released in Python **0.7.0+**; proof packs remain Swift-only). End-to-end decision-path demo (gate + attest): `swift run E2EDecisionPathDemo` — see [Examples/E2EDecisionPath](Examples/E2EDecisionPath/README.md); Python twin: [examples/e2e_decision_path](https://github.com/Therealdk8890/DProvenanceKitPython/tree/main/examples/e2e_decision_path).

---

## Swift vs Python capability matrix

| Capability | Swift (`DProvenanceKit`) | Python (`dprovenancekit`) |
|---|---|---|
| Record / store / query instrumented paths | Yes | Yes |
| Semantic diff + golden baselines | Yes | Yes |
| CI regression gate | Yes (`dpk` / package tools) | Yes (`dprovenancekit gate`, pytest `golden_trace`, [GitHub Action](https://github.com/marketplace/actions/dprovenancekit-regression-gate)) |
| Framework adapters (LangChain, Agents, …) | Foundation Models (+ OTel bridge) | LangChain, OpenAI Agents, LlamaIndex, CrewAI, OTel ingest |
| Trace attestation (`DPK-BINARY-V1` + P-256 DER) | **Yes** | **MVP yes** (`dprovenancekit[crypto]`; software keys; **0.7.0+** / on main) |
| Proof packs | **Yes** | **Not yet** |
| Secure Enclave–backed keys | **Yes** (Apple platforms) | N/A |

> **CI Action pin:** the Marketplace Action defaults to `install-spec: dprovenancekit==0.7.0`. Prefer pinning the Action itself to a commit SHA (see [dprovenancekit-action](https://github.com/Therealdk8890/dprovenancekit-action)).

Cross-language conformance covers fingerprints, query semantics, profile hash, and alignment verdicts per [TRACE_SPEC_v1](https://github.com/Therealdk8890/DProvenanceKitPython/blob/main/conformance/TRACE_SPEC_v1.md). Payload encodings need **not** be byte-identical across SDKs; equivalence is on decoded payloads and structural fingerprints.

---

## Works with your observability stack

DProvenanceKit aims to be the local-first layer for **AI decision-path observability** — record, diff, attest (Swift), and CI-gate the instrumented path. It is built to sit **beside** OpenTelemetry, LangSmith, Langfuse, and Arize, not to replace them.

| | Platform / request observability (LangSmith, Langfuse, OTel, …) | DProvenanceKit |
|---|---|---|
| **Job** | Spans, dashboards, evals, production monitoring | Decision path, golden baselines, CI gate, signed attestation (Swift) |
| **Question** | What happened? | Did the instrumented decision path regress — and (Swift) can we verify the record wasn’t altered after signing? |
| **Where data lives** | Collector or hosted platform (by design) | Local-first; optional OTel export when you choose |
| **How they fit** | Keep using them | Add DPK next to them |

**Bottom line:** Use LangSmith, Langfuse, and OpenTelemetry for platform observability. Use DProvenanceKit when you need the decision path to be queryable, diffable, refused in CI when it drifts, and — on Swift — attestable offline.

---

## Real Example: Legal Document Provenance

A law firm uses an AI to draft legal briefs.

**The problem:** Every citation must be verifiable. If the AI cites a case that doesn't exist, that's malpractice.

**How DProvenanceKit helps:**

```
1. Legal AI generates brief
2. Before export, instrumented verification steps are recorded:
   - Case existence check against a legal database
   - Statute currency check
   - Quote accuracy check against source
3. (Swift) The recorded chain is attested (DPK-BINARY-V1 + P-256 DER)
4. Brief is exported with an optional proof pack binding report digests
5. If disputed, the firm can show:
   - The instrumented reasoning chain that was recorded
   - (Swift) The signature and offline verification result
   - That the attested record has not been tampered with since signing
```

Attestation establishes integrity of what was recorded — not truthfulness of citations or legal sufficiency. See [What it does not establish](docs/ATTESTATION.md#what-it-does-not-establish).

---

## Open Source + Paid Governance Support

### Option 1: Self-Directed (Open Source)

Product layers (OSS evidence engine vs commercial AI Assurance Platform): see [docs/PRODUCT_LAYERS.md](docs/PRODUCT_LAYERS.md).

DProvenanceKit is Apache 2.0 licensed. You can use it free:

```bash
# Python
pip install dprovenancekit

# Swift
dependencies: [
    .package(url: "https://github.com/Therealdk8890/DProvenanceKit", from: "0.8.1")
]
```

You instrument your AI workflow. You establish baselines. You manage the governance policy.

**Best for:** Teams with internal compliance/audit expertise.

### Option 2: Governed AI Deployment Pilot ($4,500 one-time)

For organizations that want governance guidance and a structured review of one AI workflow:

**Includes:**
- **Instrumentation review:** Is this the right tracing for your compliance needs?
- **Baseline establishment:** What's the "golden" reasoning path your AI should follow?
- **Governance policy definition:** What counts as a regression? When do we alert? What's audit-worthy?
- **Compliance-oriented audit report:** A written summary of your reasoning architecture and how DPK artifacts support review — not certification, indemnity, or a guarantee of regulatory acceptance.

**Does not include:**
- Recurring SaaS or managed service
- Code in your repository
- Ongoing support (scope separately as needed)
- Certification under any legal or industry framework

**Who this is for:** Chief Risk Officer, Compliance Officer, Audit Manager at an organization in a regulated industry deploying one specific AI workflow.

**Example scope:**
- Healthcare: Diagnostic-recommendation AI
- Finance: Lending decision AI
- Legal: Brief-generation AI
- Insurance: Claims-approval AI

**Timeline:** 30 days, delivered as a report.

**Next step:** [Request a pilot](mailto:danielpaulkissel@gmail.com?subject=Governed%20AI%20Deployment%20Pilot).

---

## Getting Started

### For Open-Source Users

1. **Define your AI's critical decisions**
   - Which instrumented steps must appear in an audit trail?
   - What evidence matters?
   - Where is liability highest?

2. **Instrument one workflow** (Python or Swift)

```python
from dprovenancekit import traced, record_event, traced_run

@traced("lending_decision")
def approve_or_reject(applicant_data):
    # Your AI logic here
    record_event("credit_score_checked", applicant_data["credit"])
    record_event("income_verified", applicant_data["income"])
    decision = model.predict(applicant_data)
    record_event("decision_made", decision)
    return decision

# Run it
traced_run(context_id="applicant_12345", store=store)(approve_or_reject)(data)
```

3. **Establish a baseline**
   - Run your workflow multiple times
   - Pin a known-good run
   - Store the baseline with the repo

4. **Gate future changes**
   - When you update the model, re-run
   - Compare new reasoning to baseline
   - Diff shows exactly what changed
   - Decide: Is this safe to deploy?

5. **Attest and verify (Swift)**
   - Sign with `TraceAttestationDocument` / `dpk attest`
   - Hand auditors the attestation or proof pack
   - They verify offline — no internet, no vendor involvement
   - Integrity of the recorded path, within the [documented limits](docs/ATTESTATION.md#what-it-does-not-establish)

### For Pilot Participants

1. Schedule a kickoff call
2. Define the scope (one AI workflow)
3. Provide your reasoning trace format
4. Receive governance policy + audit report
5. Keep the open-source tool, informed by compliance-oriented review

---

## Technical Foundation

- **Recording:** Non-blocking writes with priority-aware backpressure
- **Storage:** WAL-mode SQLite (crash-safe, auditable)
- **Query language:** Temporal and structural reasoning patterns
- **Diffing:** Semantic alignment engine that detects regressions
- **Attestation (Swift):** `DPK-BINARY-V1` canonicalization + ECDSA P-256 (SHA-256, ASN.1 DER); optional Secure Enclave keys
- **Verification (Swift):** Deterministic, offline, open-source — see [docs/ATTESTATION.md](docs/ATTESTATION.md)
- **Proof packs (Swift):** Signed attestation + embedded artifact digests — [docs/PROOF_PACK.md](docs/PROOF_PACK.md)

**Cross-language:** Swift and Python stay aligned via a formal Trace Spec and shared conformance vectors (fingerprint, query, profile hash, alignment). Payload bytes need not match across languages; see TRACE_SPEC §2.

**Quality bar:** Conformance suite and benchmark corpus exercise edge cases. Built for teams in regulated industries; not a claim of production certification or regulator endorsement.

---

## No Third-Party Dependencies

**Core (Python):**
```
sqlite3, contextvars, threading, json, hashlib, uuid, urllib
```

No pip dependencies. Just Python's standard library. Requires Python 3.9+.

**Core (Swift):**
```
Foundation, CryptoKit, SQLite
```

No external packages. Native to macOS/iOS. Requires Swift 6.0.

**Why this matters for compliance:** Fewer dependencies = smaller attack surface = easier for auditors to review.

---

## Adoption Path

### Week 1
Integrate DProvenanceKit into one AI workflow. Record a baseline.

### Week 2-4
Establish governance policy. Define what counts as a regression.

### Month 1-3
Gate releases on instrumented-path changes. Export attestations or proof packs where needed (Python: software keys via `[crypto]`; Swift: software or Secure Enclave; proof packs Swift-only).

### Ongoing
Every release: baseline vs. candidate. A clear record of whether the instrumented path stayed consistent.

---

## Status

**Public beta — [0.8.1](https://github.com/Therealdk8890/DProvenanceKit/releases/tag/0.8.1) is released; APIs may continue to evolve before 1.0.**

---

## License

Apache 2.0. Free for commercial use.

---

## Contact

**For pilot inquiry:**
[Request Governed AI Deployment Pilot](mailto:danielpaulkissel@gmail.com?subject=Governed%20AI%20Deployment%20Pilot)

**For open-source questions:**
GitHub Issues: https://github.com/Therealdk8890/DProvenanceKit

**For technical details:**
- Swift: https://github.com/Therealdk8890/DProvenanceKit
- Python: https://github.com/Therealdk8890/DProvenanceKitPython
- Docs: https://dprovenance.dev
- Attestation limits: [docs/ATTESTATION.md](docs/ATTESTATION.md)

---

## Why This Exists

AI systems make decisions that affect real people. Teams in regulated industries need a durable, local record of instrumented decision paths — and a way to catch regressions before release. Cloud-based observability platforms aren't designed for that job alone.

DProvenanceKit is built for teams that care about:
- **Privacy:** Data stays local unless you explicitly export
- **Auditability:** Paths are queryable, diffable, and (Swift) integrity-checkable offline
- **Change control:** CI can refuse merges when the golden path drifts
- **Honest scope:** Attestation supports audit workflows; it is not by itself certification or proof that a decision was “sound”

If your AI makes healthcare, financial, legal, or insurance decisions, start with one workflow and a golden baseline.