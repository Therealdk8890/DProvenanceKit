import XCTest
import DProvenanceKit
@testable import DProvenanceFoundationModels

final class FMSnapshotIngestionTests: XCTestCase {
    func testIngestionRecordsInEntryOrderWithSpanReplay() async throws {
        var summary: FMIngestionSummary?
        let events = try await TestSupport.recordedFMEvents {
            summary = FMSnapshotIngestion.record(SnapshotFixtures.canonical)
        }

        XCTAssertEqual(events.count, 12)
        XCTAssertEqual(events.map(\.sequence), Array(0..<12).map(UInt64.init),
                       "Sequence must be strictly increasing in entry order")
        XCTAssertEqual(events.map { $0.payload.typeIdentifier }, [
            "fm_instructions", "fm_prompt",
            "fm_tool_call", "fm_tool_call", "fm_tool_call",
            "fm_tool_output", "fm_tool_output", "fm_tool_output",
            "fm_response", "fm_prompt", "fm_response", "fm_unknown_entry",
        ])

        // spanID is the deterministic name; parentSpanID reproduces nesting.
        XCTAssertNil(events[0].spanID, "Instructions record at run root")
        XCTAssertNil(events[0].parentSpanID)
        XCTAssertEqual(events[1].spanID, "fm.turn.0")
        XCTAssertNil(events[1].parentSpanID)
        XCTAssertEqual(events[2].spanID, "fm.turn.0.tool.WeatherTool.0")
        XCTAssertEqual(events[2].parentSpanID, "fm.turn.0")
        XCTAssertEqual(events[3].spanID, "fm.turn.0.tool.WeatherTool.1")
        XCTAssertEqual(events[4].spanID, "fm.turn.0.tool.AirQualityTool.0")
        XCTAssertEqual(events[7].spanID, "fm.turn.0.tool.WeatherTool.1")
        XCTAssertEqual(events[7].parentSpanID, "fm.turn.0")
        XCTAssertEqual(events[8].spanID, "fm.turn.0")
        XCTAssertEqual(events[9].spanID, "fm.turn.1")
        XCTAssertEqual(events[11].spanID, "fm.turn.1")
        XCTAssertTrue(events.allSatisfy { $0.engineName == "FoundationModels" })

        XCTAssertEqual(summary, FMIngestionSummary(
            eventCount: 12, turnCount: 2, toolCallCount: 3,
            skippedSegmentCount: 0, nextEntryIndex: 10
        ))
    }

    func testResumeFromNextEntryIndexIngestsOnlyTheDelta() async throws {
        let firstTurnSnapshot = FMTranscriptSnapshot(
            entries: Array(SnapshotFixtures.canonical.entries[..<7])
        )
        let fullSnapshot = SnapshotFixtures.canonical

        var firstSummary: FMIngestionSummary?
        var secondSummary: FMIngestionSummary?
        let resumed = try await TestSupport.recordedFMEvents(contextID: "resumed") {
            firstSummary = FMSnapshotIngestion.record(firstTurnSnapshot)
            secondSummary = FMSnapshotIngestion.record(fullSnapshot, startingAt: firstSummary!.nextEntryIndex)
        }
        let oneShot = try await TestSupport.recordedFMEvents(contextID: "one-shot") {
            FMSnapshotIngestion.record(fullSnapshot)
        }

        XCTAssertEqual(firstSummary?.nextEntryIndex, 7)
        XCTAssertEqual(secondSummary, FMIngestionSummary(
            eventCount: 3, turnCount: 1, toolCallCount: 0,
            skippedSegmentCount: 0, nextEntryIndex: 10
        ))

        // The resumed run continues turn numbering: it is indistinguishable
        // from a single-shot ingestion, payloads and span identity included.
        XCTAssertEqual(resumed.map(\.payload), oneShot.map(\.payload))
        XCTAssertEqual(resumed.map(\.spanID), oneShot.map(\.spanID))
        XCTAssertEqual(resumed.map(\.parentSpanID), oneShot.map(\.parentSpanID))
    }

    func testOutsideARunIsASafeNoOp() async throws {
        let summary = FMSnapshotIngestion.record(SnapshotFixtures.canonical)
        XCTAssertEqual(summary, FMIngestionSummary(
            eventCount: 0, turnCount: 0, toolCallCount: 0,
            skippedSegmentCount: 0, nextEntryIndex: 10
        ))
    }

    func testSessionLabelFlowsIntoSpanIdentity() async throws {
        let configuration = FMTracingConfiguration(sessionLabel: "draft")
        let events = try await TestSupport.recordedFMEvents {
            FMSnapshotIngestion.record(SnapshotFixtures.canonical, configuration: configuration)
        }
        XCTAssertEqual(events[1].spanID, "fm[draft].turn.0")
        XCTAssertEqual(events[2].spanID, "fm[draft].turn.0.tool.WeatherTool.0")
        XCTAssertEqual(events[2].parentSpanID, "fm[draft].turn.0")
    }
}
