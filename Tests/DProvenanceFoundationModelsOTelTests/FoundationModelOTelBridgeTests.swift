import XCTest
import DProvenanceKit
import DProvenanceFoundationModels
import DProvenanceOTel
import DProvenanceFoundationModelsOTel

/// Verifies the flagship path: FoundationModels traces classify as `gen_ai.*` when
/// exported through the OTel bridge, purely by linking `DProvenanceFoundationModelsOTel`.
final class FoundationModelOTelBridgeTests: XCTestCase {

    private let runID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    private func event(_ payload: FoundationModelTraceEvent, seq: UInt64, span: String) -> TraceEvent<FoundationModelTraceEvent> {
        TraceEvent(runID: runID, contextID: "ctx", engineName: "fm", schemaVersion: 1,
                   sequence: seq, spanID: span, parentSpanID: nil, payload: payload)
    }

    private func stringAttr(_ span: OTLPSpan, _ key: String) -> String? {
        for kv in span.attributes where kv.key == key {
            if case .string(let s) = kv.value { return s }
        }
        return nil
    }

    // MARK: - Conformance mapping (unit)

    func testPromptMapsToChatWithProviderAndRequestParams() {
        let prompt = FoundationModelTraceEvent.prompt(FMPromptPayload(
            content: FMRedactedText("hi", redaction: .full),
            options: FMGenerationOptionsSnapshot(temperature: 0.7, maximumResponseTokens: 256, sampling: .random),
            turnIndex: 0))

        let semantics = prompt.otelSemantics
        XCTAssertEqual(semantics?.operationName, "chat")
        XCTAssertEqual(semantics?.providerName, "apple.foundationmodels")
        XCTAssertEqual(semantics?.requestModel, "apple.foundationmodels.system")
        XCTAssertTrue(semantics?.extra.contains(.double("gen_ai.request.temperature", 0.7)) ?? false)
        XCTAssertTrue(semantics?.extra.contains(.int("gen_ai.request.max_tokens", 256)) ?? false)
    }

    func testToolCallMapsToExecuteTool() {
        let call = FoundationModelTraceEvent.toolCall(
            FMToolCallPayload(toolName: "WeatherTool", arguments: .omitted, turnIndex: 0, invocationIndex: 0))
        let semantics = call.otelSemantics
        XCTAssertEqual(semantics?.operationName, "execute_tool")
        XCTAssertEqual(semantics?.toolName, "WeatherTool")
        XCTAssertEqual(semantics?.providerName, "apple.foundationmodels")
    }

    func testNonGenerativeEventsAreNotPromoted() {
        let avail = FoundationModelTraceEvent.modelAvailability(FMModelAvailabilityPayload(isAvailable: true))
        XCTAssertNil(avail.otelSemantics)

        let stream = FoundationModelTraceEvent.streamSnapshot(
            FMStreamSnapshotPayload(snapshotIndex: 0, contentUTF8Count: 3, turnIndex: 0))
        XCTAssertNil(stream.otelSemantics)
    }

    func testPromptWithoutOptionsEmitsNoRequestParamExtras() {
        let prompt = FoundationModelTraceEvent.prompt(
            FMPromptPayload(content: .omitted, turnIndex: 0))
        let semantics = prompt.otelSemantics
        XCTAssertEqual(semantics?.operationName, "chat")
        XCTAssertEqual(semantics?.extra.count, 0)
    }

    // MARK: - End-to-end span promotion

    func testExportedSpansCarryGenAIAttributes() {
        let run = TraceRun<FoundationModelTraceEvent>(runID: runID, contextID: "ctx", events: [
            event(.prompt(FMPromptPayload(
                content: FMRedactedText("hi", redaction: .full),
                options: FMGenerationOptionsSnapshot(temperature: 0.7, maximumResponseTokens: 256),
                turnIndex: 0)), seq: 0, span: "turn0"),
            event(.toolCall(FMToolCallPayload(
                toolName: "WeatherTool", arguments: .omitted, turnIndex: 0, invocationIndex: 0)), seq: 1, span: "turn0"),
            event(.response(FMResponsePayload(
                content: FMRedactedText("sunny", redaction: .full), turnIndex: 0)), seq: 2, span: "turn0"),
        ])

        let spans = OTelSpanMapper<FoundationModelTraceEvent>().spans(for: run)

        let operations = spans.compactMap { stringAttr($0, "gen_ai.operation.name") }
        XCTAssertTrue(operations.contains("chat"),
                      "prompt/response must classify as a chat generation")
        XCTAssertTrue(operations.contains("execute_tool"),
                      "tool call must classify as execute_tool")
        XCTAssertTrue(spans.contains { stringAttr($0, "gen_ai.provider.name") == "apple.foundationmodels" })
        XCTAssertTrue(spans.contains { stringAttr($0, "gen_ai.tool.name") == "WeatherTool" })
    }

    // MARK: - Error status (#30)

    func testChatErrorClassifiesAndCarriesErrorType() {
        let err = FoundationModelTraceEvent.generationError(
            FMGenerationErrorPayload(kind: .guardrailViolation, message: .omitted, turnIndex: 0))
        let semantics = err.otelSemantics
        XCTAssertEqual(semantics?.operationName, "chat")
        XCTAssertEqual(semantics?.errorType, "guardrailViolation")
    }

    func testToolCallErrorClassifiesAsExecuteTool() {
        let err = FoundationModelTraceEvent.generationError(
            FMGenerationErrorPayload(kind: .toolCallError, message: .omitted, toolName: "WeatherTool", turnIndex: 0))
        let semantics = err.otelSemantics
        XCTAssertEqual(semantics?.operationName, "execute_tool")
        XCTAssertEqual(semantics?.toolName, "WeatherTool")
        XCTAssertEqual(semantics?.errorType, "toolCallError")
    }

    func testExportedErrorSpanHasErrorStatusAndErrorType() throws {
        let run = TraceRun<FoundationModelTraceEvent>(runID: runID, contextID: "ctx", events: [
            event(.generationError(FMGenerationErrorPayload(
                kind: .exceededContextWindowSize, message: .omitted, turnIndex: 0)), seq: 0, span: "turn0"),
        ])
        let spans = OTelSpanMapper<FoundationModelTraceEvent>().spans(for: run)
        let errorSpan = try XCTUnwrap(spans.first { stringAttr($0, "error.type") == "exceededContextWindowSize" })
        XCTAssertEqual(errorSpan.status.code, 2, "an errored generation must export as OTLP ERROR")
        XCTAssertEqual(stringAttr(errorSpan, "gen_ai.operation.name"), "chat")
    }
}
