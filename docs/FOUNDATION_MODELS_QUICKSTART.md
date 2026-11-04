# Foundation Models: developer quickstart

This guide is the fastest path for a Swift team evaluating DProvenanceKit with Apple's on-device Foundation Models framework.

## Requirements

- Swift 6
- An Apple SDK that includes `FoundationModels`
- iOS 26, macOS 26, or visionOS 26 at runtime for the live model path
- A supported device and an available on-device model; availability is checked by the example

The package itself declares lower deployment targets for its non-Foundation-Models functionality. The live Foundation Models APIs have their own platform availability requirements.

## Run the live integration

From the repository root:

```bash
swift run FoundationModelsLiveQuickstart
```

You can provide your own prompt:

```bash
swift run FoundationModelsLiveQuickstart -- "Summarize this note in one sentence."
```

The executable:

1. Creates a local SQLite trace store.
2. Starts a DPK run.
3. Checks Foundation Models availability.
4. Creates a `LanguageModelSession.traced` session.
5. Sends the prompt to Apple's on-device model.
6. Flushes and reads the recorded run.
7. Prints the trace events and SQLite file location.

The example is intentionally a command-line quickstart, not an application template. It demonstrates the actual SDK integration in one runnable place: [FoundationModelsLiveQuickstart.swift](../Sources/FoundationModelsLiveQuickstart/FoundationModelsLiveQuickstart.swift).

## See a regression gate

Run:

```bash
swift run FoundationModelsRegressionDemo --gate
```

This deterministic demo compares two captured Foundation Models transcripts. The baseline includes a live-data tool call; the candidate omits it while still producing a fluent answer. The alignment engine identifies the missing critical step and `--gate` returns a non-zero exit code.

This is a regression demonstration using transcript snapshots, not a claim that the live model will reproduce those exact outputs.

## Integrate into an app

Add the Swift package and the `DProvenanceKit` and `DProvenanceFoundationModels` products to your application target. Import:

```swift
import FoundationModels
import DProvenanceFoundationModels
```

For new sessions, the adapter exposes `LanguageModelSession.traced(...)`. For an existing session, post-hoc transcript ingestion is available through `session.recordProvenance()`. The adapter source documents the one-line entry points and their configuration:

- [Adapter overview and adoption entry points](../Sources/DProvenanceFoundationModels/DProvenanceFoundationModels.swift)
- [Traced session implementation](../Sources/DProvenanceFoundationModels/FM/TracedLanguageModelSession.swift)
- [Tracing configuration](../Sources/DProvenanceFoundationModels/FMTracingConfiguration.swift)

## Privacy and evidence boundaries

The SDK records events that the integration captures; it cannot prove that an uninstrumented event did not occur. Review the adapter's redaction configuration and the [attestation threat model](ATTESTATION.md) before recording sensitive prompts, responses, or tool data. A valid attestation protects the integrity of the recorded artifact; it does not prove that model output or source evidence is true, correct, safe, or compliant.

## Integration support

If your team is evaluating DPK in a real Foundation Models workflow, open an [integration discussion](https://github.com/Therealdk8890/DProvenanceKit/issues). We can help with the first integration at no charge. A public case study is optional and would only be published with your approval.
