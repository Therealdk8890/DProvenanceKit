#if canImport(FoundationModels)
import Foundation
import FoundationModels
@testable import DProvenanceFoundationModels

/// Transcript fixtures built purely from the SDK's public inits — no model
/// runtime required.
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
enum TranscriptFixtures {
    static func text(_ content: String) -> Transcript.Segment {
        .text(Transcript.TextSegment(content: content))
    }

    static func weatherToolDefinition() -> Transcript.ToolDefinition {
        Transcript.ToolDefinition(
            name: "WeatherTool",
            description: "Gets weather",
            parameters: GeneratedContent.generationSchema
        )
    }

    /// instructions + 2 turns, the first with a tool call/output pair.
    static func canonical() throws -> Transcript {
        let arguments = try GeneratedContent(json: #"{"city": "Paris"}"#)
        return Transcript(entries: [
            .instructions(Transcript.Instructions(
                segments: [text("Be terse.")],
                toolDefinitions: [weatherToolDefinition()]
            )),
            .prompt(Transcript.Prompt(segments: [text("Weather in Paris?")])),
            .toolCalls(Transcript.ToolCalls(id: "calls-0", [
                Transcript.ToolCall(id: "call-0", toolName: "WeatherTool", arguments: arguments),
            ])),
            .toolOutput(Transcript.ToolOutput(id: "output-0", toolName: "WeatherTool", segments: [text("Sunny")])),
            .response(Transcript.Response(assetIDs: [], segments: [text("It is sunny.")])),
            .prompt(Transcript.Prompt(segments: [text("And tomorrow?")])),
            .response(Transcript.Response(assetIDs: [], segments: [text("Rainy.")])),
        ])
    }
}
#endif
