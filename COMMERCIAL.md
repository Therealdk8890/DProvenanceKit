# Commercial Support & Services

DProvenanceKit is free and open source under the **Apache License 2.0**. Subject to its
terms, you may use, modify, embed, and distribute the public code in production and commercial
products without paying a license fee. See [LICENSE](LICENSE).

The paid offer is deliberately separate from that license grant: you pay for a defined
assurance engagement, maintainer time, and customer-specific deliverables — never for
permission to use the public library.

## Start here

| I want to… | Do this |
|------------|---------|
| **Govern one AI workflow in 30 days** | Complete the [pilot intake →](https://github.com/Therealdk8890/DProvenanceKit/issues/new?labels=pilot&template=pilot.yml). After the workflow, scope, and kickoff timing are accepted in writing, an invoice is issued for **$4,500 one time** (50% on signature, 50% on delivery) |
| **Scope integration help or a workshop** | Email **[therealdk8890+lineage@gmail.com](mailto:therealdk8890+lineage@gmail.com?subject=DProvenanceKit%20scoped%20support%20inquiry)** or [open a commercial inquiry →](https://github.com/Therealdk8890/DProvenanceKit/issues/new?labels=commercial&template=commercial.yml) |
| **Use the library in my product** | It is already free under Apache 2.0 — `.package(url: "https://github.com/Therealdk8890/DProvenanceKit", from: "0.7.0")`. Nothing to buy; follow the license terms. |
| **Use the native Mac workbench** | [Download D.P.K: Reasoning Traces →](https://apps.apple.com/us/app/d-p-k-reasoning-traces/id6784076039?mt=12). Basic is currently free; see the app section below for Pro availability. |

Kickoff timing is confirmed in writing after the workflow and scope are accepted.

## The live paid offer

### Governed AI Deployment Pilot — $4,500 one time

The pilot covers **one AI workflow** with one clear failure risk. It is built for a small
team shipping legal, regulated, on-device, or tool-using AI where a fluent-but-wrong result
is more dangerous than a crash.

It runs for 30 days and produces six deliverables:

1. **Instrumentation review.** A written assessment of your recorded traces, flagging gaps
   where reasoning steps are not captured, and identifying the steps whose disappearance
   should page someone.
2. **Golden baseline.** A validated reference run that future runs are compared against,
   committed to your repository.
3. **Three to five governance policies** authored for your workflow — structural divergence,
   required steps, claim support, allowed models, or others agreed at kickoff — delivered as
   a ruleset with written rationale for each rule.
4. **CI deployment gate.** A GitHub Actions or GitLab CI configuration that fails a pull
   request when reasoning regresses against the baseline, and comments the diff explaining
   what changed.
5. **Audit and provenance report.** What the baseline established, which policies apply, what
   they would have caught, and how to present that to an auditor or a customer.
6. **Two calls** — kickoff and handover — plus written async support throughout, answered
   within two business days.

**You run the software.** Your engineer installs the SDK and instruments the workflow
following the documented quickstart, typically two to six hours. The pilot supplies
governance expertise, the policies, and the audit record — not code written inside your
repository.

The pilot does **not** include code written or debugged in your repository, hosted
infrastructure, a broad application rewrite, on-call or incident support, legal advice, a
compliance certification, an SLA, or indemnity. Sensitive customer data should stay local; a
synthetic or redacted example is enough for the first pass.

**[Request the pilot →](https://github.com/Therealdk8890/DProvenanceKit/issues/new?labels=pilot&template=pilot.yml)**

After fit, scope, and kickoff timing are accepted in writing, an invoice is issued — 50% on
signature, 50% on delivery of the audit report, net 15. For procurement questions use the
[commercial inquiry](https://github.com/Therealdk8890/DProvenanceKit/issues/new?labels=commercial&template=commercial.yml)
or email the address above.

*Design partner rate: **$4,500 reduced from the standard $7,500**, for the first three
customers, in exchange for a written testimonial and a case study published with your
approval and any anonymisation you require.*

## Other paid work

Scoped support is available by quote when a pilot is not the right shape:

- integration reviews and implementation workshops
- CI regression-gate design or implementation
- trace-vocabulary and OpenTelemetry export reviews
- team training using synthetic or redacted examples

There are currently **no recurring support tiers, hosted/team service, managed SaaS,
fixed-response SLA, indemnity, or compliance-certification package**. Customer-specific or
confidential work is kept outside this public repository.

## What remains free

The public Apache-2.0 library includes:

- recording, querying, structural diffing, and regression detection
- provenance and source lineage
- local P-256 trace attestation and role-bound proof packs
- offline verification and the local CI regression gate
- the Foundation Models adapter (`DProvenanceFoundationModels`)
- the OpenTelemetry / OTLP exporter (`DProvenanceOTel`)
- export to a backend you choose and operate

These capabilities are not paid features and are not unlocked by purchasing a pilot.

## The licensing boundary

> **The library is free. The service is paid.**

Everything committed to this repository is distributed under Apache 2.0. That license already
allows commercial use, embedding, modification, and distribution subject to its terms.
DProvenanceKit does not sell an “OEM right” to public code the customer already has.

If a genuinely separate proprietary component is created in the future, it must be scoped,
licensed, and delivered outside this repository. It cannot be a relabeling of code already
released here. No such component is part of the current public offer.

## Where the Mac app and web Explorer fit

- **The web Explorer is free.** [WebVisualizer](WebVisualizer/) is an Apache-2.0,
  zero-backend viewer for one pre-computed `WebDiffExport`. It is a shareable preview and
  reference renderer, not a live data service.
- **The D.P.K Mac app currently has a free Basic experience.**
  [D.P.K: Reasoning Traces](https://apps.apple.com/us/app/d-p-k-reasoning-traces/id6784076039?mt=12)
  is the native workbench over a live local trace database. As of July 2026, an optional
  **$99/year Pro Annual** subscription is planned but not publicly purchasable. Its metadata,
  submission with D.P.K 1.3.0, and Apple review still remain. Check the App Store listing for
  current availability.

The app and Explorer both use the free engine. Neither changes the Apache-2.0 rights granted
for this repository.

## Frequently asked questions

### Can I use DProvenanceKit for free in a commercial product?

Yes. Follow the Apache 2.0 terms; no separate commercial agreement or payment is required.

### What does the pilot cost?

**$4,500 one time** for 30 days and one workflow, invoiced 50% on signature and 50% on
delivery. The standard rate is $7,500; $4,500 is the design-partner rate for the first three
customers. This page and the [commercial offer](docs/COMMERCIAL_OFFER.md) define the same
scope.

Regulated workflows requiring a compliance export are quoted separately.

### Why is it not self-serve checkout?

At this scope the workflow, policies, and success criteria have to be agreed in writing
before work starts, or neither of us knows what "done" means. Intake first, then an invoice.

### Is there a free design-partner pilot?

No. Design partners pay the reduced rate rather than nothing — a paying customer tells you
the truth about whether the work was worth it, and a free one does not. You can evaluate the
library itself for free, indefinitely.

### Do you operate a hosted service?

No. The current library and engagement are local-first. You decide whether to export traces
to infrastructure you operate or already use.

### Can I contribute code and still buy support?

Yes. Contributions and paid services are independent.

---

Questions? Open a
[commercial inquiry](https://github.com/Therealdk8890/DProvenanceKit/issues/new?labels=commercial&template=commercial.yml)
or email **[therealdk8890+lineage@gmail.com](mailto:therealdk8890+lineage@gmail.com)**.

*Last updated: July 2026*
