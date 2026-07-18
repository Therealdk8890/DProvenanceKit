// Outer compiler gate: keeps Swift 6.0/6.1 consumer builds from parsing this file's
// FM-session surface — see TracedLanguageModelSession.swift and issue #57.
#if compiler(>=6.2)
#if canImport(FoundationModels)
import Foundation
import FoundationModels

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
extension FMTranscriptSnapshot {
    /// `Transcript` IS the collection of entries (there is no `.entries`
    /// property in the SDK).
    public init(_ transcript: Transcript) {
        self.init(entries: transcript)
    }

    /// For entry slices, e.g. `Response.transcriptEntries`.
    public init(entries: some Sequence<Transcript.Entry>) {
        self = FMTranscriptBridge.bridge(entries).snapshot
    }
}

/// Pure Transcript-to-IR conversion. Segment text uses the verified pattern:
/// `.text` yields the segment content, `.structure` yields
/// `content.jsonString`; non-text segment kinds (attachment, custom, unknown)
/// are skipped and counted so ingestion summaries can surface data loss.
/// Reasoning and unknown Entry kinds map to `.unknown(description:)` via the
/// entry's CustomStringConvertible.
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
enum FMTranscriptBridge {
    struct Result {
        let snapshot: FMTranscriptSnapshot
        let skippedSegmentCount: Int
    }

    static func bridge(_ entries: some Sequence<Transcript.Entry>) -> Result {
        var skipped = 0
        var out: [FMTranscriptSnapshot.Entry] = []
        for entry in entries {
            switch entry {
            case .instructions(let instructions):
                let definitions = instructions.toolDefinitions
                out.append(.instructions(
                    text: text(from: instructions.segments, skipped: &skipped),
                    toolNames: definitions.map(\.name),
                    toolDescriptions: Dictionary(
                        definitions.map { ($0.name, $0.description) },
                        uniquingKeysWith: { first, _ in first }
                    )
                ))
            case .prompt(let prompt):
                out.append(.prompt(
                    text: text(from: prompt.segments, skipped: &skipped),
                    options: FMGenerationOptionsSnapshot(bridging: prompt.options),
                    responseFormatName: prompt.responseFormat?.name
                ))
            case .toolCalls(let calls):
                out.append(.toolCalls(calls.map {
                    FMTranscriptSnapshot.Call(toolName: $0.toolName, argumentsJSON: $0.arguments.jsonString)
                }))
            case .toolOutput(let output):
                out.append(.toolOutput(
                    toolName: output.toolName,
                    text: text(from: output.segments, skipped: &skipped)
                ))
            case .response(let response):
                out.append(.response(
                    text: text(from: response.segments, skipped: &skipped),
                    assetIDCount: response.assetIDs.count
                ))
            #if canImport(FoundationModels, _version: 2.0)
            // The OS 27 SDK (FoundationModels 2.0) adds .reasoning; older
            // SDKs can't name it, so it's compiled in conditionally and
            // routes like unknown kinds — 26.x-SDK builds reach the same
            // .unknown mapping via @unknown default at runtime.
            case .reasoning:
                out.append(.unknown(description: String(describing: entry)))
            #endif
            @unknown default:
                out.append(.unknown(description: String(describing: entry)))
            }
        }
        return Result(snapshot: FMTranscriptSnapshot(entries: out), skippedSegmentCount: skipped)
    }

    static func text(from segments: [Transcript.Segment], skipped: inout Int) -> String {
        segments.compactMap { segment -> String? in
            switch segment {
            case .text(let textSegment): return textSegment.content
            case .structure(let structuredSegment): return structuredSegment.content.jsonString
            #if canImport(FoundationModels, _version: 2.0)
            case .attachment, .custom:
                skipped += 1
                return nil
            #endif
            @unknown default:
                skipped += 1
                return nil
            }
        }.joined(separator: "\n")
    }
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
extension FMGenerationOptionsSnapshot {
    /// nil when options carries no signal (`GenerationOptions()` — the
    /// SDK-verified all-nil default), so default-options prompts stay free of
    /// noise fields. SamplingMode has no accessors: non-nil compares against
    /// `.greedy`, anything else is `.random` with parameters unrecoverable.
    init?(bridging options: GenerationOptions) {
        guard options != GenerationOptions() else { return nil }
        #if canImport(FoundationModels, _version: 2.0)
        // FoundationModels 2.0 (OS 27 SDK) renames `sampling` to the
        // back-deployed `samplingMode`; older SDKs only declare `sampling`.
        let mode = options.samplingMode
        #else
        let mode = options.sampling
        #endif
        let sampling: Sampling
        if let mode {
            sampling = (mode == .greedy) ? .greedy : .random
        } else {
            sampling = .unspecified
        }
        self.init(
            temperature: options.temperature,
            maximumResponseTokens: options.maximumResponseTokens,
            sampling: sampling
        )
    }
}
#endif
#endif  // compiler(>=6.2)
