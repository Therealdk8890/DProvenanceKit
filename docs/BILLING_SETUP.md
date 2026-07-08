# Billing Setup

This document sets up the paid catalog without putting billing code or secrets in the public
Apache-2.0 repository.

Use Stripe Payment Links or hosted Checkout first. Do not add secret keys, webhook secrets, or
hosted-service code to this repo.

## Stripe Products

Create these products in Stripe:

| Product | Price | Billing | Lookup key |
| ------- | ----- | ------- | ---------- |
| DProvenanceKit Starter Support | $250/month | Recurring monthly | `dpk_starter_monthly` |
| DProvenanceKit Starter Support Annual | $2,400/year | Recurring annual | `dpk_starter_annual` |
| DProvenanceKit Pro Assurance | $1,500/month | Recurring monthly | `dpk_pro_monthly` |
| DProvenanceKit Pro Assurance Annual | $15,000/year | Recurring annual | `dpk_pro_annual` |
| DProvenanceKit Pilot | $1,500 | One-time | `dpk_pilot_once` |

Enterprise is quote/invoice only. Do not expose a public self-serve enterprise checkout.

## Product Descriptions

Starter Support:

> Commercial support for DProvenanceKit integration: onboarding, private email support, first
> integration review, and prioritized public bug triage. The Apache-2.0 library remains free.

Pro Assurance:

> Commercial assurance for AI reasoning workflows: Starter support plus CI gate design, trace
> vocabulary review, OTel/export review, and monthly reasoning-regression review.

Pilot:

> 30-day paid pilot for one AI workflow. Includes integration review and one reasoning assurance
> report.

## Required Metadata

`lookup_key` is a first-class field on the Stripe **Price**, not metadata — set it there (e.g.
`dpk_starter_monthly` from the product table) so you can fetch and swap prices by lookup key
without editing links or code. Do not also duplicate it into metadata; the two copies will drift.

Set the remaining keys as **product** (or Checkout Session) metadata:

```text
product_family=DProvenanceKit
license_scope=support_and_services
repo=Therealdk8890/DProvenanceKit
fulfillment=manual
apache_core_included=false
```

For customer-specific tracking, note that a **static Payment Link cannot carry arbitrary
per-buyer metadata**. Capture buyer context one of these ways instead:

- Append `?client_reference_id=<buyer-name>` to the Payment Link URL — it surfaces on the
  resulting Checkout Session and payment.
- Add **custom fields** to the Payment Link (Dashboard) to collect organization and workflow at
  checkout.
- For structured keys (`organization`, `github_issue`, `primary_workflow`), create a Checkout
  Session via the API with a restricted key (`rk_`) and set them in `metadata`. Keep that script
  and key **outside this public repo**.

## Fulfillment Checklist

After payment:

1. Confirm the customer and organization.
2. Create or update the commercial GitHub issue.
3. Send the onboarding email from `docs/SALES_PLAYBOOK.md`.
4. Schedule the first integration review.
5. Ask for a minimal representative trace workflow, not confidential client data.
6. Keep any private, hosted, on-prem, or custom add-ons outside this public repo.

## Public Links To Publish

Use Payment Links for self-serve Starter, Pro, and Pilot purchases:

```text
Starter monthly: https://buy.stripe.com/4gMeV7dUgcnNgVT6SGfYY04
Starter annual:  https://buy.stripe.com/bJeeV79E0gE3dJHdh4fYY03
Pro monthly:     https://buy.stripe.com/7sY7sF2byfzZgVT5OCfYY02
Pro annual:      https://buy.stripe.com/8x24gt4jG4Vl3534KyfYY01
Pilot:           https://buy.stripe.com/3cI5kx9E03Rh353el8fYY00
```

Do not commit live secret keys, webhook signing secrets, or customer-specific links.

## Preventing Secret Leaks

This rule is enforced, not just stated, because key exposure via a public repo is the top cause
of Stripe key compromise:

- **CI:** the `secret-scan` job in `.github/workflows/ci.yml` runs gitleaks on every push and PR
  and fails the build if a key pattern (`sk_`, `rk_`, `whsec_`, and others) lands in the tree.
- **Local:** `.pre-commit-config.yaml` runs the same gitleaks check before a commit is created.
  Contributors enable it once with `pre-commit install`.
- **GitHub:** turn on **Secret scanning + push protection** (Settings → Code security). On a
  public repo it is free and blocks a push that contains a recognized secret before it lands.

If a real key is ever committed, treat it as compromised: roll it immediately in the Stripe
Dashboard (API keys page), then check Workbench request logs for unrecognized activity.

## Invoicing

For Pro annual and Enterprise buyers, prefer invoice-first sales when procurement is involved.
Use Payment Links only for low-friction self-serve purchases.

## Boundary Rules

The open-source library remains free for production and commercial use. Billing covers support,
service, review, SLAs, and separately licensed private add-ons. It does not grant permission to
use the public code; users already have that permission under Apache 2.0.
