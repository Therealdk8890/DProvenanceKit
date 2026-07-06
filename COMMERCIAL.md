# Commercial Support & Services

DProvenanceKit is free and open source under the **Apache License 2.0** — free for any
use, including production and commercial products, with no license fee and no usage
restrictions. See [LICENSE](LICENSE).

What's offered commercially is **not** a license to use the code — the code is already
free. It's the support, operational features, and assurances that teams running reasoning
observability in production tend to need.

## What's available

| Tier              | Best for                              | Annual pricing (USD)     | Includes |
|-------------------|---------------------------------------|--------------------------|----------|
| **Starter**       | Small teams, indie developers         | $2,400 – $6,000          | Email support, 1 named contact, prioritized bug fixes |
| **Pro**           | Growing AI startups and products      | $12,000 – $36,000        | Priority support, SLAs (99% uptime), managed OTel export pipeline (hosted trace sharing across machines & CI, regression gate), cross-machine lineage graph & analytics dashboard, up to 5 seats |
| **Enterprise**    | Large organizations, regulated industries | Custom (from $50,000)    | Dedicated support, custom features, on-prem/air-gapped deployment, audit logs, indemnity, SOC 2 / HIPAA-ready documentation, unlimited seats |

**Notes**

- Pricing is flexible and based on factors such as number of developers, event volume,
  deployment type (self-hosted vs. hosted), and contract length.
- Multi-year discounts and usage-based options are available.
- Paid tiers include access to private repositories for premium features and early access
  to new capabilities.
- The in-process OTel exporter (`DProvenanceOTel`, [docs/otel-bridge.md](docs/otel-bridge.md))
  is free and open source under Apache 2.0, like the rest of the library. The Pro tier's
  **managed OTel export pipeline** is the hosted layer on top — shared team traces, CI
  gates, monitoring — not the exporter itself.

**What's in the free library (not a paid feature):** the core recording, querying, and
diff/regression engine, **provenance/lineage** (record what each reasoning step was derived
from, then trace, diff, and export it), the **FoundationModels adapter**
(`DProvenanceFoundationModels`), and the **OpenTelemetry / OTLP exporter** (`DProvenanceOTel`)
that sends traces — lineage attributes included — to Langfuse, an OTel collector, or any OTLP
backend. On-device capture and getting your traces *out* to the tools you already run are free
by design — the paid tiers are the hosted, cross-machine, and support layers on top.

## How we decide free vs. paid

One line, applied consistently so the boundary never surprises a user or a contributor:

> **The library is free. The service is paid.**

- **Free, always** — anything that runs *in your process, on your machine*: capture, query,
  diff, regression detection, lineage recording, and exporting your traces to a backend
  *you* run. Paywalling these would only slow adoption, and adoption is the whole strategy in
  an empty niche.
- **Paid** — anything DProvenanceKit runs *for you, across machines*: hosted trace and lineage
  sharing, a managed CI regression gate, cross-run/cross-machine analytics dashboards,
  production monitoring, plus support, SLAs, indemnity, and compliance.

The test for any new feature: *does it deliver its value standalone, in the user's own
process?* If yes, it ships free and widens the top of the funnel. If its value only exists as
a hosted, multi-machine, or managed service, it belongs in a paid tier. A strong free library
makes the paid service **more** valuable, not less: the more teams capture and record locally,
the more they want it shared, gated in CI, and monitored in production.

## What a commercial agreement includes

- Professional support and SLAs
- Indemnification against IP claims
- Enterprise-only and hosted features: traces shared across machines and CI, a regression
  gate that fails a pull request when reasoning drifts, and production monitoring
- Priority bug fixes and feature requests
- Private Slack/Discord channel or email support
- Optional training and integration workshops

The library itself stays Apache 2.0 — these are services and add-ons layered on top, not a
gate on the open-source code.

## How to get in touch

1. Open a GitHub issue with the label **`commercial`**
   or email **DanielPaulKissel@gmail.com**

2. Provide the following information:
   - Company / Organization name
   - Approximate number of developers or users
   - Intended use case (internal tool, product, SaaS, etc.)
   - Expected scale (events per month, number of deployments)
   - Any specific requirements (compliance, on-prem, custom features)

We typically respond within 1–2 business days and can provide a custom quote quickly.

## Frequently Asked Questions

**Can I use DProvenanceKit for free in production?**
Yes. Under Apache 2.0 you may use it in production and in commercial products at no cost and
with no restrictions. Commercial agreements cover support, SLAs, indemnity, and
enterprise/hosted features — not permission to use the code.

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
