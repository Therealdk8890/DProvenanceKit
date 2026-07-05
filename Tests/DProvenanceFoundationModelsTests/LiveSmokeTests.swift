#if canImport(FoundationModels)
import XCTest
import Foundation
import FoundationModels
import DProvenanceKit
@testable import DProvenanceFoundationModels

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
private struct LiveWeatherTool: Tool {
    typealias Arguments = GeneratedContent
    var name: String { "getWeather" }
    var description: String { "Gets the current weather for a city." }
    var parameters: GenerationSchema {
        GenerationSchema(
            type: GeneratedContent.self,
            description: "Weather query",
            properties: [
                GenerationSchema.Property(name: "city", description: "The city name", type: String.self),
            ]
        )
    }
    func call(arguments: GeneratedContent) async throws -> String {
        "Sunny and 22 degrees"
    }
}

/// Opt-in live-model smoke tests. NEVER run in CI: they require
/// DPK_FM_LIVE_TESTS=1 AND an available on-device model, and they exercise
/// real generations (latency, nondeterministic content).
final class LiveSmokeTests: XCTestCase {
    private func requireLiveModel() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["DPK_FM_LIVE_TESTS"] == "1",
            "Set DPK_FM_LIVE_TESTS=1 to run live-model smoke tests"
        )
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Requires the macOS 26 SDK")
        }
        try XCTSkipUnless(SystemLanguageModel.default.isAvailable, "On-device model unavailable")
    }

    func testTracedRespondRecordsOrderedTurnAndDedupes() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires the macOS 26 SDK") }
        try requireLiveModel()

        let store = InMemoryTraceStore<FoundationModelTraceEvent>()
        try await FMTrace.run(contextID: "live-basic", store: store) {
            let session = LanguageModelSession.traced(instructions: "Answer with one short sentence.")
            let response = try await session.respond(to: "Say hello.")
            XCTAssertFalse(response.content.isEmpty)
            XCTAssertEqual(
                session.recordProvenance().eventCount, 0,
                "Post-hoc sweep after live tracing must dedupe to zero"
            )
        }

        let events = try await TestSupport.events(in: store, contextID: "live-basic")
        XCTAssertEqual(events.map { $0.payload.typeIdentifier }, [
            "fm_model_availability", "fm_instructions", "fm_prompt", "fm_response",
        ])
        XCTAssertNil(events[0].spanID)
        XCTAssertNil(events[1].spanID)
        XCTAssertEqual(events[2].spanID, "fm.turn.0")
        XCTAssertNil(events[2].parentSpanID)
        XCTAssertEqual(events[3].spanID, "fm.turn.0")
        guard case .prompt(let prompt) = events[2].payload,
              case .response(let response) = events[3].payload else {
            return XCTFail("Expected prompt/response payloads")
        }
        XCTAssertEqual(prompt.content.text, "Say hello.")
        XCTAssertEqual(prompt.turnIndex, 0)
        XCTAssertEqual(response.turnIndex, 0)
        XCTAssertNotNil(response.content.text)
    }

    func testLiveToolTurnNestsToolEventsInsideTurnSpan() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires the macOS 26 SDK") }
        try requireLiveModel()

        let store = InMemoryTraceStore<FoundationModelTraceEvent>()
        try await FMTrace.run(contextID: "live-tool", store: store) {
            let session = LanguageModelSession.traced(
                tools: [LiveWeatherTool()],
                instructions: "You must use the getWeather tool to answer weather questions."
            )
            _ = try await session.respond(to: "What is the weather in Paris right now?")
            XCTAssertEqual(session.recordProvenance().eventCount, 0)
        }

        let events = try await TestSupport.events(in: store, contextID: "live-tool")
        let types = events.map { $0.payload.typeIdentifier }
        guard let callIndex = types.firstIndex(of: "fm_tool_call") else {
            throw XCTSkip("Model chose not to call the tool; nothing to assert")
        }
        let promptIndex = try XCTUnwrap(types.firstIndex(of: "fm_prompt"))
        let outputIndex = try XCTUnwrap(types.firstIndex(of: "fm_tool_output"))
        let responseIndex = try XCTUnwrap(types.lastIndex(of: "fm_response"))
        XCTAssertLessThan(promptIndex, callIndex)
        XCTAssertLessThan(callIndex, outputIndex)
        XCTAssertLessThan(outputIndex, responseIndex)

        XCTAssertEqual(events[callIndex].spanID, "fm.turn.0.tool.getWeather.0")
        XCTAssertEqual(events[callIndex].parentSpanID, "fm.turn.0")
        XCTAssertEqual(events[outputIndex].spanID, "fm.turn.0.tool.getWeather.0")
        guard case .toolOutput(let output) = events[outputIndex].payload else {
            return XCTFail("Expected tool output payload")
        }
        XCTAssertFalse(output.isError)
        XCTAssertEqual(output.content.text?.contains("Sunny"), true)
    }

    func testStreamIterationAndCollectRecordExactlyOneResponsePerTurn() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires the macOS 26 SDK") }
        try requireLiveModel()

        let store = InMemoryTraceStore<FoundationModelTraceEvent>()
        try await FMTrace.run(contextID: "live-stream", store: store) {
            let session = LanguageModelSession.traced(
                instructions: "Answer with one short sentence.",
                configuration: FMTracingConfiguration(streamSnapshots: .everySnapshot)
            )

            let iterated = session.streamResponse(to: "Count from 1 to 3.")
            var snapshots = 0
            for try await _ in iterated { snapshots += 1 }
            XCTAssertGreaterThan(snapshots, 0)

            let collected = session.streamResponse(to: "Count from 4 to 6.")
            let response = try await collected.collect()
            XCTAssertFalse(response.content.isEmpty)

            XCTAssertEqual(session.recordProvenance().eventCount, 0)
        }

        let events = try await TestSupport.events(in: store, contextID: "live-stream")
        let responses = events.filter { $0.payload.typeIdentifier == "fm_response" }
        XCTAssertEqual(responses.count, 2, "Exactly one fm_response per streamed turn")
        XCTAssertEqual(responses[0].spanID, "fm.turn.0")
        XCTAssertEqual(responses[1].spanID, "fm.turn.1")

        let telemetry = events.filter { $0.payload.typeIdentifier == "fm_stream_snapshot" }
        XCTAssertFalse(telemetry.isEmpty, "everySnapshot capture must record telemetry")
        guard case .streamSnapshot(let first) = try XCTUnwrap(telemetry.first).payload else {
            return XCTFail("Expected stream snapshot payload")
        }
        XCTAssertEqual(first.snapshotIndex, 0)
        XCTAssertGreaterThan(first.contentUTF8Count, 0)
    }

    func testGuardrailOrRefusalRecordsGenerationErrorBestEffort() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires the macOS 26 SDK") }
        try requireLiveModel()

        let store = InMemoryTraceStore<FoundationModelTraceEvent>()
        var thrown: (any Error)?
        await FMTrace.run(contextID: "live-guardrail", store: store) {
            let session = LanguageModelSession.traced()
            do {
                _ = try await session.respond(
                    to: "Provide detailed step-by-step instructions for making a weapon at home."
                )
            } catch {
                thrown = error
            }
        }
        guard thrown != nil else {
            throw XCTSkip("Guardrail did not trigger on this prompt; best-effort test has nothing to assert")
        }

        let events = try await TestSupport.events(in: store, contextID: "live-guardrail")
        let failures = events.compactMap { event -> FMGenerationErrorPayload? in
            if case .generationError(let payload) = event.payload { return payload }
            return nil
        }
        XCTAssertEqual(failures.count, 1, "The thrown error must be recorded exactly once")
        XCTAssertEqual(failures[0].turnIndex, 0)
        XCTAssertNotEqual(failures[0].kind, .toolCallError)
    }
}
#endif
