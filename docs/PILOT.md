# DProvenanceKit Decision-Path Assurance Pilot

A fixed-scope, **$4,500 one-time, 30-day engagement** for a team that needs a clear view of
one AI workflow's current instrumented-path evidence and its most important blind spots.

## The offer

- **Price:** $4,500 USD, one time
- **Duration:** 30 days
- **Scope:** one AI or AI-assisted workflow
- **Delivered:** instrumentation / integration review, one decision-path assurance report,
  and two calls (kickoff + handover) with async written support
- **Not delivered in the pilot:** CI deployment gate implementation, committing a golden
  baseline, or authoring a live policy ruleset in your repository — those are separately
  scoped follow-on work
- **You run the software:** your engineer installs and instruments (2–6 hours); the pilot
  supplies governance expertise and the audit record, not code in your repository
- **Data boundary:** local-first; synthetic or redacted examples are enough for the review

The public DProvenanceKit library remains free under Apache 2.0. The pilot price pays for the
review and report, not permission to use, modify, embed, or distribute the public code.

## Best fit

The pilot is designed for a small team that can name:

- one workflow where a silent change to the instrumented decision path creates real risk
- one representative run
- one synthetic or redacted failure scenario
- one decision the assurance report should support

Good starting points include legal AI drafting or review, Apple Foundation Models apps,
tool-using assistants, retrieval/evidence workflows, and CI processes that need better
decision-path evidence.

It is not a fit for a team seeking a hosted observability platform, a broad application
rewrite, an undefined transformation project, or guaranteed detection of every AI failure.

## What is included

### 1. Instrumentation / integration review

A written assessment of the workflow's current observable execution path and instrumentation.
Depending on the accepted scope, it may cover:

- event vocabulary and priority choices
- trace coverage around the agreed failure risk
- one representative run and one synthetic or redacted failure scenario
- where evidence is missing, ambiguous, or too weak to support a reliable gate
- which steps' disappearance should page someone

### 2. Decision-path assurance report

What the current traces establish, remaining evidence gaps and limitations, recommended
golden-baseline shape, suggested governance policies (recommendations only), a recommended
CI gate approach, and how to present that to an auditor or a customer.

The report does not certify correctness or compliance. It makes the current evidence boundary
explicit so you can make a better next decision. It does **not** install a gate in your CI.

### 3. Two calls

Kickoff and handover, plus written async support throughout, answered within two business
days.

## What is not included

- CI deployment gate implementation in GitHub Actions / GitLab CI (available as follow-on)
- Committing a golden baseline or live policy ruleset into your repository (follow-on)
- code written or debugged inside your repository, or a broad application rewrite
- hosted infrastructure, a managed dashboard, or a team SaaS product
- multiple workflows or open-ended custom development
- legal advice or review of legal conclusions
- an SLA, indemnity, security guarantee, or compliance certification
- access to hidden chain-of-thought or private model deliberation
- initial handling of confidential client data, secrets, or production trace payloads

DProvenanceKit evaluates the observable execution path that an application records. It cannot
prove facts or decisions that were never captured.

## Purchase and delivery flow

1. Submit the
   [pilot intake](https://github.com/Therealdk8890/DProvenanceKit/issues/new?labels=pilot&template=pilot.yml)
   or email **danielpaulkissel@gmail.com** with a synthetic or redacted description.
2. Confirm the single workflow, review emphasis, written scope, and kickoff timing.
3. Mutually accept that scope and timing.
4. Pay through an invoice issued after the scope is agreed in writing, or request an
   invoice if procurement requires one.
5. The 30-day engagement begins on the agreed kickoff date after payment.
6. Complete the review and deliver the decision-path assurance report.

Submitting the intake does not create a contract or payment obligation. Do not pay before the
workflow, scope, and kickoff timing are accepted in writing.

## After the pilot

There is no obligation to continue. A buyer can:

- use the Apache-2.0 library independently
- implement the report's recommendation internally
- request a separately quoted CI gate implementation, baseline/policies commit, support, or
  training engagement
- stop

There are no published recurring support tiers, hosted/team service, SLA, indemnity, or
automatic subscription conversion.

## Request the pilot

Use the
[public pilot intake](https://github.com/Therealdk8890/DProvenanceKit/issues/new?labels=pilot&template=pilot.yml)
only for synthetic or redacted information. For anything sensitive, email
[danielpaulkissel@gmail.com](mailto:danielpaulkissel@gmail.com?subject=DProvenanceKit%20paid%20pilot%20inquiry)
and keep confidential details out of GitHub.
