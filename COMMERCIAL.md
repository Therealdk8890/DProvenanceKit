# Commercial Support & Services

DProvenanceKit is free and open source under the **Apache License 2.0** — free for any
use, including production and commercial products, with no license fee and no usage
restrictions. See [LICENSE](LICENSE).

What's offered commercially is **not** a license to use the code — the code is already
free. It's the support, operational features, and assurances that teams running reasoning
observability in production tend to need.

---

## Start here

| I want to… | Do this |
|------------|---------|
| **Join the pilot** (free/discounted design partner) | [Open the pilot form →](https://github.com/Therealdk8890/DProvenanceKit/issues/new?labels=pilot&template=pilot.yml) |
| **Embed DPK in your own regulated app** (OEM / on-prem / private build) | Email **[therealdk8890+lineage@gmail.com](mailto:therealdk8890+lineage@gmail.com?subject=DProvenanceKit%20OEM%2Fembed%20licensing%20inquiry)** — the attestation and role-bound proof-pack, separately licensed to ship inside your product |
| **Ask about paid support or a scoped engagement** | Email **[therealdk8890+lineage@gmail.com](mailto:therealdk8890+lineage@gmail.com?subject=DProvenanceKit%20commercial%20inquiry)** or [open a `commercial` issue →](https://github.com/Therealdk8890/DProvenanceKit/issues/new?labels=commercial&template=commercial.yml) |
| **Just use the library** | It's free — `.package(url: "https://github.com/Therealdk8890/DProvenanceKit", from: "0.7.0")`. Nothing to sign. |

We typically respond within 1–2 business days.

---

## 🚀 Design partners & pilots (open now)

If you're shipping on-device or Swift AI and reasoning drift is a real risk for you, a
small number of **design partners** work directly with the maintainer — to get
DProvenanceKit wired into your app and CI, and to steer what ships next.

**What a design partner gets**

- A **direct line** to the maintainer (private channel) and priority on bug fixes.
- **Integration help** getting capture, lineage, and the regression gate into your app and CI.
- **Roadmap input** — partners' needs shape what gets built next.
- Optional: a logo / short case study once you're getting value (never required).

**What we ask in return**

- ~30 minutes of feedback every couple of weeks during the pilot.
- Permission to use anonymized learnings to improve the library.
- Honesty — including telling us what's missing or broken.

**Who it's for:** teams or solo developers shipping AI in **Apple Foundation Models, Swift
(MLX / Core ML / custom), or Python**, where an agent silently changing behavior after a
model/OS update would actually hurt.

**Slots are limited** so each partner gets real attention.
👉 **[Apply to the pilot](https://github.com/Therealdk8890/DProvenanceKit/issues/new?labels=pilot&template=pilot.yml)** (2-minute form) — or email
**[therealdk8890+lineage@gmail.com](mailto:therealdk8890+lineage@gmail.com?subject=DProvenanceKit%20pilot%20interest&body=Company%3A%0AWhat%20you're%20building%3A%0ATeam%20size%3A%0AWhat%20you'd%20want%20help%20with%3A%0A)** with what you're building.

> A design partnership trades your feedback for hands-on help. If you'd rather engage on a
> defined **paid scope** — an integration review or a 30-day assurance pilot for one workflow —
> say so in the same email and we'll scope it. Both are low-commitment ways in.

---

## What's available commercially

The library is Apache-2.0 and free. What's sold is narrow and honest — none of it is a
hosted service, and none of it gates the open-source code:

- **OEM / embed license.** Ship the local trace attestation and role-bound proof-pack
  **inside your own product** — on-prem, air-gapped, or a private build — under a commercial
  license (separate from Apache 2.0). This is the primary paid path, aimed at regulated
  Apple-native and Swift/Python ISVs that need provenance embedded in what *they* ship.
- **Paid support & scoped engagements.** Maintainer time, by inquiry: integration review,
  CI regression-gate design, trace-vocabulary / OTel export review, or a defined 30-day
  assurance pilot for one workflow. Priced per engagement, not as a subscription.
- **The D.P.K Mac app.** A separate paid product on the Mac App Store (see below) — the
  packaged desktop workbench over the same free engine.
- **Sponsorship.** [GitHub Sponsors](https://github.com/sponsors/Therealdk8890) and reduced
  rates for qualifying open-source / academic use.

There is **no hosted, cross-machine, or managed-SaaS tier**, and no SLA, indemnity, or
compliance-certification offering — a local-first library that runs entirely on your machine
is the whole point. Anything that would require running a service *for* you isn't on the menu.

**What's in the free library (not a paid feature):** the core recording, querying, and
diff/regression engine, **provenance/lineage** (record what each reasoning step was derived
from, then trace, diff, and export it), **local P-256 trace attestation and role-bound proof
packs** (including offline verification), the **FoundationModels adapter**
(`DProvenanceFoundationModels`), and the **OpenTelemetry / OTLP exporter**
(`DProvenanceOTel`) that sends traces — lineage attributes included — to Langfuse, an OTel
collector, or any OTLP backend. On-device capture, signing, verification, the local CI
regression gate, and getting your traces *out* to the tools you already run are all free by
design.

## How we decide free vs. paid

One line, applied consistently so the boundary never surprises a user or a contributor:

> **The library is free. The service is paid.**

Concretely, two categories:

- **Free, always — the open-source library.** Anything in the Apache-2.0 library that runs
  *in your process, on your machine*: capture, query, diff, regression detection, lineage
  recording, local trace attestation, proof-pack generation and offline verification, the
  local CI regression gate, and exporting your traces to a backend *you* run. Paywalling these
  would only slow adoption, and adoption is the whole strategy in an empty niche.
- **Paid — a commercial license to embed, plus maintainer time.** The right to ship the
  attestation and proof-pack **inside your own product** (on-prem / air-gapped / private
  build) under a commercial license — not Apache 2.0 — together with any bespoke premium
  components, which are delivered through private repositories and never merged into the
  public tree. Alongside that: paid support and scoped engagements (maintainer time). What you
  pay for is the license to embed and the work — not access to the code, which is already free.

The test for any new library feature: *does it deliver its value standalone, in the user's own
process?* If yes, it ships free in the Apache-2.0 library and widens the top of the funnel.
Anything meant to be sold as software you embed or run privately is built in a private
repository under a commercial license from the start, never committed to the open-source tree,
because an Apache-2.0 release is irrevocable. A strong free library makes the paid offering
**more** valuable, not less: the more teams capture and record locally, the more of them need
it embedded, supported, and shipped inside regulated products.

## Where the Mac app and the web Explorer fit

Two visualization surfaces sit on opposite sides of the line, and the difference is worth
stating plainly so it never reads as inconsistent:

- **The web Explorer — free.** [WebVisualizer](WebVisualizer/) is an Apache-2.0,
  zero-backend viewer that renders **one** pre-computed diff artifact (a `WebDiffExport` the
  free CLI produces). It's a shareable, zero-install preview and a reference renderer for
  anyone embedding the schema. It is deliberately capped at a single artifact — never a live
  or multi-run data source — see [WebVisualizer/SCOPE.md](WebVisualizer/SCOPE.md).
- **The D.P.K Mac app — paid.** [*D.P.K: Reasoning Traces*](https://apps.apple.com/us/app/d-p-k-reasoning-traces/id6784076039?mt=12)
  is a native application built **on top of** the free library, sold on the Mac App Store. It
  opens your **live** trace database and gives you the interactive workbench: diff any two runs
  you choose, replay timelines event by event, drill into payloads and span lineage, and
  surface anomalies across every loaded run.

This does **not** contradict "the library is free." The free-vs-paid test governs what ships
*in the Apache-2.0 library* — it asks whether a *library feature* delivers its value in your
process. It does not say every program that happens to run locally must be free. A polished
native application is a distinct downstream **product**, the same way an open-source engine can
have a paid GUI: the recording, querying, diffing, and alignment engine the app runs is the
free library; what you pay for is the packaged, interactive desktop experience on top of it. If
you'd rather not buy the app, the same engine is yours for free — build your own front end, use
the CLI, or preview single diffs in the Explorer.

## What a commercial engagement includes

- Professional support, scoped per engagement (no fixed-SLA promises a solo maintainer can't keep)
- An **OEM / embed commercial license** to ship the attestation and proof-pack inside your product
- Priority bug fixes and feature requests
- A private channel or email support
- Optional training and integration workshops

The library itself stays Apache 2.0 — these are a license to embed plus services layered on
top, not a gate on the open-source code.

## How to get in touch

**Fastest — use a form/link:**

- **Pilot:** [github.com/Therealdk8890/DProvenanceKit → new pilot issue](https://github.com/Therealdk8890/DProvenanceKit/issues/new?labels=pilot&template=pilot.yml)
- **Commercial / OEM licensing / support:** [new `commercial` issue](https://github.com/Therealdk8890/DProvenanceKit/issues/new?labels=commercial&template=commercial.yml)
  or email **[therealdk8890+lineage@gmail.com](mailto:therealdk8890+lineage@gmail.com?subject=DProvenanceKit%20commercial%20inquiry)**

**When you reach out, it helps to include:**

- Company / Organization name
- Approximate number of developers or users
- Intended use case (internal tool, product, SaaS, etc.)
- Expected scale (events per month, number of deployments)
- Any specific requirements (compliance, on-prem, custom features)

We typically respond within 1–2 business days and can provide a custom quote quickly.

## Frequently Asked Questions

**Can I use DProvenanceKit for free in production?**
Yes. Under Apache 2.0 you may use it in production and in commercial products at no cost and
with no restrictions. Commercial agreements cover support, scoped engagements, and an
OEM/embed license to ship it inside your own product — not permission to use the code.

**What does a pilot cost?**
Design-partner pilots are free or discounted for the pilot term. In exchange we ask for
feedback and permission to learn from anonymized usage. Standard rates apply after the pilot
if you convert to a paid tier — with no obligation to.

**Do you offer sponsorship or open-source support?**
Yes — we welcome GitHub Sponsors and can discuss reduced rates for qualifying open-source
projects or academic use.

**Can I contribute code and still buy support?**
Absolutely. Contributors are encouraged, and we offer favorable terms to active community
members.

---

**Questions?**
Feel free to reach out via GitHub or email. We're happy to discuss how DProvenanceKit can
support your AI observability needs.

*Last updated: July 2026*
