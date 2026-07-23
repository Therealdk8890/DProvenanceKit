# Billing Setup

This document defines the paid catalog without adding billing code or secrets to the public
Apache-2.0 repository.

Use the existing Stripe Payment Link only after the workflow, scope, and kickoff timing are
accepted in writing. Do not add secret keys, webhook secrets, customer data, or hosted-service
code to this repo.

## Stripe product

The only public self-serve product is the one-time assurance **Pilot**. There are no recurring
support subscriptions and no hosted, team, or enterprise SaaS tiers.

| Product | Price | Billing | Lookup key |
|---------|-------|---------|------------|
| DProvenanceKit Pilot | $1,500 | One time | `dpk_pilot_once` |

Additional integration, assurance, support, or training engagements are scoped and invoiced
individually. Do not publish a self-serve checkout for work without a defined fulfillment
scope.

## Product description

Use this description for the pilot:

> 30-day paid pilot for one AI workflow. Includes an integration review and one reasoning
> assurance report. The Apache-2.0 library remains free.

Billing covers services and customer-specific deliverables. The public Apache-2.0 code may
already be used, modified, embedded, and distributed subject to the license; payment does not
grant or expand those rights.

If a genuinely separate proprietary component is ever offered, define its scope and terms
outside this repository before selling it. No such component is part of the current catalog.

## Required metadata

`lookup_key` is a first-class field on the Stripe **Price**, not metadata. Set
`dpk_pilot_once` on the Price so a later checkout integration can retrieve the price without
hard-coding an object ID. Do not duplicate it into metadata.

Set the remaining keys as product or Checkout Session metadata:

```text
product_family=DProvenanceKit
engagement=assurance_pilot
repo=Therealdk8890/DProvenanceKit
fulfillment=manual
apache_core_included=false
```

A static Payment Link cannot carry arbitrary per-buyer metadata. Capture buyer context in one
of these ways:

- append `?client_reference_id=<buyer-reference>` to the Payment Link URL
- add Payment Link custom fields for organization and workflow
- if structured metadata becomes necessary, create Checkout Sessions through a private
  fulfillment system kept outside this public repository

Do not place restricted keys or customer identifiers in this repo.

## Fulfillment checklist

After payment:

1. Confirm the customer, organization, and preferred contact.
2. Create or update the private fulfillment record; do not put confidential details in a
   public GitHub issue.
3. Send the onboarding email from [SALES_PLAYBOOK.md](SALES_PLAYBOOK.md).
4. Schedule the integration review.
5. Confirm the single workflow, success test, and 30-day boundary in writing.
6. Ask for a synthetic or redacted good/bad example, not confidential client data.
7. Complete the integration review and deliver one written reasoning assurance report.
8. Record the closeout decision: continue internally, quote a new scope, or stop.

## Public link

Publish this link only for an accepted, defined pilot:

```text
Pilot: https://buy.stripe.com/3cI5kx9E03Rh353el8fYY00
```

Invoice separately scoped work only after both parties agree on its deliverables and price.
Do not commit live API keys, webhook signing secrets, or customer-specific payment links.

## Preventing secret leaks

- **CI:** the `secret-scan` job in `.github/workflows/ci.yml` runs gitleaks on every push and
  pull request.
- **Local:** `.pre-commit-config.yaml` runs the same check before a commit when contributors
  enable it with `pre-commit install`.
- **GitHub:** keep Secret scanning and push protection enabled in repository settings.

If a real key is ever committed, treat it as compromised, rotate it immediately in Stripe,
and review request logs for unrecognized activity.

## Boundary rules

- Everything in this public repository remains under Apache 2.0.
- The pilot price pays for the defined 30-day engagement and deliverables.
- Additional paid work is quoted per scope; no recurring tier is implied.
- DProvenanceKit currently offers no hosted service, SLA, indemnity, or compliance
  certification.
- A purchase is not required to use or ship the public library.
