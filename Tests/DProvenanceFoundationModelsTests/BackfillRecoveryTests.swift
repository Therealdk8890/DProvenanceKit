// Outer compiler gate mirrors the FM session sources: on Swift 6.0/6.1 those files
// compile out, so tests referencing their types must compile out with them (#57).
#if compiler(>=6.2)
#if canImport(FoundationModels)
import XCTest
import FoundationModels
import DProvenanceKit
@testable import DProvenanceFoundationModels

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
private struct BackfillEchoTool: Tool {
    typealias Arguments = GeneratedContent
    var name: String { "EchoTool" }
    var description: String { "Echoes the message property." }
    func call(arguments: GeneratedContent) async throws -> String {
        "echo:\(try arguments.value(String.self, forProperty: "message"))"
    }
}

/// Pins the delivery-gated dedupe contract: capture attempts that soft-no-op
/// (no ambient run, or a run the recorder cannot deliver into) must not spend
/// dedupe bookkeeping — otherwise the documented `recordProvenance()` backfill
/// recovery silently records nothing. Model-free: sessions are constructed
/// from transcripts, never asked to generate.
final class BackfillRecoveryTests: XCTestCase {

    func testRecordProvenanceOutsideRunLeavesEverythingBackfillable() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires the macOS 26 SDK") }
        let session = TracedLanguageModelSession(
            wrapping: LanguageModelSession(transcript: try TranscriptFixtures.canonical())
        )

        // Outside any run: documented soft no-op — and it must not poison.
        let outside = session.recordProvenance()
        XCTAssertEqual(outside.eventCount, 0)

        // The documented recovery: the same call inside a run backfills the
        // FULL transcript.
        var insideCount = 0
        let events = try await TestSupport.recordedFMEventsAsync {
            insideCount = session.recordProvenance().eventCount
        }
        XCTAssertGreaterThan(insideCount, 0, "backfill after a soft no-op must record")
        XCTAssertEqual(insideCount, events.count)
        let types = Set(events.map { $0.payload.typeIdentifier })
        XCTAssertTrue(types.contains(FMEventType.instructions),
                      "fm_instructions must survive an out-of-run first touch")
        XCTAssertTrue(types.contains(FMEventType.prompt))
        XCTAssertTrue(types.contains(FMEventType.toolCall))

        // And the dedupe that the gating protects still works: a second
        // in-run sweep records nothing new.
        let again = try await TestSupport.recordedFMEventsAsync(contextID: "fm-test-second") {
            XCTAssertEqual(session.recordProvenance().eventCount, 0)
        }
        XCTAssertTrue(again.isEmpty)
    }

    func testCaptureContextReportsDeliveryHonestly() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires the macOS 26 SDK") }
        let context = FMToolCaptureContext(configuration: .default, startingTurnIndex: 0, liveToolTracing: true)
        let event = FoundationModelTraceEvent.modelAvailability(
            FMModelAvailabilityPayload(isAvailable: true)
        )

        // No ambient run, no captured run: must report undelivered.
        XCTAssertFalse(context.canDeliverNow())
        XCTAssertFalse(context.record(event, spanPath: []))

        // Inside a typed run: delivered, and the event actually lands.
        let landed = try await TestSupport.recordedFMEventsAsync(contextID: "fm-probe") {
            XCTAssertTrue(context.canDeliverNow())
            XCTAssertTrue(context.record(event, spanPath: []))
        }
        XCTAssertEqual(landed.count, 1)
    }

    func testTracedToolOutsideRunDoesNotClaimLiveCopies() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires the macOS 26 SDK") }
        let context = FMToolCaptureContext(configuration: .default, startingTurnIndex: 0, liveToolTracing: true)
        let traced = TracedTool(BackfillEchoTool(), context: context)
        let arguments = try GeneratedContent(json: #"{"message": "lost"}"#)

        // Invoke the session-owned tool with NO run anywhere: records no-op.
        _ = context.beginTurn(promptOrdinal: 0)
        _ = try await traced.call(arguments: arguments)

        // The live-copy dedupe keys must NOT have been claimed by the no-op,
        // so a later transcript reconciliation can still record the pair.
        XCTAssertFalse(context.hasLiveToolEvent(kind: "call", turn: 0, toolName: "EchoTool", invocation: 0))
        XCTAssertFalse(context.hasLiveToolEvent(kind: "output", turn: 0, toolName: "EchoTool", invocation: 0))

        // Inside a run the same invocation claims its keys as before.
        _ = try await TestSupport.recordedFMEventsAsync(contextID: "fm-tool-live") {
            _ = context.beginTurn(promptOrdinal: 1)
            _ = try await traced.call(arguments: arguments)
        }
        XCTAssertTrue(context.hasLiveToolEvent(kind: "call", turn: 1, toolName: "EchoTool", invocation: 0))
        XCTAssertTrue(context.hasLiveToolEvent(kind: "output", turn: 1, toolName: "EchoTool", invocation: 0))
    }
}
#endif
#endif  // compiler(>=6.2)
