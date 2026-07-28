# Sales Playbook

This is the lightweight process for selling the **$4,500 one-time, 30-day reasoning assurance
pilot**. DProvenanceKit's Apache-2.0 library remains free; the buyer pays for the defined
integration and assurance work.

The pilot is the way in. The recurring revenue is the **annual OEM / embed license** described
under [Expansion](#expansion-pilot--annual-oem-license). Sell the pilot; plan for the license.

## Offer in one sentence

DProvenanceKit helps a team prove when one AI workflow's reasoning changed, which steps
supported an output, and whether a silent regression should block release.

## Who this lands with

The sharpest version of this sale is a vendor whose **enterprise customer's security team
sends them a compliance questionnaire** asking, in effect: *how do we audit what your AI
actually did, and prove it wasn't tampered with, without your model or our data leaving our
environment?* When data legally cannot leave the device — PHI, attorney-client privilege,
classification, data residency — a cloud logging or audit service cannot answer that question,
and the vendor is stuck.

Lead with that questionnaire. Do not lead with cryptography, and do not use the phrase "AI
observability" — it is a commodity category and it invites a commodity comparison.

Prospect qualification for that motion lives in
[`go-to-market/oem-design-partner-kit.md`](../go-to-market/oem-design-partner-kit.md), which
defines the three hard filters and the 60-day kill test. Qualify against those filters *before*
pitching; a mis-qualified pitch burns the experiment's signal.

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

The default pilot is **$4,500 one time**, lasts 30 days, and covers one workflow.

Promise exactly six deliverables:

1. **Instrumentation review.** A written assessment of instrumentation, trace vocabulary,
   representative runs, and the agreed failure scenario.
2. **Golden baseline.** A validated reference run committed to their repository.
3. **Three to five governance policies** with written rationale per rule.
4. **CI deployment gate** that fails a PR on regression and comments the diff.
5. **Audit and provenance report** — findings, evidence gaps, limitations, and how to present
   it to an auditor or customer.
6. **Two calls** (kickoff, handover) plus async support answered within two business days.

Say this on every call: **they run the software.** Their engineer installs and instruments
(2–6 hours). You supply governance expertise, the policies, and the audit record — never code
inside their repo. That sentence is what keeps this a 15-hour engagement instead of a
40-hour one.

Out of scope:

- hosted infrastructure or managed dashboards
- broad application rewrites
- legal advice
- compliance certification, SLA, or indemnity
- confidential client data during the first integration pass

Checkout for an accepted pilot:

```text
[invoice issued after scope is agreed — the old $1,500 Stripe link is retired]
```

Do not request payment until the workflow, written scope, and kickoff timing are accepted.

## Onboarding email

Subject:

```text
DProvenanceKit pilot kickoff
```

Body:

```text
Thanks for starting a DProvenanceKit Governed AI Deployment Pilot.

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

Lead with the buyer's problem, not the library. The first sentence must contain a real detail
about *their* product — something you could only know by looking at it. Never send with a
bracketed placeholder still in the text.

### Primary — regulated, on-device vendor (the questionnaire wedge)

Subject:

```text
on-device AI audit trail for <Company>'s <regulated> customers
```

Body:

```text
Hi <name>,

You ship <specific AI feature> on-device in <Company> — which means when your enterprise
customer's security team asks "how do we audit what your AI actually did, and prove it wasn't
tampered with, without your model or our data leaving our environment?", a cloud logging
service isn't an answer you can give them.

DProvenanceKit is an Apache-2.0 Swift library that turns each AI run into a signed,
offline-verifiable record of the reasoning path — added, dropped, and reordered steps included
— and can fail CI when a model or OS update silently changes behavior. It runs inside your
process. Nothing leaves the device.

I run a 30-day pilot that gets it embedded and produces the audit record, and I license the
attestation to ship inside regulated products like yours. Worth 20 minutes to see whether your
questionnaires are asking for exactly this?

— Danny · github.com/Therealdk8890/DProvenanceKit
```

### Secondary — team running agents in or near production, not regulated

Use only when the prospect fails the on-device filter but has a real silent-regression problem.
These are outside the OEM experiment; do not let them consume the qualified-pitch budget.

Subject:

```text
the agent regression your output tests pass
```

Body:

```text
Hi <name>,

<specific detail about their agent or workflow>. The failure worth worrying about there is the
one where a model or prompt change makes the agent quietly stop calling a tool — the answer
still reads fine, the output assertions still pass, and it surfaces in production.

DProvenanceKit records the execution path itself and fails CI when the structure changes: a
tool dropped, a step reordered, a source path changed. Open source, runs entirely in your own
runner, no data leaves.

I run a $4,500, 30-day pilot on one workflow: golden baseline, three to five governance
policies, a CI gate, and an audit report. A synthetic or redacted example is enough to start.

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

**"Our reviewer already accepts our cloud audit log."**

Then they may not need this, and it is worth finding that out in the first ten minutes rather
than the third call. The distinction that matters is whether their reviewer needs the record to
be *verifiable by someone who does not trust the service that produced it* — a signed artifact
that checks out offline, against the exact bytes it describes — or whether an attested log from
a trusted vendor is sufficient. If it is sufficient, say so and disqualify.

**Log every instance of this answer.** It is the single most important signal in the pipeline:
if it recurs, the honest conclusion is that this is a feature rather than a business, and the
[kill test](../go-to-market/oem-design-partner-kit.md) has done its job.

## Expansion: pilot → annual OEM license

The pilot is a $4,500 one-time engagement. It does not, by itself, constitute a business. The
recurring line is an **annual OEM / embed license**: the right to ship DProvenanceKit's
attestation and role-bound proof pack inside the customer's own regulated product — on-prem,
air-gapped, or private build — together with a support retainer. Low five figures, scaled by
seats or deployments, priced per engagement, no public self-serve tier.

**When to raise it:** at handover, not at intake. The audit report is the proof; the license
conversation is what the proof earns. Raising it during the pilot sale adds a procurement
question to a decision that is currently small enough to be made by one person.

**The trigger to listen for:** the customer asks some version of *"can we give this artifact to
our customer / our auditor / our regulator?"* That is the moment the pilot deliverable stops
being an internal engineering artifact and starts being part of their product. Answer it with
the license.

**The boundary that must hold.** Everything in this repository is Apache 2.0, which already
permits commercial use, embedding, modification, and distribution subject to its terms. The
license does **not** sell permission to use public code the customer already has. It can only
cover a genuinely separate proprietary component, scoped, licensed, and delivered outside this
repository — or the support, assurance, and update commitments that surround the embed. No such
proprietary component exists today. Until one does, sell the retainer and the assurance work,
and say plainly that the library itself is free. See [COMMERCIAL.md](../COMMERCIAL.md).

## Close

Ask for one of three decisions:

- Accept the workflow, written scope, and kickoff timing, then start the **$4,500 pilot**
  through an invoice issued after the scope is agreed in writing.
- Request a written quote for a narrowly scoped integration, assurance, or training
  engagement.
- Decide the workflow is not a fit and stop.

At pilot handover, ask for a fourth: whether the attestation should ship inside their product
under an annual license. If the answer is no, ask what would have to be true for it to be yes,
and record the answer — that is the roadmap.
