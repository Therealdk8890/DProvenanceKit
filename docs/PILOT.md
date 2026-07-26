# DProvenanceKit Reasoning Assurance Pilot

A fixed-scope, **$4,500 one-time, 30-day engagement** for a team that needs a clear view of
one AI workflow's current reasoning evidence and its most important blind spots.

## The offer

- **Price:** $4,500 USD, one time
- **Duration:** 30 days
- **Scope:** one AI or AI-assisted workflow
- **Delivered:** instrumentation review, golden baseline, 3–5 governance policies, CI
  regression gate, audit and provenance report, and two calls
- **You run the software:** your engineer installs and instruments (2–6 hours); the pilot
  supplies governance expertise and the audit record, not code in your repository
- **Data boundary:** local-first; synthetic or redacted examples are enough for the review

The public DProvenanceKit library remains free under Apache 2.0. The pilot price pays for the
review and report, not permission to use, modify, embed, or distribute the public code.

## Best fit

The pilot is designed for a small team that can name:

- one workflow where a silent reasoning change creates real risk
- one representative run
- one synthetic or redacted failure scenario
- one decision the assurance report should support

Good starting points include legal AI drafting or review, Apple Foundation Models apps,
tool-using assistants, retrieval/evidence workflows, and CI processes that need better
reasoning evidence.

It is not a fit for a team seeking a hosted observability platform, a broad application
rewrite, an undefined transformation project, or guaranteed detection of every AI failure.

## What is included

The pilot owes six deliverables.

### 1. Instrumentation review

A written assessment of the workflow's current observable execution path and instrumentation.
Depending on the accepted scope, it may cover:

- event vocabulary and priority choices
- trace coverage around the agreed failure risk
- one representative run and one synthetic or redacted failure scenario
- where evidence is missing, ambiguous, or too weak to support a reliable gate
- which steps' disappearance should page someone

### 2. Golden baseline

A validated reference run, committed to your repository, that future runs are compared
against.

### 3. Three to five governance policies

Authored for your workflow — structural divergence, required steps, claim support, allowed
models, or others agreed at kickoff — delivered as a ruleset with written rationale per rule.

### 4. CI deployment gate

A GitHub Actions or GitLab CI configuration that fails a pull request when reasoning regresses
against the baseline, and comments the diff explaining what changed.

### 5. Audit and provenance report

What the baseline established, which policies apply, what they would have caught, remaining
evidence gaps and limitations, and how to present that to an auditor or a customer.

The report does not certify correctness or compliance. It makes the current evidence boundary
explicit so you can make a better next decision.

### 6. Two calls

Kickoff and handover, plus written async support throughout, answered within two business
days.

## What is not included

- code written or debugged inside your repository, or a broad application rewrite
- hosted infrastructure, a managed dashboard, or a team SaaS product
- multiple workflows or open-ended custom development
- legal advice or review of legal conclusions
- an SLA, indemnity, security guarantee, or compliance certification
- access to hidden chain-of-thought or private model deliberation
- initial handling of confidential client data, secrets, or production trace payloads

DProvenanceKit evaluates the observable execution path that an application records. It cannot
prove facts or reasoning that were never captured.

## Purchase and delivery flow

1. Submit the
   [pilot intake](https://github.com/Therealdk8890/DProvenanceKit/issues/new?labels=pilot&template=pilot.yml)
   or email the commercial contact with a synthetic or redacted description.
2. Confirm the single workflow, review emphasis, written scope, and kickoff timing.
3. Mutually accept that scope and timing.
4. Pay through the
   an invoice issued after the scope is agreed in writing, or request an
   invoice if procurement requires one.
5. The 30-day engagement begins on the agreed kickoff date after payment.
6. Complete the review and deliver the reasoning assurance report.

Submitting the intake does not create a contract or payment obligation. Do not pay before the
workflow, scope, and kickoff timing are accepted in writing.

## After the pilot

There is no obligation to continue. A buyer can:

- use the Apache-2.0 library independently
- implement the report's recommendation internally
- request a separately quoted integration, gate-implementation, support, or training
  engagement
- stop

There are no published recurring support tiers, hosted/team service, SLA, indemnity, or
automatic subscription conversion.

## Request the pilot

Use the
[public pilot intake](https://github.com/Therealdk8890/DProvenanceKit/issues/new?labels=pilot&template=pilot.yml)
only for synthetic or redacted information. For anything sensitive, email
[therealdk8890+lineage@gmail.com](mailto:therealdk8890+lineage@gmail.com?subject=DProvenanceKit%20paid%20pilot%20inquiry)
and keep confidential details out of GitHub.
