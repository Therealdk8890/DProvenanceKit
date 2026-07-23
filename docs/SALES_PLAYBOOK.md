# Sales Playbook

This is the lightweight process for selling the **$1,500 one-time, 30-day reasoning assurance
pilot**. DProvenanceKit's Apache-2.0 library remains free; the buyer pays for the defined
integration and assurance work.

## Offer in one sentence

DProvenanceKit helps a team prove when one AI workflow's reasoning changed, which steps
supported an output, and whether a silent regression should block release.

## Qualification questions

Ask these before recommending the pilot:

1. What AI workflow creates the most risk if it silently changes?
2. What output must be trusted: a legal draft, tool decision, summary, recommendation, or CI
   result?
3. Can you provide one representative good run and one synthetic or redacted bad/changed run?
4. Must the data remain local?
5. What model stack is involved: Apple Foundation Models, OpenAI, Anthropic, local models, or
   mixed?
6. Where should evidence land: CI, an OTLP backend, a report, or code review?
7. What would make a 30-day pilot obviously successful?

If the buyer cannot name a workflow, a failure mode, and a success test, do not force the
pilot. Offer a short scoping conversation or call it no fit.

## Discovery call agenda

Use 30 minutes:

1. Confirm the workflow and the business risk.
2. Review one representative successful run and one known-bad or changed run.
3. Map the workflow to trace event names and priorities.
4. Identify the first gate: missing critical step, changed order, unsupported conclusion, or
   changed source lineage.
5. Choose one outcome: start the paid pilot, request a separately scoped engagement, or stop.

## Pilot scope

The default pilot is **$1,500 one time**, lasts 30 days, and covers one workflow.

Deliverables:

- integration review and instrumentation findings
- trace vocabulary recommendation
- review of one representative run and one agreed failure scenario
- one short reasoning assurance report with evidence gaps and a recommended next gate
- closeout recommendation: continue internally, scope follow-on work, or stop

Out of scope:

- hosted infrastructure or managed dashboards
- broad application rewrites
- legal advice
- compliance certification, SLA, or indemnity
- confidential client data during the first integration pass

Checkout for an accepted pilot:

```text
https://buy.stripe.com/3cI5kx9E03Rh353el8fYY00
```

Do not request payment until the workflow, written scope, and kickoff timing are accepted.

## Onboarding email

Subject:

```text
DProvenanceKit pilot kickoff
```

Body:

```text
Thanks for starting a DProvenanceKit reasoning assurance pilot.

To keep the 30-day scope tight, please send:

1. The one workflow you want to de-risk.
2. The AI/model stack involved.
3. One example of a good output and one example of a bad or changed output.
4. Whether data must stay local.
5. Where you want the report, and any future gate, to live: CI, OTLP backend, local report, or code review.
6. The decision that will tell us the pilot succeeded.

Please do not send confidential client data by email. A synthetic or redacted example is
enough for the first integration pass.
```

## Outreach email

Subject:

```text
Catch silent AI regressions before they reach clients
```

Body:

```text
Hi <name>,

I build DProvenanceKit, an open-source Swift library that records and diffs AI reasoning
paths. It is useful when an output still looks fluent but the model silently skipped a
critical step, changed its source path, or stopped calling a tool.

I am offering a $1,500, 30-day assurance pilot for one workflow. We review the integration,
examine one agreed failure risk, and deliver a short assurance report covering the evidence
gaps and recommended next gate. The workflow can stay local, and a synthetic or redacted
example is enough to start.

Would a 20-minute fit call be useful?
```

## Objection handling

**"We already have logs."**

Logs show what happened. DProvenanceKit records a structured reasoning path so the team can
diff why that path changed and enforce an agreed gate.

**"We already use Langfuse or OpenTelemetry."**

Good. DProvenanceKit can be the Swift or on-device capture layer and export completed runs to
the OTLP backend the buyer already operates.

**"We cannot send data to a hosted service."**

DProvenanceKit does not operate a hosted service. The library runs locally, and the pilot can
work from synthetic or redacted examples while the buyer keeps sensitive traces in its own
environment.

**"Why pay if the library is free?"**

The library is free, including commercial embedding subject to Apache 2.0. The pilot buys a
defined integration review and assurance report — work and deliverables, not permission to
use the code. Implementing a recommended gate is separately scoped follow-on work.

**"Can you guarantee compliance or accuracy?"**

No. The pilot reviews trace evidence against an agreed failure risk. It does not replace
domain review, legal judgment, security review, or compliance certification.

## Close

Ask for one of three decisions:

- Accept the workflow, written scope, and kickoff timing, then start the **$1,500 pilot**
  through [secure checkout](https://buy.stripe.com/3cI5kx9E03Rh353el8fYY00).
- Request a written quote for a narrowly scoped integration, assurance, or training
  engagement.
- Decide the workflow is not a fit and stop.
