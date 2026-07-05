import XCTest
import DProvenanceKit
@testable import DProvenanceFoundationModels

final class FMSnapshotMapperTests: XCTestCase {
    private let mapper = FMSnapshotMapper()

    func testCanonicalSnapshotMapsToExpectedOrderedEvents() {
        let mapped = mapper.map(SnapshotFixtures.canonical)
        XCTAssertEqual(mapped.count, 12)

        XCTAssertEqual(
            mapped.map { $0.payload.typeIdentifier },
            [
                "fm_instructions",
                "fm_prompt",
                "fm_tool_call", "fm_tool_call", "fm_tool_call",
                "fm_tool_output", "fm_tool_output", "fm_tool_output",
                "fm_response",
                "fm_prompt",
                "fm_response",
                "fm_unknown_entry",
            ]
        )

        guard case .instructions(let instructions) = mapped[0].payload else { return XCTFail("instructions") }
        XCTAssertEqual(instructions.content.text, "Be terse.")
        XCTAssertEqual(instructions.toolNames, ["WeatherTool"])
        XCTAssertEqual(instructions.toolDescriptions, ["WeatherTool": "Gets weather"])
        XCTAssertEqual(mapped[0].spanPath, [], "Instructions live at run root")

        guard case .prompt(let prompt0) = mapped[1].payload else { return XCTFail("prompt") }
        XCTAssertEqual(prompt0.turnIndex, 0)
        XCTAssertNil(prompt0.options)
        XCTAssertEqual(mapped[1].spanPath, ["fm.turn.0"])
    }

    func testInvocationIndexFanOutAndOutputPairing() {
        let mapped = mapper.map(SnapshotFixtures.canonical)

        guard case .toolCall(let call0) = mapped[2].payload,
              case .toolCall(let call1) = mapped[3].payload,
              case .toolCall(let call2) = mapped[4].payload else { return XCTFail("tool calls") }
        XCTAssertEqual(call0.toolName, "WeatherTool")
        XCTAssertEqual(call0.invocationIndex, 0)
        XCTAssertEqual(call1.toolName, "WeatherTool")
        XCTAssertEqual(call1.invocationIndex, 1)
        XCTAssertEqual(call2.toolName, "AirQualityTool")
        XCTAssertEqual(call2.invocationIndex, 0)
        XCTAssertEqual(call0.arguments.text, #"{"city":"Paris"}"#)
        XCTAssertEqual(mapped[2].spanPath, ["fm.turn.0", "fm.turn.0.tool.WeatherTool.0"])
        XCTAssertEqual(mapped[3].spanPath, ["fm.turn.0", "fm.turn.0.tool.WeatherTool.1"])
        XCTAssertEqual(mapped[4].spanPath, ["fm.turn.0", "fm.turn.0.tool.AirQualityTool.0"])

        // Output pairing is name+order: the second WeatherTool output pairs
        // to invocation 1 even though an AirQualityTool output sits between.
        guard case .toolOutput(let out0) = mapped[5].payload,
              case .toolOutput(let out1) = mapped[6].payload,
              case .toolOutput(let out2) = mapped[7].payload else { return XCTFail("tool outputs") }
        XCTAssertEqual(out0.toolName, "WeatherTool")
        XCTAssertEqual(out0.invocationIndex, 0)
        XCTAssertEqual(out1.toolName, "AirQualityTool")
        XCTAssertEqual(out1.invocationIndex, 0)
        XCTAssertEqual(out2.toolName, "WeatherTool")
        XCTAssertEqual(out2.invocationIndex, 1)
        XCTAssertFalse(out0.isError)
        XCTAssertEqual(mapped[7].spanPath, ["fm.turn.0", "fm.turn.0.tool.WeatherTool.1"])
    }

    func testTurnIndexingAndUnknownInsideTurn() {
        let mapped = mapper.map(SnapshotFixtures.canonical)

        guard case .response(let response0) = mapped[8].payload else { return XCTFail("response 0") }
        XCTAssertEqual(response0.turnIndex, 0)
        XCTAssertEqual(mapped[8].spanPath, ["fm.turn.0"])

        guard case .prompt(let prompt1) = mapped[9].payload else { return XCTFail("prompt 1") }
        XCTAssertEqual(prompt1.turnIndex, 1)
        XCTAssertEqual(mapped[9].spanPath, ["fm.turn.1"])

        guard case .response(let response1) = mapped[10].payload else { return XCTFail("response 1") }
        XCTAssertEqual(response1.turnIndex, 1)

        guard case .unknownEntry(let unknown) = mapped[11].payload else { return XCTFail("unknown") }
        XCTAssertEqual(unknown.turnIndex, 1)
        XCTAssertEqual(unknown.kindDescription.text, "(Mystery) new entry kind")
        XCTAssertEqual(mapped[11].spanPath, ["fm.turn.1"])
    }

    func testUnknownOutsideTurnIsRootWithNilTurnIndex() {
        let snapshot = FMTranscriptSnapshot(entries: [.unknown(description: "orphan")])
        let mapped = mapper.map(snapshot)
        XCTAssertEqual(mapped.count, 1)
        guard case .unknownEntry(let unknown) = mapped[0].payload else { return XCTFail("unknown") }
        XCTAssertNil(unknown.turnIndex)
        XCTAssertEqual(mapped[0].spanPath, [])
    }

    func testRecordInstructionsFalseFilters() {
        let configuration = FMTracingConfiguration(recordInstructions: false)
        let mapped = FMSnapshotMapper(configuration: configuration).map(SnapshotFixtures.canonical)
        XCTAssertEqual(mapped.count, 11)
        XCTAssertFalse(mapped.contains { $0.payload.typeIdentifier == "fm_instructions" })
        XCTAssertEqual(mapped[0].payload.typeIdentifier, "fm_prompt")
    }

    func testRedactionPolicyAppliedPerField() {
        let configuration = FMTracingConfiguration(
            redaction: FMRedactionPolicy(
                promptContent: .hashed,
                responseContent: .omitted,
                instructionsContent: .full,
                toolArguments: .hashed,
                toolOutput: .full,
                errorMessages: .omitted
            )
        )
        let mapped = FMSnapshotMapper(configuration: configuration).map(SnapshotFixtures.canonical)

        guard case .instructions(let instructions) = mapped[0].payload,
              case .prompt(let prompt) = mapped[1].payload,
              case .toolCall(let call) = mapped[2].payload,
              case .toolOutput(let output) = mapped[5].payload,
              case .response(let response) = mapped[8].payload,
              case .unknownEntry(let unknown) = mapped[11].payload else { return XCTFail("shape") }
        XCTAssertEqual(instructions.content.redaction, .full)
        XCTAssertEqual(prompt.content.redaction, .hashed)
        XCTAssertNil(prompt.content.text)
        XCTAssertEqual(call.arguments.redaction, .hashed)
        XCTAssertEqual(output.content.redaction, .full)
        XCTAssertEqual(response.content.redaction, .omitted)
        XCTAssertNil(response.content.sha256)
        XCTAssertEqual(unknown.kindDescription.redaction, .omitted)
    }

    func testSessionLabelPrefixesSpanPaths() {
        let configuration = FMTracingConfiguration(sessionLabel: "drafting")
        let mapped = FMSnapshotMapper(configuration: configuration).map(SnapshotFixtures.canonical)
        XCTAssertEqual(mapped[1].spanPath, ["fm[drafting].turn.0"])
        XCTAssertEqual(mapped[2].spanPath, ["fm[drafting].turn.0", "fm[drafting].turn.0.tool.WeatherTool.0"])
    }

    func testEmptySnapshotMapsToEmpty() {
        XCTAssertEqual(mapper.map(FMTranscriptSnapshot(entries: [])), [])
    }

    func testDeterminism() {
        XCTAssertEqual(mapper.map(SnapshotFixtures.canonical), mapper.map(SnapshotFixtures.canonical))
    }

    func testIncrementalMapEqualsSuffixOfFullMap() {
        let snapshot = SnapshotFixtures.canonical
        let full = mapper.map(snapshot)

        // Resume at entry 7 (the turn-1 boundary); one prompt precedes it.
        let promptsBefore = snapshot.entries[..<7].reduce(into: 0) { if case .prompt = $1 { $0 += 1 } }
        XCTAssertEqual(promptsBefore, 1)
        let incremental = mapper.map(snapshot, in: 7..<snapshot.entries.count, startingTurnIndex: promptsBefore)
        XCTAssertEqual(incremental, Array(full.suffix(3)))
    }

    func testMidTurnResumeAttachesOrphansToLastStartedTurn() {
        let snapshot = SnapshotFixtures.canonical
        let full = mapper.map(snapshot)

        // Entry 8 is turn 1's response; two prompts precede it. The orphan
        // response must attach to turn 1 (the last started turn), matching
        // the full map — and the range end is clamped.
        let incremental = mapper.map(snapshot, in: 8..<99, startingTurnIndex: 2)
        XCTAssertEqual(incremental, Array(full.suffix(2)))
    }
}
