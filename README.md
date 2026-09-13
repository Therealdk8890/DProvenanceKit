🚀 DProvenanceKit

Prove Your AI Decisions. Locally. Cryptographically.

For healthcare, finance, legal, insurance, and government AI systems that need verifiable evidence of how a decision was produced—without sending sensitive traces to a third-party observability service.

⸻

The Problem

Your AI makes a decision that affects a person. Later, someone asks:

Lender: “Why was this application rejected?”
Doctor: “What evidence supported this recommendation?”
Lawyer: “What sources supported this argument?”
Auditor: “Can you prove this record wasn’t changed?”

Traditional APM and AI observability platforms are built primarily for debugging and operational visibility. They can show what happened, but they aren’t designed to provide an independently verifiable record of decision provenance.

DProvenanceKit provides the infrastructure to record, compare, sign, and independently verify AI decision artifacts.

⸻

Why This Matters for Regulated AI

Healthcare

A diagnostic-support system recommends a treatment. An organization may need to reconstruct what inputs, evidence, tools, and decision steps were present when the recommendation was generated.

DProvenanceKit creates a tamper-evident record that can be retained and independently verified.

Financial Services

A lending or underwriting system makes a decision. Compliance teams need to understand which inputs and decision path produced the result.

DProvenanceKit provides a verifiable provenance record for the workflow.

Legal

A legal AI generates a brief containing claims and citations. The organization needs an auditable record of which sources were consulted and how the output was produced.

DProvenanceKit can record those evidence and verification steps and bind them to a signed proof artifact.

Insurance

A claims system approves or denies a claim. Auditors may need to reconstruct the decision path and determine whether the recorded workflow changed afterward.

DProvenanceKit provides a signed, independently verifiable decision record.

Government

AI systems processing eligibility determinations, records requests, or other consequential workflows may require strong auditability and data-local operation.

DProvenanceKit keeps provenance data under the organization’s control and supports offline verification.

⸻

How It Works

DProvenanceKit is not a SaaS platform. It’s a local-first SDK.

1. Your AI system runs normally.
    DProvenanceKit runs alongside it on your infrastructure.
2. Decision activity is recorded locally.
    * Reasoning or workflow steps
    * Evidence used
    * Tool calls
    * Intermediate results
    * Final decisions
3. The resulting trace can be cryptographically bound to a proof artifact.
    * SHA-256 hashing of canonical data
    * ECDSA P-256 signatures
    * Detached JWS proof artifacts
    * Canonical JSON using JCS / RFC 8785
4. The artifact can be verified independently.
    * No DProvenanceKit service required
    * No internet connection required
    * No vendor account required
    * Open-source verification logic

What the Signature Proves

Cryptographic signing establishes integrity and authenticity of the signed artifact, assuming the signing key is properly controlled.

It does not, by itself, prove that an AI’s reasoning was correct, unbiased, complete, or legally compliant.

DProvenanceKit provides the evidence infrastructure. Your organization’s validation, governance, policies, and domain-specific controls determine whether the underlying decision was acceptable.

⸻

DProvenanceKit vs. Cloud Observability

	Langfuse, LangSmith, Arize	DProvenanceKit
Primary purpose	AI observability and debugging	Decision provenance and verification
Trace location	Vendor or managed infrastructure	Your infrastructure
Integrity evidence	Platform-dependent	Cryptographically verifiable artifacts
Verification	Typically through platform	Offline and independently
Data residency	Depends on deployment	Controlled by you
Vendor dependency	Platform required for platform features	Core verification does not require a service
Best for	Engineering iteration and monitoring	Auditability, provenance, and controlled evidence

Bottom line: Use observability platforms to understand your AI system. Use DProvenanceKit when you need a durable, independently verifiable record of what your system did.

⸻

Real Example: Legal Document Provenance

A law firm uses an AI system to draft legal briefs.

Before export, the workflow verifies:

1. Legal AI generates a draft
2. Claims and citations are checked
3. Sources and verification results are recorded
4. The decision/provenance trace is canonicalized
5. The resulting artifact is cryptographically signed
6. The brief is exported with its proof packet
7. The proof can later be independently verified

If the record is challenged, the firm can demonstrate:

* What evidence was recorded
* What workflow events occurred
* What artifact was signed
* Whether the signed artifact has been altered
* Which signing key produced the signature

The cryptographic proof establishes artifact integrity—not the truth of every underlying claim. Domain-specific validation remains essential.

⸻

Open Source + Paid Governance Support

Option 1: Self-Directed

DProvenanceKit is Apache 2.0 licensed and free to use.

# Python
pip install dprovenancekit

Swift Package Manager:

dependencies: [
    .package(url: "https://github.com/Therealdk8890/DProvenanceKit", from: "0.8.1")
]

You instrument your AI workflow, establish baselines, and define your own governance policies.

Best for: Teams with internal engineering, compliance, or audit expertise.

Option 2: Governed AI Deployment Pilot — $4,500 One-Time

For organizations that want help applying provenance and regression controls to a specific AI workflow.

Includes:

* Instrumentation review — Evaluate what should be recorded
* Baseline establishment — Define the expected workflow and evidence
* Governance policy — Define regressions, alerts, and audit events
* Compliance-oriented report — Document the resulting provenance architecture and controls

Does not include:

* Recurring SaaS
* Managed hosting
* Code in your repository
* Ongoing support

Typical scope: One AI workflow in healthcare, finance, legal, insurance, or another regulated environment.

Timeline: 30 days.

Next step: Request a pilot.

⸻

Getting Started

For Open-Source Users

1. Identify Critical Decisions

Determine:

* Which decisions require reconstruction
* Which evidence must be retained
* Which tools or external sources matter
* Where model changes create the greatest risk

2. Instrument One Workflow

from dprovenancekit import traced, record_event, traced_run
@traced("lending_decision")
def approve_or_reject(applicant_data):
    record_event("credit_score_checked", applicant_data["credit"])
    record_event("income_verified", applicant_data["income"])
    decision = model.predict(applicant_data)
    record_event("decision_made", decision)
    return decision
traced_run(
    context_id="applicant_12345",
    store=store
)(approve_or_reject)(data)

3. Establish a Baseline

Run the workflow under known-good conditions.

Record and sign the resulting provenance artifact.

4. Gate Future Changes

When the model, prompts, tools, or workflow change:

* Re-run the workflow
* Compare against the baseline
* Inspect semantic differences
* Determine whether the change is acceptable
* Retain the resulting evidence

5. Verify

Provide the proof artifact to an auditor or reviewer.

They can independently verify the cryptographic integrity of the artifact without contacting a DProvenanceKit service.

⸻

Technical Foundation

DProvenanceKit provides:

* Recording: Non-blocking writes with priority-aware backpressure
* Storage: WAL-mode SQLite
* Querying: Temporal and structural reasoning patterns
* Diffing: Semantic alignment and regression detection
* Signing: Canonical JSON (JCS / RFC 8785) + ECDSA P-256
* Verification: Deterministic, offline, open-source verification

Cross-Language

Swift and Python implementations are maintained against a formal conformance specification.

The goal is deterministic, compatible behavior across implementations—not merely two independently maintained SDKs.

Verification

The project includes conformance and benchmark suites designed to exercise correctness, compatibility, and edge cases.

⸻

No Third-Party Dependencies

Core Python

sqlite3
contextvars
threading
json
hashlib
uuid
urllib

No pip dependencies for the core package.

Python: 3.9+

Core Swift

Foundation
CryptoKit
SQLite

No external runtime packages for the core implementation.

Swift: 6.0+

Fewer dependencies can simplify deployment, security review, and auditability.

⸻

Adoption Path

Week 1

Integrate DProvenanceKit into one critical AI workflow.

Record a baseline.

Weeks 2–4

Define:

* Required evidence
* Expected workflow behavior
* Regression criteria
* Audit retention requirements

Months 1–3

Begin gating meaningful model and workflow changes against the established baseline.

Ongoing

For each significant release:

Baseline → Candidate → Diff → Review → Decision → Evidence

⸻

Status

Public beta — 0.8.1 is released; APIs may continue to evolve before 1.0.

⸻

License

Apache 2.0. Free for commercial use.

⸻

Contact

For pilot inquiries:
Request Governed AI Deployment Pilot

Open-source questions:
GitHub Issues: https://github.com/Therealdk8890/DProvenanceKit

Technical details:

* Swift: https://github.com/Therealdk8890/DProvenanceKit
* Python: https://github.com/Therealdk8890/DProvenanceKitPython
* Docs: https://dprovenance.dev

⸻

Why This Exists

AI systems increasingly make decisions that affect real people.

Organizations need more than logs. They need durable evidence of what happened, what information was recorded, what changed, and whether the resulting artifact can still be trusted.

DProvenanceKit is built for teams that care about:

* Privacy: Keep provenance data on your infrastructure
* Integrity: Detect modification of signed artifacts
* Auditability: Reconstruct decision workflows
* Reproducibility: Compare current behavior against known baselines
* Control: Verify evidence without depending on a hosted service

Record it. Compare it. Sign it. Verify it.
