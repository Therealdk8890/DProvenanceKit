# Ecosystem Recognition & Integrations

This page records independently verifiable ecosystem listings and framework integrations for DProvenanceKit. It distinguishes upstream documentation listings, curated community directories, and project-maintained adapters. Inclusion is evidence of discoverability or technical integration—not endorsement, certification, or proof of production adoption.

## Upstream documentation listings

### LangChain

- **Listing:** DProvenanceKit appears in LangChain's provider directory.
- **Directory source:** [LangChain — All providers](https://github.com/langchain-ai/docs/blob/main/src/oss/python/integrations/providers/all_providers.mdx)
- **Integration page:** [DProvenanceKit for LangChain](https://dprovenance.dev/langchain/)
- **Directory description:** Reasoning observability and regression testing for agent runs.

### OpenAI Agents SDK

- **Listing:** DProvenanceKit appears in the SDK's official tracing documentation under **Ecosystem integrations → External tracing processors**.
- **Source:** [OpenAI Agents SDK — Tracing](https://openai.github.io/openai-agents-python/tracing/)
- **Integration implementation and usage:** [DProvenanceKit Python package](https://pypi.org/project/dprovenancekit/)

The OpenAI documentation explicitly states that listed integrations are maintained by their respective maintainers and that inclusion does not constitute OpenAI endorsement or security certification.

## Curated ecosystem directory

### OpenTelemetry ecosystem

- **Listing:** DProvenanceKit appears under **OpenTelemetry Instrumentation → GenAI / LLM Instrumentation** in the community-maintained Awesome OpenTelemetry directory.
- **Source:** [Awesome OpenTelemetry — README](https://github.com/magsther/awesome-opentelemetry/blob/main/readme.md)
- **Entry description:** The directory describes the Swift library, its zero-dependency DProvenanceOTel bridge, OTLP/JSON export, and GenAI semantic-convention mapping for Apple Foundation Models.

This is a third-party curated community directory, not the official OpenTelemetry Registry and not an endorsement by the OpenTelemetry project.

## Project-maintained framework integrations

The integrations below are maintained by the DProvenanceKit project. They are not presented as listings in the frameworks' own documentation directories.

### LlamaIndex

DProvenanceKit provides a Python callback-based adapter for LlamaIndex workflows. **LlamaIndex does not currently list DProvenanceKit in its documentation directory.**

- **Adapter guide:** [DProvenanceKit documentation](https://dprovenance.dev/docs/)
- **Package:** [DProvenanceKit on PyPI](https://pypi.org/project/dprovenancekit/)
- **Integration source:** [DProvenanceKitPython repository](https://github.com/Therealdk8890/DProvenanceKitPython)

The adapter records LlamaIndex callback events into DProvenanceKit traces, which can then be queried, compared, and used by the regression tooling. This is evidence of a project-maintained integration surface—not upstream LlamaIndex recognition or endorsement.

## What these references establish—and what they do not

These references establish that DProvenanceKit is discoverable through selected framework documentation and a community-curated ecosystem directory, and that the project maintains adapters for additional frameworks.

They do **not**, by themselves, establish:

- endorsement, sponsorship, certification, or security approval by any listed organization;
- production deployment, active usage, customer count, or commercial traction;
- correctness or completeness of any recorded AI reasoning;
- official OpenTelemetry Registry membership.

For technical capability and trust-boundary details, see the [README](../README.md), [technical overview](TECHNICAL_OVERVIEW.md), and [attestation threat model](ATTESTATION.md).

## Maintenance

When adding a new listing, record the exact public URL, the listing's owner/type, the date checked, and the precise scope of the claim. Keep upstream documentation, community-curated directories, package integrations, and endorsements as separate categories. Re-check links periodically; ecosystem directories and documentation can change independently of this repository.

---

**Project maintainer:** Daniel Paul Kissel
