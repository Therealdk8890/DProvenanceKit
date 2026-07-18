// Outer compiler gate mirrors the FM session sources: on Swift 6.0/6.1 those files
// compile out, so tests referencing their types must compile out with them (#57).
#if compiler(>=6.2)
#if canImport(FoundationModels)
import XCTest
import Foundation
import FoundationModels
import DProvenanceKit
@testable import DProvenanceFoundationModels

/// Session-wrapper behavior that needs no model runtime: init seams, turn
/// counter seeding, dedupe bookkeeping, passthrough surface.
final class TracedSessionModelFreeTests: XCTestCase {
    func testInitWithTranscriptSeedsTurnCounter() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires the macOS 26 SDK") }
        let session = TracedLanguageModelSession(transcript: try TranscriptFixtures.canonical())
        XCTAssertEqual(
            session.context.state.withLock { $0.turnIndex }, 2,
            "Two prompts in history: the next live turn must be fm.turn.2, aligning with post-hoc ingestion"
        )
        XCTAssertTrue(session.context.liveToolTracing)
    }

    func testWrappingInitDisablesLiveToolTracingAndSeedsTurns() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires the macOS 26 SDK") }
        let base = LanguageModelSession(transcript: try TranscriptFixtures.canonical())
        let session = TracedLanguageModelSession(wrapping: base)
        XCTAssertFalse(
            session.context.liveToolTracing,
            "Pre-existing tools cannot be re-wrapped; tool events come from reconciliation"
        )
        XCTAssertEqual(session.context.state.withLock { $0.turnIndex }, 2)
        XCTAssertTrue(session.base === base)
    }

    func testRecordProvenanceSweepsWholeTranscriptViaReconciliationSeam() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires the macOS 26 SDK") }
        let session = TracedLanguageModelSession(wrapping: LanguageModelSession(transcript: try TranscriptFixtures.canonical()))

        nonisolated(unsafe) var summary: FMIngestionSummary?
        let events = try await TestSupport.recordedFMEvents {
            summary = session.recordProvenance()
        }

        XCTAssertEqual(summary?.eventCount, 7)
        XCTAssertEqual(summary?.turnCount, 2)
        XCTAssertEqual(summary?.toolCallCount, 1)
        XCTAssertEqual(events.map { $0.payload.typeIdentifier }, [
            "fm_instructions", "fm_prompt", "fm_tool_call", "fm_tool_output",
            "fm_response", "fm_prompt", "fm_response",
        ])
        XCTAssertEqual(events[2].spanID, "fm.turn.0.tool.WeatherTool.0")
        XCTAssertEqual(events[2].parentSpanID, "fm.turn.0")
        XCTAssertEqual(events[5].spanID, "fm.turn.1")
    }

    func testRepeatedRecordProvenanceAddsNothing() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires the macOS 26 SDK") }
        let session = TracedLanguageModelSession(wrapping: LanguageModelSession(transcript: try TranscriptFixtures.canonical()))

        nonisolated(unsafe) var second: FMIngestionSummary?
        nonisolated(unsafe) var third: FMIngestionSummary?
        let events = try await TestSupport.recordedFMEvents {
            _ = session.recordProvenance()
            second = session.recordProvenance()
            third = session.recordProvenance()
        }
        XCTAssertEqual(events.count, 7, "Dedupe by entry id: repeated sweeps add nothing")
        XCTAssertEqual(second?.eventCount, 0)
        XCTAssertEqual(third?.eventCount, 0)
        XCTAssertEqual(second?.nextEntryIndex, 7)
    }

    func testSimulatedLiveRecordingIsDedupedByReconciliation() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires the macOS 26 SDK") }
        let session = TracedLanguageModelSession(wrapping: LanguageModelSession(transcript: try TranscriptFixtures.canonical()))

        // Simulate what a live turn 0 would have registered: the prompt was
        // recorded pre-await and both tool events were recorded by the
        // session-owned TracedTool.
        session.context.state.withLock { state in
            state.promptRecordedTurns.insert(0)
            state.liveToolEventKeys.insert(
                FMToolCaptureContext.toolEventKey(kind: "call", turn: 0, toolName: "WeatherTool", invocation: 0)
            )
            state.liveToolEventKeys.insert(
                FMToolCaptureContext.toolEventKey(kind: "output", turn: 0, toolName: "WeatherTool", invocation: 0)
            )
        }

        nonisolated(unsafe) var summary: FMIngestionSummary?
        let events = try await TestSupport.recordedFMEvents {
            summary = session.recordProvenance()
        }
        XCTAssertEqual(summary?.eventCount, 4)
        XCTAssertEqual(events.map { $0.payload.typeIdentifier }, [
            "fm_instructions", "fm_response", "fm_prompt", "fm_response",
        ])
    }

    func testRecordProvenanceOutsideARunIsSafe() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires the macOS 26 SDK") }
        let session = TracedLanguageModelSession(wrapping: LanguageModelSession(transcript: try TranscriptFixtures.canonical()))
        let summary = session.recordProvenance()
        XCTAssertEqual(summary.eventCount, 0)
        XCTAssertEqual(summary.nextEntryIndex, 7)

        // Nothing was marked recorded, so a later in-run sweep still works.
        XCTAssertEqual(session.context.state.withLock { $0.recordedEntryIDs.count }, 0)
    }

    func testDynamicMemberLookupAndPassthrough() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires the macOS 26 SDK") }
        let base = LanguageModelSession(transcript: try TranscriptFixtures.canonical())
        let session = TracedLanguageModelSession(wrapping: base)
        // Compare against the base session's own transcript: the session
        // normalizes the input transcript on init (it regenerates the
        // instructions entry's toolDefinitions from its live tools array).
        XCTAssertEqual(session.transcript, base.transcript)
        XCTAssertFalse(session.isResponding)
        XCTAssertFalse(session[dynamicMember: \.isResponding])
        XCTAssertEqual(session[dynamicMember: \.transcript], base.transcript)
    }

    func testTracedFactoryBuildsWrappedSession() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires the macOS 26 SDK") }
        let session = LanguageModelSession.traced(instructions: "Be terse.")
        XCTAssertTrue(session.context.liveToolTracing)
        XCTAssertEqual(session.context.state.withLock { $0.turnIndex }, 0)
        XCTAssertTrue(session.transcript.contains { entry in
            if case .instructions = entry { return true }
            return false
        })
    }
}
#endif
#endif  // compiler(>=6.2)
