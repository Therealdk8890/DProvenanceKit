# DProvenanceKit Reasoning Regression Pilot

A fixed-scope, 30-day engagement for teams that need to catch silent AI workflow regressions before they reach production.

## The offer

- **Price:** $1,500 USD
- **Duration:** 30 days
- **Scope:** one AI agent or AI-assisted workflow, one repository, and one CI environment
- **Best fit:** Python agents, Apple Foundation Models apps, tool-using assistants, evidence/retrieval workflows, and systems where skipping a verification or approval step creates real risk

## Buyer outcome

At the end of the pilot, the selected workflow has:

1. An explicit vocabulary for the execution steps that matter.
2. A recorded known-good baseline.
3. A repeatable candidate-run workflow.
4. A structural regression gate that fails when critical steps disappear or change beyond the agreed tolerance.
5. Initial anomaly rules for the highest-risk failure modes, such as a dropped verification step or looping tool.
6. A written reasoning-assurance report describing what is covered, what was observed, and what remains outside the detection boundary.

The pilot is successful when a material workflow change creates a visible, reproducible regression result instead of silently shipping.

## What is included

### Discovery and instrumentation

- One kickoff session to select the workflow and define success.
- Review of the agent architecture, tool sequence, model/prompt boundaries, and current test or evaluation process.
- Recommended event vocabulary and priority model.
- Instrumentation guidance or implementation support for the agreed workflow.

### Baseline and regression gate

- Capture and pin one known-good run or representative baseline set.
- Configure a local DProvenanceKit comparison and CI gate.
- Add up to three initial anomaly rules tied to the workflow's critical steps.
- Review one model, prompt, tool, configuration, or code change against the baseline.

### Evidence and handoff

- One reasoning-assurance report.
- One final review covering findings, blind spots, operational ownership, and recommended next steps.
- A practical handoff checklist so the team can continue recording and gating runs after the pilot.

## What is not included

- Access to a model's hidden chain-of-thought or private internal deliberation.
- A guarantee that every AI failure, hallucination, or factual error will be detected.
- Certification of legal, medical, financial, security, privacy, or regulatory compliance.
- Unlimited custom development, additional workflows, or multiple CI environments.
- A production uptime SLA for hosted services.
- A promise that the current hosted/team layer is a fully self-service SaaS product.

DProvenanceKit records and compares the observable, instrumented execution path: prompts, tool calls, retrieval and verification steps, decisions, outputs, and application-defined events.

## Delivery process

### Week 1 — Define and instrument

- Select one high-value workflow.
- Identify critical, structural, diagnostic, and telemetry events.
- Establish the integration and success criteria.

### Week 2 — Record and baseline

- Capture representative known-good behavior.
- Pin the golden baseline.
- Validate trace completeness and drop accounting.

### Week 3 — Gate and challenge

- Add the regression gate to CI.
- Configure anomaly rules.
- Exercise at least one deliberate or naturally occurring workflow change.

### Week 4 — Review and hand off

- Produce the reasoning-assurance report.
- Review blind spots and operational ownership.
- Recommend whether the next step is local-only use, commercial support, a hosted design partnership, or a private deployment engagement.

## After the pilot

There is no obligation to continue. Successful pilots may convert into one of the following:

- **Starter Support:** $250/month or $2,400/year.
- **Pro Assurance:** $1,500/month or $15,000/year.
- **Hosted/team design partnership:** manually provisioned early access while the self-service control plane is completed.
- **Enterprise, OEM, on-prem, or air-gapped engagement:** custom scope and pricing.

The Apache-2.0 Swift and Python libraries remain free for commercial and production use. Paid agreements cover implementation, support, managed workflows, private components, and operational assurances—not permission to use the open-source code.

## Apply

Open the [paid-pilot intake form](https://github.com/Therealdk8890/DProvenanceKit/issues/new?template=paid-pilot.yml) or email [therealdk8890+lineage@gmail.com](mailto:therealdk8890+lineage@gmail.com?subject=DProvenanceKit%20paid%20pilot%20inquiry) with:

- company or project name
- workflow to de-risk
- current AI stack
- repository and CI environment
- critical step that must not silently disappear
- preferred start window
