# Billing Setup

This document sets up the paid catalog without putting billing code or secrets in the public
Apache-2.0 repository.

Use Stripe Payment Links or hosted Checkout first. Do not add secret keys, webhook secrets, or
hosted-service code to this repo.

## Stripe Products

The only self-serve product is the one-time assurance **Pilot**. There are no recurring
"Starter/Pro" support subscriptions and no hosted/enterprise SaaS tiers — those were removed;
a local-first library that runs entirely on the user's machine has no service to bill for.
OEM/embed licensing and paid support engagements are **quote/invoice by inquiry**, not self-serve.

| Product | Price | Billing | Lookup key |
| ------- | ----- | ------- | ---------- |
| DProvenanceKit Pilot | $1,500 | One-time | `dpk_pilot_once` |

OEM / embed licensing and scoped support engagements are invoice-only. Do not expose a public
self-serve enterprise or subscription checkout.

## Product Descriptions

Pilot (the one self-serve product):

> 30-day paid pilot for one AI workflow. Includes integration review and one reasoning assurance
> report. The Apache-2.0 library remains free.

Everything else is invoice-only, scoped per engagement:

> **OEM / embed license** — the right to ship the local attestation and role-bound proof-pack
> inside your own product (on-prem / air-gapped / private build), under a commercial license
> separate from Apache 2.0.
>
> **Support & integration engagements** — maintainer time: integration review, CI regression-gate
> design, trace-vocabulary / OTel export review. Priced per engagement.

## Required Metadata

`lookup_key` is a first-class field on the Stripe **Price**, not metadata — set it there (e.g.
`dpk_pilot_once` from the product table) so you can fetch and swap prices by lookup key
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

Use a Payment Link only for the self-serve Pilot. (The retired Starter/Pro subscription links
point at products that are no longer offered — archive those products in the Stripe Dashboard.)

```text
Pilot: https://buy.stripe.com/3cI5kx9E03Rh353el8fYY00
```

OEM/embed licensing and support engagements are handled by invoice, not a public link. Do not
commit live secret keys, webhook signing secrets, or customer-specific links.

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

For OEM/embed licenses and support engagements, prefer invoice-first sales when procurement is
involved. Use the Payment Link only for the low-friction self-serve Pilot.

## Boundary Rules

The open-source library remains free for production and commercial use. Billing covers support,
scoped engagements, and a separately licensed OEM/embed right to ship the library inside your own
product. It does not grant permission to use the public code; users already have that permission
under Apache 2.0.
