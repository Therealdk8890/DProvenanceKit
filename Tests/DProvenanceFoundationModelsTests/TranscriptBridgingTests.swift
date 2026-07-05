#if canImport(FoundationModels)
import XCTest
import Foundation
import FoundationModels
import DProvenanceKit
@testable import DProvenanceFoundationModels

final class TranscriptBridgingTests: XCTestCase {
    func testSegmentTextExtraction() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires the macOS 26 SDK") }
        let structured = try GeneratedContent(json: #"{"a": 1}"#)
        let snapshot = FMTranscriptSnapshot(entries: [
            .response(Transcript.Response(assetIDs: [], segments: [
                TranscriptFixtures.text("Hello"),
                .structure(Transcript.StructuredSegment(source: "test", content: structured)),
            ])),
        ])
        guard case .response(let text, let assetIDCount) = snapshot.entries[0] else {
            return XCTFail("Expected response entry")
        }
        XCTAssertEqual(text, "Hello\n\(structured.jsonString)")
        XCTAssertEqual(assetIDCount, 0)
    }

    func testToolCallArgumentsAreCanonicalJSONString() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires the macOS 26 SDK") }
        let arguments = try GeneratedContent(json: #"{"city": "Paris", "unit": "C"}"#)
        let snapshot = FMTranscriptSnapshot(entries: [
            .toolCalls(Transcript.ToolCalls(id: "calls", [
                Transcript.ToolCall(id: "call", toolName: "WeatherTool", arguments: arguments),
            ])),
        ])
        guard case .toolCalls(let calls) = snapshot.entries[0] else {
            return XCTFail("Expected toolCalls entry")
        }
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].toolName, "WeatherTool")
        XCTAssertEqual(calls[0].argumentsJSON, arguments.jsonString)
    }

    func testInstructionsToolDefinitions() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires the macOS 26 SDK") }
        let snapshot = FMTranscriptSnapshot(try TranscriptFixtures.canonical())
        guard case .instructions(let text, let toolNames, let toolDescriptions) = snapshot.entries[0] else {
            return XCTFail("Expected instructions entry")
        }
        XCTAssertEqual(text, "Be terse.")
        XCTAssertEqual(toolNames, ["WeatherTool"])
        XCTAssertEqual(toolDescriptions, ["WeatherTool": "Gets weather"])
    }

    func testOptionsMapping() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires the macOS 26 SDK") }
        func bridgedOptions(_ options: GenerationOptions) -> FMGenerationOptionsSnapshot? {
            let snapshot = FMTranscriptSnapshot(entries: [
                .prompt(Transcript.Prompt(segments: [TranscriptFixtures.text("p")], options: options)),
            ])
            guard case .prompt(_, let bridged, _) = snapshot.entries[0] else {
                XCTFail("Expected prompt entry")
                return nil
            }
            return bridged
        }

        XCTAssertNil(bridgedOptions(GenerationOptions()), "Default options carry no signal")
        XCTAssertEqual(
            bridgedOptions(GenerationOptions(sampling: .greedy, temperature: 0.5, maximumResponseTokens: 100)),
            FMGenerationOptionsSnapshot(temperature: 0.5, maximumResponseTokens: 100, sampling: .greedy)
        )
        XCTAssertEqual(
            bridgedOptions(GenerationOptions(sampling: .random(top: 5), temperature: nil)),
            FMGenerationOptionsSnapshot(sampling: .random)
        )
        XCTAssertEqual(
            bridgedOptions(GenerationOptions(temperature: 0.9)),
            FMGenerationOptionsSnapshot(temperature: 0.9, sampling: .unspecified)
        )
    }

    func testResponseFormatName() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires the macOS 26 SDK") }
        let format = Transcript.ResponseFormat(type: GeneratedContent.self)
        let snapshot = FMTranscriptSnapshot(entries: [
            .prompt(Transcript.Prompt(segments: [TranscriptFixtures.text("p")], responseFormat: format)),
            .prompt(Transcript.Prompt(segments: [TranscriptFixtures.text("q")])),
        ])
        guard case .prompt(_, _, let name) = snapshot.entries[0],
              case .prompt(_, _, let missing) = snapshot.entries[1] else {
            return XCTFail("Expected prompt entries")
        }
        XCTAssertEqual(name, format.name)
        XCTAssertNil(missing)
    }

    func testAssetIDCount() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires the macOS 26 SDK") }
        let snapshot = FMTranscriptSnapshot(entries: [
            .response(Transcript.Response(assetIDs: ["a", "b"], segments: [TranscriptFixtures.text("r")])),
        ])
        guard case .response(_, let count) = snapshot.entries[0] else {
            return XCTFail("Expected response entry")
        }
        XCTAssertEqual(count, 2)
    }

    func testFullPipelineTranscriptToMappedEvents() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires the macOS 26 SDK") }
        let snapshot = FMTranscriptSnapshot(try TranscriptFixtures.canonical())
        let mapped = FMSnapshotMapper().map(snapshot)
        XCTAssertEqual(mapped.map { $0.payload.typeIdentifier }, [
            "fm_instructions", "fm_prompt", "fm_tool_call", "fm_tool_output",
            "fm_response", "fm_prompt", "fm_response",
        ])
        XCTAssertEqual(mapped[2].spanPath, ["fm.turn.0", "fm.turn.0.tool.WeatherTool.0"])
        XCTAssertEqual(mapped[5].spanPath, ["fm.turn.1"])
        guard case .toolCall(let call) = mapped[2].payload else { return XCTFail("tool call") }
        XCTAssertEqual(call.arguments.text, try GeneratedContent(json: #"{"city": "Paris"}"#).jsonString)
    }

    /// THE parity invariant: post-hoc ingestion and the wrapper's
    /// reconciliation seam over the same transcript produce BYTE-EXACT equal
    /// payload sequences and IDENTICAL span identity — no normalization,
    /// because payloads carry no volatile data.
    func testLiveReconciliationParityWithPostHocIngestion() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires the macOS 26 SDK") }
        // Both paths must consume the SAME entries. The session's transcript
        // is the shared source of truth: LanguageModelSession(transcript:)
        // regenerates the instructions entry's toolDefinitions from its live
        // `tools:` array, so the raw fixture would differ from what the
        // wrapper can ever observe.
        let session = TracedLanguageModelSession(
            wrapping: LanguageModelSession(transcript: try TranscriptFixtures.canonical())
        )
        let transcript = session.transcript

        let ingestionStore = InMemoryTraceStore<FoundationModelTraceEvent>()
        var ingestionSummary: FMIngestionSummary?
        DProvenanceKit<FoundationModelTraceEvent>.runSync(contextID: "parity-ingest", store: ingestionStore) {
            ingestionSummary = FMTranscriptIngestion.ingest(transcript)
        }

        let wrapperStore = InMemoryTraceStore<FoundationModelTraceEvent>()
        var wrapperSummary: FMIngestionSummary?
        DProvenanceKit<FoundationModelTraceEvent>.runSync(contextID: "parity-wrapper", store: wrapperStore) {
            wrapperSummary = session.recordProvenance()
        }

        let ingested = try await TestSupport.events(in: ingestionStore, contextID: "parity-ingest")
        let reconciled = try await TestSupport.events(in: wrapperStore, contextID: "parity-wrapper")

        XCTAssertEqual(ingestionSummary?.eventCount, 7)
        XCTAssertEqual(wrapperSummary?.eventCount, 7)
        XCTAssertEqual(ingested.count, reconciled.count)
        for (postHoc, live) in zip(ingested, reconciled) {
            XCTAssertEqual(
                try TestSupport.sortedKeysJSON(postHoc.payload),
                try TestSupport.sortedKeysJSON(live.payload),
                "Payloads must be byte-exact across capture modes"
            )
            XCTAssertEqual(postHoc.spanID, live.spanID)
            XCTAssertEqual(postHoc.parentSpanID, live.parentSpanID)
            XCTAssertEqual(postHoc.engineName, live.engineName)
        }
    }
}
#endif
