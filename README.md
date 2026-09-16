# 🚀 DProvenanceKit

## Prove Your AI's Reasoning to Regulators. Offline. Cryptographically.

For healthcare, finance, and legal AI systems that must demonstrate why they made each decision — without sending sensitive reasoning traces to third-party services.

> Working in Python? **[DProvenanceKitPython](https://github.com/Therealdk8890/DProvenanceKitPython)** — `pip install dprovenancekit`. Same regression gate and adapters for LangChain, OpenAI Agents, LlamaIndex, and CrewAI.

---

## The Problem Regulators Actually Care About

Your AI makes a decision that impacts a customer. The decision is challenged.

**Lender:** "Why did you reject this applicant?"
**Doctor:** "Why did you recommend that treatment?"
**Lawyer:** "What's the basis for this legal argument?"
**Auditor:** "Prove this decision wasn't changed after the fact."

Traditional APM platforms (Datadog, New Relic) and AI observability platforms (Langfuse, LangSmith) answer "what happened," not "why did the AI decide that?" And they're cloud-based—your sensitive reasoning traces live on someone else's servers.

Regulators don't accept that answer. Neither should you.

DProvenanceKit answers the question regulators actually ask: **Can you prove, cryptographically, that your AI's reasoning was sound and hasn't been tampered with?**

---

## Why This Matters for Regulated Industries

### Healthcare
Your diagnostic-support AI recommends treatment. A patient sues. The hospital needs to show that the recommendation was based on the patient's actual symptoms and medical history—not a hallucination. A cryptographically signed trace is that proof.

### Financial Services
Your lending AI rejects an applicant. They file a fair-lending complaint. You need to prove the decision was based on relevant factors, not proxy discrimination. A verifiable reasoning chain is your defense.

### Legal
Your legal AI generates a brief with case citations. Opposing counsel challenges the citations. You need to prove every case actually exists and was correctly cited. The entire reasoning is signed so it can't be disputed.

### Insurance
Your claims AI approves or denies a claim. The customer appeals. Auditors want to see the decision tree. A provable reasoning path shows the logic was consistent and wasn't hidden.

### Government
Your AI processes FOIA requests or makes eligibility determinations. Citizens and auditors need to understand the reasoning. Local-first means no privacy concerns, and cryptographic signing means it's trustworthy.

---

## How It Works

**DProvenanceKit is not a SaaS platform. It's a local-first SDK.**

1. **Your AI system runs normally.** Everything stays on your infrastructure.

2. **Each decision is recorded locally.**
   - Every reasoning step
   - Every evidence used
   - Every tool called
   - Every intermediate result

3. **The trace is cryptographically signed.**
   - SHA-256 hash of the canonical reasoning path
   - ECDSA P-256 signature (can use Secure Enclave on Apple platforms)
   - Detached JWS (proof is separate from trace data)

4. **Auditors verify offline, without calling home.**
   - No external service dependency
   - No internet required
   - Proof that traces weren't modified in transit
   - Open-source verification code they can audit themselves

---

## DProvenanceKit vs. Cloud Observability Platforms

| | Langfuse, LangSmith, Arize | DProvenanceKit |
|---|---|---|
| **Where traces live** | Third-party cloud servers | Your infrastructure only |
| **Regulatory proof** | "Here's what happened" | "Here's cryptographic proof of why" |
| **Data residency** | Governed by vendor | Governed by you |
| **Auditor verification** | Depends on vendor's uptime | Works offline, forever |
| **HIPAA/PCI compliance** | Business Associate Agreement required | No BAA needed (data doesn't leave) |
| **Cost** | Recurring SaaS (per trace, per month) | One-time per workflow |
| **Use case** | Engineering iteration, debugging | Compliance, regulatory proof |

**Bottom line:** Use Langfuse or LangSmith to build and debug your AI. Use DProvenanceKit to prove it works correctly to regulators.

---

## Real Example: Legal Document Provenance

A law firm uses an AI to draft legal briefs.

**The problem:** Every citation must be verifiable. If the AI cites a case that doesn't exist, that's malpractice.

**How DProvenanceKit helps:**

```
1. Legal AI generates brief
2. Before export, every claim is verified:
   - "Does this case actually exist?" (checked against legal database)
   - "Is this statute current?" (validated against code)
   - "Is this quote accurate?" (matched against source)
3. The entire reasoning chain is cryptographically signed
4. Brief is exported with proof packet attached
5. If disputed, the firm can show:
   - "Here's the reasoning chain"
   - "Here's the signature"
   - "Auditors can verify it hasn't been tampered with"
```

---

## Open Source + Paid Governance Support

### Option 1: Self-Directed (Open Source)

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

For organizations that want governance guidance + compliance audit:

**Includes:**
- **Instrumentation review:** Is this the right tracing for your compliance needs?
- **Baseline establishment:** What's the "golden" reasoning path your AI should follow?
- **Governance policy definition:** What counts as a regression? When do we alert? What's audit-worthy?
- **Compliance audit report:** Proof of your reasoning architecture for regulators.

**Does not include:**
- Recurring SaaS or managed service
- Code in your repository
- Ongoing support (scope separately as needed)

**Who this is for:** Chief Risk Officer, Compliance Officer, Audit Manager at a regulated organization deploying one specific AI workflow.

**Example scope:**
- Healthcare: Diagnostic-recommendation AI
- Finance: Lending decision AI
- Legal: Brief-generation AI
- Insurance: Claims-approval AI

**Timeline:** 30 days, delivered as a report.

**Next step:** [Request a pilot](mailto:inquiry@dprovenance.dev?subject=Governed%20AI%20Deployment%20Pilot).

---

## Getting Started

### For Open-Source Users

1. **Define your AI's critical decisions**
   - What reasoning steps must regulators see?
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
   - Sign the reasoning as "known good"
   - Store the proof

4. **Gate future changes**
   - When you update the model, re-run
   - Compare new reasoning to baseline
   - Diff shows exactly what changed
   - Decide: Is this safe to deploy?

5. **Verify with auditors**
   - Give them the proof packet
   - They verify the signature offline
   - No internet, no vendor involvement
   - Proof that traces are authentic

### For Pilot Participants

1. Schedule a kickoff call
2. Define the scope (one AI workflow)
3. Provide your reasoning trace format
4. Receive governance policy + audit report
5. Keep the open-source tool, informed by compliance experts

---

## Technical Foundation

DProvenanceKit is built on proven infrastructure:

- **Recording:** Non-blocking writes with priority-aware backpressure
- **Storage:** WAL-mode SQLite (crash-safe, auditable)
- **Query language:** Temporal and structural reasoning patterns
- **Diffing:** Semantic alignment engine that detects regressions
- **Signatures:** Canonical JSON (JCS/RFC 8785) + ECDSA P-256
- **Verification:** Deterministic, offline, open-source

**Cross-language:** Swift and Python implementations kept in sync by a formal conformance spec, not by hope. They produce byte-identical outputs for the same input.

**Battle-tested:** Reasoning observability in production at regulated organizations. Consensus suite validates correctness. Benchmark corpus tests edge cases.

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
Gate releases on reasoning changes. Provide proof to auditors.

### Ongoing
Every release: baseline vs. candidate. Proof that reasoning was consistent.

---

## Status

**Public beta — [0.8.1](https://github.com/Therealdk8890/DProvenanceKit/releases/tag/0.8.1) is released; APIs may continue to evolve before 1.0.**

---

## License

Apache 2.0. Free for commercial use.

---

## Contact

**For pilot inquiry:**
[Request Governed AI Deployment Pilot](mailto:inquiry@dprovenance.dev?subject=Governed%20AI%20Deployment%20Pilot)

**For open-source questions:**
GitHub Issues: https://github.com/Therealdk8890/DProvenanceKit

**For technical details:**
- Swift: https://github.com/Therealdk8890/DProvenanceKit
- Python: https://github.com/Therealdk8890/DProvenanceKitPython
- Docs: https://dprovenance.dev

---

## Why This Exists

AI systems make decisions that affect real people. Regulators want to see the reasoning. Cloud-based observability platforms aren't designed for that.

DProvenanceKit is built for teams that care about:
- **Privacy:** Data stays local
- **Auditability:** Reasoning is provable and verifiable
- **Liability:** Proof that the decision was sound
- **Compliance:** Evidence that regulators will accept

If your AI makes healthcare, financial, legal, or insurance decisions, you need this.
