# Commercial Offer

DProvenanceKit is free infrastructure for recording, querying, diffing, and exporting
reasoning traces. The commercial product is the assurance layer around that engine: support,
review, managed workflows, and proof that an AI system's reasoning has not silently drifted.

## Positioning

**AI reasoning assurance for teams that cannot afford silent AI regressions.**

DProvenanceKit is strongest where a fluent wrong answer is worse than a crash:

- legal AI drafting and review workflows
- on-device Foundation Models applications
- agentic tools that call functions, search, or retrieve evidence
- CI pipelines that must fail when a reasoning path changes
- regulated teams that need traceable, explainable AI behavior

## Buyer

The first practical buyer is not a random individual user. It is a small team with a painful
accuracy or audit problem:

- a legal AI startup shipping drafts, summaries, or strategy suggestions
- a solo/small firm using AI internally but worried about review and privilege
- a legal aid or document-prep organization that needs cheap, repeatable quality control
- an Apple-platform AI app team using Foundation Models or Core ML
- an engineering team that wants OTel/Langfuse-compatible AI trace evidence

## Paid Packages

| Package | Price | Best For | Promise |
| ------- | ----- | -------- | ------- |
| Starter Support | $250/month or $2,400/year | Indie teams, small apps, early legal workflows | Get DProvenanceKit integrated correctly and avoid obvious tracing mistakes. |
| Pro Assurance | $1,500/month or $15,000/year | AI products with CI, review, or client-facing risk | Turn reasoning traces into repeatable gates, review artifacts, and operational confidence. |
| Enterprise Assurance | From $50,000/year | Regulated, on-prem, or procurement-heavy teams | Private support, custom integration, deployment review, security questionnaires, and contractual coverage. |

These prices sell service and assurance, not permission to use the Apache-2.0 code.

## Starter Support

Includes:

- one commercial support contact
- private email support
- first integration review
- prioritized public bug triage
- 60-minute onboarding call
- recommended trace vocabulary and priority model

Good success metric: the buyer can record representative runs, query for missing support steps,
and run `swift run DProvenanceKitCLI evaluate --gate` in CI.

## Pro Assurance

Includes Starter plus:

- CI regression-gate design
- trace vocabulary review for the buyer's production workflow
- monthly assurance review of failed gates and blind spots
- OTel/Langfuse export mapping review
- legal/regulated workflow evidence-report templates
- up to 5 named contacts
- 2-business-day support target

Good success metric: the buyer has a repeatable evidence trail showing why each output was
produced and a CI gate that fails when critical reasoning steps disappear.

## Enterprise Assurance

Includes Pro plus:

- custom contract, SOW, and procurement support
- security and architecture review
- on-prem or air-gapped deployment guidance
- custom private add-ons delivered outside this Apache repo
- support SLAs and escalation path
- optional indemnity and compliance documentation

Good success metric: the buyer can pass internal AI governance review with clear traceability,
audit, and operational ownership.

## Legal AI Wedge

For legal workflows, the sharp offer is:

> Before a draft leaves review, prove which facts, documents, and reasoning steps supported it.

Sell this as an audit artifact:

- missing evidence steps
- unsupported conclusions
- changed reasoning paths after a model or OS update
- source-to-draft lineage
- reviewer notes tied to trace evidence

This pairs naturally with CaseClarity-style local-first legal drafting: keep sensitive data
local, then export only the assurance artifact the user chooses to share.

## First 10-Customer Plan

1. Publish the offer from this file in the README, GitHub issue template, and outbound emails.
2. Offer 10 paid pilots at $1,500 for 30 days.
3. For each pilot, review one real workflow and produce one "reasoning assurance report".
4. Convert successful pilots to Pro Assurance at $1,500/month or annual $15,000.
5. Keep every reusable hosted, managed, or custom component outside this public Apache repo.

## Proof To Show Buyers

Use concrete commands, not claims:

```bash
swift build
swift test
swift run DProvenanceKitCLI evaluate --gate
swift run FoundationModelsRegressionDemo --gate
swift run --package-path ConformanceHarness
```

Use the output to show:

- tests pass
- corpus gate catches known regressions
- Foundation Models demo catches a silent tool/drop regression
- conformance vectors reproduce deterministically

## Call To Action

Open a GitHub issue using the commercial inquiry template or email the address in
`COMMERCIAL.md` with:

- organization name
- workflow to de-risk
- current AI stack
- expected event volume
- support or compliance requirements
