# Commercial Offer

DProvenanceKit is free Apache-2.0 infrastructure for recording, querying, diffing, and
exporting instrumented decision-path traces. The commercial offer is hands-on assurance work
around that engine: review one risky AI workflow, define what must not silently change, and
leave the buyer with a concise evidence report and a recommended next gate.

## Positioning

**AI decision-path assurance for a workflow that cannot afford silent regressions.**

DProvenanceKit is strongest where a fluent wrong answer is worse than a crash:

- legal AI drafting and review workflows
- on-device Foundation Models applications
- agents that call tools, search, or retrieve evidence
- CI pipelines that must fail when a critical instrumented step disappears
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
| **30-day Governed AI Deployment Pilot** | **$4,500 one time** | One AI workflow | Instrumentation / integration review + decision-path assurance report + two calls. CI gate implementation is separately scoped follow-on. |

**[Request pilot fit →](https://github.com/Therealdk8890/DProvenanceKit/issues/new?labels=pilot&template=pilot.yml)**

After the workflow, scope, and kickoff timing are accepted in writing, an invoice is issued —
50% on signature, 50% on delivery of the assurance report, net 15. For procurement questions,
open a
[commercial inquiry](https://github.com/Therealdk8890/DProvenanceKit/issues/new?labels=commercial&template=commercial.yml)
or email **inquiry@dprovenance.dev**.

## Pilot deliverables

The pilot owes three deliverables:

1. **Instrumentation / integration review.** Within the accepted scope, a written assessment
   of the workflow's instrumentation, trace vocabulary, representative runs, and the agreed
   failure scenario — flagging where instrumented steps are not captured and which steps'
   disappearance should page someone.
2. **Decision-path assurance report.** What current evidence establishes, remaining gaps,
   recommended golden-baseline shape, suggested governance policies (recommendations only),
   and a recommended CI gate approach for follow-on work.
3. **Two calls** — kickoff and handover — plus written async support answered within two
   business days.

**The buyer runs the software.** Their engineer installs the SDK and instruments the workflow
from the documented quickstart, typically two to six hours. The pilot supplies governance
expertise and the assurance record — never code written inside the buyer's repository.

A good pilot ends with a clear evidence boundary in writing and a concrete next step. It does
**not** end with a gate already running in the buyer's CI unless that was separately quoted.

## Out of scope

The pilot does not include:

- CI deployment gate implementation (quote as follow-on)
- committing a golden baseline or live policy ruleset into the buyer's repository
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
- golden baseline + policy ruleset commit
- trace-vocabulary and OpenTelemetry export review
- team training using synthetic or redacted examples

The Apache-2.0 library already permits commercial use, embedding, modification, and
distribution subject to the license. Services are not a paid license to public code.
A genuinely separate proprietary component, if one is ever created, would require its own
scope and terms outside this repository.

## Legal AI wedge

For legal workflows, use this concrete question:

> Before a draft leaves review, can the trace show which facts, documents, and instrumented
> steps supported it — and what rule should catch a missing critical support step?

The pilot can surface:

- missing evidence steps
- unsupported conclusions identified by an agreed rule
- changed instrumented paths after a model or OS update
- source-to-draft lineage
- reviewer notes tied to trace evidence

This is assurance tooling, not legal advice. The buyer remains responsible for the draft and
the review standard.

## 30-day sales sprint

1. Identify 25 qualified teams with one visible legal, regulated, or on-device AI workflow.
2. Ask for a 20-minute fit call, using the message in the internal sales playbook.
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
- **Accepted scope and kickoff timing:** pay for the $4,500 pilot through
  an invoice issued after the scope is agreed in writing.
- **Need an invoice or different scoped engagement:** open a
  [commercial inquiry](https://github.com/Therealdk8890/DProvenanceKit/issues/new?labels=commercial&template=commercial.yml)
  or email **[inquiry@dprovenance.dev](mailto:inquiry@dprovenance.dev)**.
