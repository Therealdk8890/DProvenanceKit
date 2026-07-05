#if canImport(FoundationModels)
import Foundation
import FoundationModels

/// Capture mode 1: post-hoc, zero refactor. Bridges a transcript to the
/// neutral snapshot and records it via FMSnapshotIngestion.
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
public enum FMTranscriptIngestion {
    @discardableResult
    public static func ingest(
        _ transcript: Transcript,
        configuration: FMTracingConfiguration = .default,
        startingAt entryIndex: Int = 0
    ) -> FMIngestionSummary {
        let bridged = FMTranscriptBridge.bridge(transcript)
        return FMSnapshotIngestion.record(
            bridged.snapshot,
            configuration: configuration,
            startingAt: entryIndex,
            skippedSegmentCount: bridged.skippedSegmentCount
        )
    }
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
extension Transcript {
    @discardableResult
    public func recordProvenance(
        configuration: FMTracingConfiguration = .default,
        startingAt entryIndex: Int = 0
    ) -> FMIngestionSummary {
        FMTranscriptIngestion.ingest(self, configuration: configuration, startingAt: entryIndex)
    }
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
extension LanguageModelSession {
    /// THE zero-refactor one-liner: `session.recordProvenance()` after any
    /// existing FoundationModels code. Stateless: calling it twice
    /// double-records — pass `startingAt` (the previous summary's
    /// `nextEntryIndex`) or use `TracedLanguageModelSession`, whose
    /// `recordProvenance()` dedupes.
    @discardableResult
    public func recordProvenance(
        configuration: FMTracingConfiguration = .default,
        startingAt entryIndex: Int = 0
    ) -> FMIngestionSummary {
        FMTranscriptIngestion.ingest(transcript, configuration: configuration, startingAt: entryIndex)
    }

    /// THE greenfield one-liner:
    /// `LanguageModelSession.traced(instructions: "Be terse.")`.
    public static func traced(
        model: SystemLanguageModel = .default,
        tools: [any Tool] = [],
        instructions: String? = nil,
        configuration: FMTracingConfiguration = .default
    ) -> TracedLanguageModelSession {
        TracedLanguageModelSession(
            model: model, tools: tools, instructions: instructions, configuration: configuration
        )
    }
}
#endif
