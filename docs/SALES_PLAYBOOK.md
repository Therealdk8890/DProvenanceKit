# Sales Playbook

This is the lightweight process for turning interest in DProvenanceKit into paid support or an
assurance pilot.

## Offer In One Sentence

DProvenanceKit helps teams prove when an AI workflow's reasoning changed, which steps supported
an output, and whether a silent regression should block release.

## Qualification Questions

Ask these before quoting:

1. What AI workflow creates the most risk if it silently changes?
2. What output do you need to trust: legal draft, tool decision, summary, recommendation, or CI result?
3. Do you need local-only/private operation?
4. What model stack are you using: Apple Foundation Models, OpenAI, Anthropic, local models, or mixed?
5. Where should evidence show up: CI, a dashboard, a PDF/report, Langfuse, OTel collector, or code review?
6. How many developers or reviewers need support?
7. What would make a 30-day pilot obviously successful?

## Discovery Call Agenda

Use 30 minutes:

1. Confirm the workflow and risk.
2. Ask for one representative successful run and one known-bad or changed run.
3. Map the buyer's steps to trace event names and priorities.
4. Identify the first gate: missing critical step, changed order, unsupported conclusion, or changed source lineage.
5. Choose Starter, Pro, Pilot, or Enterprise.

## Pilot Scope

The default pilot is $1,500 for 30 days and covers one workflow.

Deliverables:

- trace vocabulary recommendation
- integration checklist
- one passing demo run
- one regression or missing-support gate
- one short reasoning assurance report
- conversion recommendation: continue, expand, or stop

Out of scope:

- custom hosted infrastructure
- broad app rewrites
- legal advice
- review of sensitive client data unless a separate agreement is in place

## Onboarding Email

Subject:

```text
DProvenanceKit pilot kickoff
```

Body:

```text
Thanks for starting a DProvenanceKit pilot.

To keep this tight, please send:

1. The workflow you want to de-risk.
2. The AI/model stack involved.
3. One example of a good output and one example of a bad or changed output.
4. Whether data must stay local.
5. Where you want the gate or report to live: CI, Langfuse/OTel, dashboard, or review artifact.

Please do not send confidential client data in email. A synthetic or redacted example is enough
for the first integration pass.
```

## Outreach Email

Subject:

```text
Catch silent AI regressions before they reach clients
```

Body:

```text
Hi <name>,

I am building DProvenanceKit, an open-source Swift library that records and diffs AI reasoning
paths. It is useful when the output still looks fluent but the model silently skipped a critical
step, changed its source path, or stopped calling a tool.

For legal and regulated AI workflows, I am offering a short paid pilot: we instrument one
workflow, define the reasoning steps that must not disappear, and produce a small assurance
report or CI gate.

Useful if you are using AI for drafts, summaries, review, or tool-using agents and need proof
of why an output was produced.

Would it be worth a 20-minute call to see if one workflow fits?
```

## Objection Handling

**"We already have logs."**
Logs show what happened. DProvenanceKit records the reasoning structure so you can diff why the
decision path changed.

**"We use Langfuse/OpenTelemetry already."**
Good. DProvenanceKit can be the on-device or Swift capture layer and export finished runs to
your existing OTLP backend.

**"We cannot send data to a hosted service."**
The public library runs locally. Commercial support can review integration patterns without
receiving confidential data.

**"Why pay if the library is free?"**
Because the paid product is support, assurance review, CI gate design, SLAs, and private
custom work. The Apache-2.0 core stays free.

## Close

Ask for one of three decisions:

- Start a $1,500 pilot for one workflow.
- Start Starter Support for integration help.
- Schedule a technical review for Enterprise/on-prem requirements.
