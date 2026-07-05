import XCTest
import Foundation
import DProvenanceKit
@testable import DProvenanceFoundationModels

final class FMEquivalenceEvaluatorTests: XCTestCase {
    private let evaluator = FoundationModelEquivalenceEvaluator()

    private func toolCall(_ name: String, args: String, turn: Int = 0, invocation: Int = 0, redaction: FMContentRedaction = .full) -> FoundationModelTraceEvent {
        .toolCall(FMToolCallPayload(
            toolName: name,
            arguments: FMRedactedText(args, redaction: redaction),
            turnIndex: turn,
            invocationIndex: invocation
        ))
    }

    private func response(_ text: String, turn: Int = 0, redaction: FMContentRedaction = .full) -> FoundationModelTraceEvent {
        .response(FMResponsePayload(content: FMRedactedText(text, redaction: redaction), turnIndex: turn))
    }

    func testIdenticalToolCallScoresOne() {
        let base = toolCall("WeatherTool", args: #"{"city":"Paris"}"#)
        XCTAssertEqual(evaluator.evaluateSimilarity(base: base, comparison: base), 1.0)
    }

    func testDifferentTypeIdentifierScoresZero() {
        XCTAssertEqual(
            evaluator.evaluateSimilarity(
                base: toolCall("WeatherTool", args: "{}"),
                comparison: response("Sunny.")
            ),
            0.0
        )
    }

    func testDifferentToolNameHitsFloor() {
        XCTAssertEqual(
            evaluator.evaluateSimilarity(
                base: toolCall("WeatherTool", args: #"{"city":"Paris"}"#),
                comparison: toolCall("AirQualityTool", args: #"{"city":"Paris"}"#)
            ),
            0.05
        )
    }

    func testHashedVersusFullSameContentScoresOne() {
        XCTAssertEqual(
            evaluator.evaluateSimilarity(
                base: toolCall("WeatherTool", args: #"{"city":"Paris"}"#, redaction: .full),
                comparison: toolCall("WeatherTool", args: #"{"city":"Paris"}"#, redaction: .hashed)
            ),
            1.0,
            "Content identity is hash-based, so cross-policy diffing hits the exact path"
        )
    }

    func testSameToolDifferentArgsFallsBelowToolThreshold() {
        // Disjoint argument tokens and distant turns: no Jaccard credit, no
        // proximity credit — the score is the 0.55 base, below the 0.6
        // tool-call ambiguity threshold.
        let base = toolCall("WeatherTool", args: #"{"city":"Paris"}"#, turn: 0)
        let comparison = toolCall("WeatherTool", args: #"{"zip":"69001"}"#, turn: 10)
        let score = evaluator.evaluateSimilarity(base: base, comparison: comparison)
        XCTAssertEqual(score, 0.55, accuracy: 1e-12)
        XCTAssertLessThan(score, evaluator.ambiguityThreshold(for: base))
    }

    func testPartialJaccardOverlapScoresInBand() {
        // Tokens: {"city": / "Paris"} vs {"city": / "Tokyo"} — 1 of 3 shared.
        let base = toolCall("WeatherTool", args: #"{"city": "Paris"}"#, turn: 0)
        let comparison = toolCall("WeatherTool", args: #"{"city": "Tokyo"}"#, turn: 0)
        let score = evaluator.evaluateSimilarity(base: base, comparison: comparison)
        XCTAssertEqual(score, 0.55 + 0.35 / 3 + 0.10, accuracy: 1e-12)
    }

    func testOmittedVersusFullLandsInStructuralBand() {
        let base = response("Sunny in Paris.", turn: 0)
        let comparison = response("Sunny in Paris.", turn: 0, redaction: .omitted)
        let score = evaluator.evaluateSimilarity(base: base, comparison: comparison)
        XCTAssertEqual(score, 0.65, accuracy: 1e-12, "0.55 base + full index proximity, no Jaccard without both texts")
    }

    func testIndexBrittlenessGuard() {
        // A turnIndex shift ALONE must not drop a content-identical match
        // below threshold: an inserted early turn shifts every later index.
        let base = response("The demand letter is ready.", turn: 0)
        let shifted = response("The demand letter is ready.", turn: 5)
        let score = evaluator.evaluateSimilarity(base: base, comparison: shifted)
        XCTAssertEqual(score, 1.0)
        XCTAssertGreaterThanOrEqual(score, evaluator.ambiguityThreshold(for: base))
    }

    func testAmbiguityThresholds() {
        XCTAssertEqual(evaluator.ambiguityThreshold(for: toolCall("T", args: "{}")), 0.6)
        XCTAssertEqual(
            evaluator.ambiguityThreshold(for: .toolOutput(FMToolOutputPayload(
                toolName: "T", content: .omitted, turnIndex: 0, invocationIndex: 0
            ))),
            0.6
        )
        XCTAssertEqual(
            evaluator.ambiguityThreshold(for: .prompt(FMPromptPayload(content: .omitted, turnIndex: 0))),
            0.5
        )
        XCTAssertEqual(evaluator.ambiguityThreshold(for: response("x")), 0.5)
        XCTAssertEqual(
            evaluator.ambiguityThreshold(for: .modelAvailability(FMModelAvailabilityPayload(isAvailable: true))),
            0.4
        )
        XCTAssertEqual(
            evaluator.ambiguityThreshold(for: .streamSnapshot(FMStreamSnapshotPayload(
                snapshotIndex: 0, contentUTF8Count: 1, turnIndex: 0
            ))),
            0.4
        )
    }

    // MARK: end-to-end through TraceAlignmentEngine

    private func traceEvent(
        _ payload: FoundationModelTraceEvent,
        sequence: UInt64,
        runID: UUID,
        spanID: String?,
        parentSpanID: String?
    ) -> TraceEvent<FoundationModelTraceEvent> {
        TraceEvent(
            runID: runID, contextID: "eval", engineName: "FoundationModels",
            schemaVersion: 1, sequence: sequence, spanID: spanID,
            parentSpanID: parentSpanID, payload: payload,
            timestamp: Date(timeIntervalSince1970: Double(sequence))
        )
    }

    private func run(_ payloads: [FoundationModelTraceEvent]) -> TraceRun<FoundationModelTraceEvent> {
        let runID = UUID()
        let events = payloads.enumerated().map { index, payload -> TraceEvent<FoundationModelTraceEvent> in
            let spanID: String?
            let parentSpanID: String?
            switch payload {
            case .toolCall(let p):
                spanID = FMSpanPath.tool(named: p.toolName, invocation: p.invocationIndex, turnIndex: p.turnIndex)
                parentSpanID = FMSpanPath.turn(p.turnIndex)
            case .toolOutput(let p):
                spanID = FMSpanPath.tool(named: p.toolName, invocation: p.invocationIndex, turnIndex: p.turnIndex)
                parentSpanID = FMSpanPath.turn(p.turnIndex)
            case .instructions, .modelAvailability:
                spanID = nil
                parentSpanID = nil
            default:
                spanID = FMSpanPath.turn(0)
                parentSpanID = nil
            }
            return traceEvent(payload, sequence: UInt64(index), runID: runID, spanID: spanID, parentSpanID: parentSpanID)
        }
        return TraceRun(runID: runID, contextID: "eval", events: events)
    }

    private var baselinePayloads: [FoundationModelTraceEvent] {
        [
            .prompt(FMPromptPayload(content: FMRedactedText("Prepare the invoice.", redaction: .full), turnIndex: 0)),
            toolCall("CreateCustomer", args: #"{"name":"ACME"}"#),
            toolCall("GenerateInvoice", args: #"{"amount":100}"#),
            response("Invoice generated for ACME."),
        ]
    }

    func testToolCallRemovedIsHighRegression() {
        let engine = TraceAlignmentEngine(configuration: FoundationModelAlignment.configuration())
        var comparisonPayloads = baselinePayloads
        comparisonPayloads.remove(at: 1)

        let result = engine.align(base: run(baselinePayloads), comparison: run(comparisonPayloads))
        XCTAssertEqual(result.regressionRisk.level, .high)
        XCTAssertTrue(result.regressionRisk.reasoning.contains("fm_tool_call"))
    }

    func testToolCallsReorderedIsHighRegression() {
        let engine = TraceAlignmentEngine(configuration: FoundationModelAlignment.configuration())
        var comparisonPayloads = baselinePayloads
        comparisonPayloads.swapAt(1, 2)

        let result = engine.align(base: run(baselinePayloads), comparison: run(comparisonPayloads))
        XCTAssertEqual(result.regressionRisk.level, .high,
                       "Critical reorder (GenerateInvoice before CreateCustomer) must be flagged")
    }

    func testResponseDriftOnlyAlignsBelowHigh() {
        let engine = TraceAlignmentEngine(configuration: FoundationModelAlignment.configuration())
        var comparisonPayloads = baselinePayloads
        comparisonPayloads[3] = response("Invoice generated for ACME today.")

        let result = engine.align(base: run(baselinePayloads), comparison: run(comparisonPayloads))
        XCTAssertNotEqual(result.regressionRisk.level, .high)
        XCTAssertFalse(result.alignments.contains { $0.state.isRemoved },
                       "Drifted response must still align")
    }
}
