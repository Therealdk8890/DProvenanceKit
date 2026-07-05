import XCTest
import DProvenanceKit
@testable import DProvenanceFoundationModels

/// Locks the frozen identifier/priority table. These literals are the wire
/// contract; a failure here means a breaking change shipped.
final class TypeIdentifierStabilityTests: XCTestCase {
    private let text = FMRedactedText("abc", redaction: .full)

    private var allCases: [(FoundationModelTraceEvent, String, TracePriority)] {
        [
            (.instructions(FMInstructionsPayload(content: text, toolNames: [])), "fm_instructions", .structural),
            (.prompt(FMPromptPayload(content: text, turnIndex: 0)), "fm_prompt", .critical),
            (.toolCall(FMToolCallPayload(toolName: "WeatherTool", arguments: text, turnIndex: 0, invocationIndex: 0)), "fm_tool_call", .critical),
            (.toolOutput(FMToolOutputPayload(toolName: "WeatherTool", content: text, turnIndex: 0, invocationIndex: 0)), "fm_tool_output", .structural),
            (.response(FMResponsePayload(content: text, turnIndex: 0)), "fm_response", .critical),
            (.generationError(FMGenerationErrorPayload(kind: .refusal, message: text, turnIndex: 0)), "fm_generation_error", .critical),
            (.modelAvailability(FMModelAvailabilityPayload(isAvailable: true)), "fm_model_availability", .diagnostic),
            (.streamSnapshot(FMStreamSnapshotPayload(snapshotIndex: 0, contentUTF8Count: 1, turnIndex: 0)), "fm_stream_snapshot", .telemetry),
            (.unknownEntry(FMUnknownEntryPayload(kindDescription: text)), "fm_unknown_entry", .diagnostic),
        ]
    }

    func testFrozenIdentifierAndPriorityTable() {
        for (event, identifier, priority) in allCases {
            XCTAssertEqual(event.typeIdentifier, identifier)
            XCTAssertEqual(event.priority, priority)
        }
        XCTAssertEqual(allCases.count, 9, "New cases must be added to this table")
    }

    func testFMEventTypeConstantsMatchPayloadComputedIdentifiers() {
        let constants = [
            FMEventType.instructions, FMEventType.prompt, FMEventType.toolCall,
            FMEventType.toolOutput, FMEventType.response, FMEventType.generationError,
            FMEventType.modelAvailability, FMEventType.streamSnapshot, FMEventType.unknownEntry,
        ]
        XCTAssertEqual(constants, allCases.map { $0.0.typeIdentifier })
    }

    func testSemanticKeyExcludesIndicesAndContent() {
        let callTurn0 = FoundationModelTraceEvent.toolCall(
            FMToolCallPayload(toolName: "WeatherTool", arguments: text, turnIndex: 0, invocationIndex: 0)
        )
        let callTurn5 = FoundationModelTraceEvent.toolCall(
            FMToolCallPayload(toolName: "WeatherTool", arguments: FMRedactedText("other", redaction: .full), turnIndex: 5, invocationIndex: 3)
        )
        XCTAssertEqual(callTurn0.semanticKey, "fm_tool_call:WeatherTool")
        XCTAssertEqual(callTurn0.semanticKey, callTurn5.semanticKey)

        let refusal = FoundationModelTraceEvent.generationError(
            FMGenerationErrorPayload(kind: .refusal, message: text, turnIndex: 2)
        )
        XCTAssertEqual(refusal.semanticKey, "fm_generation_error:refusal")

        let promptA = FoundationModelTraceEvent.prompt(FMPromptPayload(content: text, turnIndex: 0))
        let promptB = FoundationModelTraceEvent.prompt(
            FMPromptPayload(content: FMRedactedText("different", redaction: .full), turnIndex: 7)
        )
        XCTAssertEqual(promptA.semanticKey, promptB.semanticKey)
        XCTAssertEqual(promptA.semanticKey, "fm_prompt")

        let availability = FoundationModelTraceEvent.modelAvailability(FMModelAvailabilityPayload(isAvailable: false))
        XCTAssertEqual(availability.semanticKey, "fm_model_availability:apple.foundationmodels")
    }
}
