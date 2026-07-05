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
/// `content.jsonString`; unknown segment kinds are skipped and counted so
/// ingestion summaries can surface data loss. Unknown Entry kinds map to
/// `.unknown(description:)` via the entry's CustomStringConvertible.
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
        let sampling: Sampling
        if let mode = options.sampling {
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
