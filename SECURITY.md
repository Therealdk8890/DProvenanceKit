# Security Policy

## Reporting a vulnerability

Please report suspected vulnerabilities privately rather than opening a public issue.
Use GitHub's [private vulnerability reporting](https://github.com/Therealdk8890/DProvenanceKit/security/advisories/new)
("Report a vulnerability" under the repository's **Security** tab). If that is
unavailable, email the maintainer listed in the repository profile.

Please include:
- affected version or commit,
- a description of the issue and its impact, and
- a minimal reproduction if you have one.

You can expect an acknowledgement within a few days. Please give a reasonable window
to release a fix before any public disclosure.

## Scope and where risk concentrates

DProvenanceKit is on-device-first: the core capture, storage, and query paths keep
data local. Two areas warrant extra attention when reviewing a report:

- **`DProvenanceOTel` (and `DProvenanceFoundationModelsOTel`)** — the only components
  that send data over the network, via OTLP/HTTP. Trace payloads leave the device when
  you configure an exporter, so misconfiguration or leakage here is the highest-impact
  surface. Redaction (`FMRedaction`, payload policies) is the intended control; report
  cases where redaction can be bypassed.
- **`SQLiteConnection` / `SQLiteTraceStore`** — untrusted trace payloads are stored and
  queried. All SQL is executed via prepared statements with bound parameters; report any
  path that interpolates untrusted input into SQL text.

## Supported versions

This is a pre-1.0 library; security fixes target the latest released version and `main`.
Pin a version and watch releases for security-relevant changes.
