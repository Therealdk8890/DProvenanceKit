# Commercial Offer

DProvenanceKit is free Apache-2.0 infrastructure for recording, querying, diffing, and
exporting reasoning traces. The commercial offer is hands-on assurance work around that
engine: review one risky AI workflow, define what must not silently change, and leave the
buyer with a concise evidence report and a recommended next gate.

## Positioning

**AI reasoning assurance for a workflow that cannot afford silent regressions.**

DProvenanceKit is strongest where a fluent wrong answer is worse than a crash:

- legal AI drafting and review workflows
- on-device Foundation Models applications
- agents that call tools, search, or retrieve evidence
- CI pipelines that must fail when a critical reasoning step disappears
- regulated workflows that need traceable, reviewable behavior

## First buyer

The best first buyer is a small team with one concrete accuracy or audit problem:

- a legal AI startup shipping drafts, summaries, or strategy suggestions
- a firm or legal-aid organization using AI internally but worried about review quality
- an Apple-platform AI team using Foundation Models, MLX, or Core ML
- an engineering team that needs Swift-native trace evidence in CI or an OTLP backend

Do not sell to a team that only wants general observability, a hosted dashboard, or an
undefined transformation project. The offer works when the buyer can name one workflow, one
known failure mode, and one decision the resulting evidence will support.

## Live paid offer

| Offer | Price | Scope | Promise |
|-------|-------|-------|---------|
| **30-day reasoning assurance pilot** | **$1,500 one time** | One AI workflow | Review the integration and deliver one reasoning assurance report. |

**[Request pilot fit →](https://github.com/Therealdk8890/DProvenanceKit/issues/new?labels=pilot&template=pilot.yml)**

After the workflow, scope, and kickoff timing are accepted in writing, use
[secure checkout](https://buy.stripe.com/3cI5kx9E03Rh353el8fYY00). For invoice-based
procurement, open a
[commercial inquiry](https://github.com/Therealdk8890/DProvenanceKit/issues/new?labels=commercial&template=commercial.yml)
instead.

## Pilot deliverables

The pilot owes exactly two deliverables:

1. **One integration review.** Within the accepted scope, the review may examine the selected
   workflow's instrumentation, trace vocabulary, one representative run, and one agreed
   failure scenario.
2. **One written reasoning assurance report.** The report contains findings, evidence gaps,
   limitations, a recommended next gate or implementation step, and a closeout recommendation.

A good pilot ends with a report that explains what was reviewed, whether the current
instrumentation exposes the agreed risk, what evidence is still missing, and what gate or
implementation step the buyer should consider next.

## Out of scope

The pilot does not include:

- hosted infrastructure or a managed team dashboard
- a broad app rewrite or open-ended custom development
- legal advice or review of the buyer's legal conclusions
- a compliance certification, SLA, indemnity, or security guarantee
- handling confidential client data during initial integration

Start with synthetic or redacted examples. Any expanded data-handling or customer-specific
work requires a separately agreed scope.

## Follow-on work

After a successful pilot, a buyer may request a separately quoted integration, assurance, or
training engagement. There are no published recurring support tiers and no automatic
subscription conversion. Quote only a deliverable the maintainer can define and fulfill.

Possible scopes include:

- implementation workshop
- CI regression-gate design or implementation
- trace-vocabulary and OpenTelemetry export review
- team training using synthetic or redacted examples

The Apache-2.0 library already permits commercial use, embedding, modification, and
distribution subject to the license. Services are not a paid license to public code.
A genuinely separate proprietary component, if one is ever created, would require its own
scope and terms outside this repository.

## Legal AI wedge

For legal workflows, use this concrete question:

> Before a draft leaves review, can the trace show which facts, documents, and reasoning
> steps supported it — and what rule should catch a missing critical support step?

The pilot can surface:

- missing evidence steps
- unsupported conclusions identified by an agreed rule
- changed reasoning paths after a model or OS update
- source-to-draft lineage
- reviewer notes tied to trace evidence

This is assurance tooling, not legal advice. The buyer remains responsible for the draft and
the review standard.

## 30-day sales sprint

1. Identify 25 qualified teams with one visible legal, regulated, or on-device AI workflow.
2. Ask for a 20-minute fit call, using the message in [SALES_PLAYBOOK.md](SALES_PLAYBOOK.md).
3. Target 10 calls and two paid pilots.
4. Keep the scope to one workflow and collect a redacted good/bad example before kickoff.
5. Turn each completed pilot into a buyer-approved case study or private reference when
   possible.
6. Use completed-pilot evidence to decide whether any repeatable follow-on offer deserves to
   exist. Do not invent recurring tiers before demand is proven.

## Proof to show buyers

Use concrete commands and artifacts, not broad claims:

```bash
swift build
swift test
swift run DProvenanceKitCLI evaluate --gate
swift run FoundationModelsRegressionDemo --gate
swift run --package-path ConformanceHarness
```

Use the output to show:

- the package and tests pass
- the corpus gate catches a known regression
- the Foundation Models demo catches a missing-tool or dropped-step regression
- conformance vectors reproduce deterministically

## Call to action

- **Ready to start:** complete the
  [pilot intake](https://github.com/Therealdk8890/DProvenanceKit/issues/new?labels=pilot&template=pilot.yml).
- **Accepted scope and kickoff timing:** pay for the $1,500 pilot through
  [secure checkout](https://buy.stripe.com/3cI5kx9E03Rh353el8fYY00).
- **Need an invoice or different scoped engagement:** open a
  [commercial inquiry](https://github.com/Therealdk8890/DProvenanceKit/issues/new?labels=commercial&template=commercial.yml)
  or use the email address in [COMMERCIAL.md](../COMMERCIAL.md).
