#if canImport(FoundationModels)
import XCTest
import Foundation
import FoundationModels
import DProvenanceKit
@testable import DProvenanceFoundationModels

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
private struct MappingStubTool: Tool {
    typealias Arguments = GeneratedContent
    var description: String { "stub" }
    func call(arguments: GeneratedContent) async throws -> String { "ok" }
}

private enum StubFailure: Error { case boom }

final class FMErrorAndAvailabilityMappingTests: XCTestCase {
    func testEveryGenerationErrorCaseMapsToItsKind() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires the macOS 26 SDK") }
        typealias GenError = LanguageModelSession.GenerationError
        let context = GenError.Context(debugDescription: "ctx")
        let cases: [(any Error, FMGenerationErrorKind)] = [
            (GenError.exceededContextWindowSize(context), .exceededContextWindowSize),
            (GenError.assetsUnavailable(context), .assetsUnavailable),
            (GenError.guardrailViolation(context), .guardrailViolation),
            (GenError.unsupportedGuide(context), .unsupportedGuide),
            (GenError.unsupportedLanguageOrLocale(context), .unsupportedLanguageOrLocale),
            (GenError.decodingFailure(context), .decodingFailure),
            (GenError.rateLimited(context), .rateLimited),
            (GenError.concurrentRequests(context), .concurrentRequests),
            (GenError.refusal(GenError.Refusal(transcriptEntries: []), context), .refusal),
        ]
        for (error, expectedKind) in cases {
            let payload = FMGenerationErrorPayload(error: error, turnIndex: 3, redaction: .full)
            XCTAssertEqual(payload.kind, expectedKind)
            XCTAssertEqual(payload.message.text, "ctx", "Message is the Context.debugDescription")
            XCTAssertEqual(payload.turnIndex, 3)
        }
    }

    func testRefusalMappingNeverFetchesExplanation() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires the macOS 26 SDK") }
        typealias GenError = LanguageModelSession.GenerationError
        let refusal = GenError.Refusal(transcriptEntries: [
            .prompt(Transcript.Prompt(segments: [TranscriptFixtures.text("p")])),
        ])
        // The mapping init is synchronous by construction, so the async
        // `explanation` (which triggers a generation) cannot be awaited.
        let payload = FMGenerationErrorPayload(
            error: GenError.refusal(refusal, GenError.Context(debugDescription: "refused")),
            turnIndex: 0,
            redaction: .full
        )
        XCTAssertEqual(payload.kind, .refusal)
        XCTAssertEqual(payload.message.text, "refused")
        XCTAssertNil(payload.toolName)
        XCTAssertNil(
            payload.refusalEntryCount,
            "Deviation from spec, probe wins: the SDK exposes no public accessor for Refusal's transcript entries"
        )
    }

    func testToolCallErrorCarriesToolName() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires the macOS 26 SDK") }
        let error = LanguageModelSession.ToolCallError(tool: MappingStubTool(), underlyingError: StubFailure.boom)
        let payload = FMGenerationErrorPayload(error: error, turnIndex: 1, redaction: .full)
        XCTAssertEqual(payload.kind, .toolCallError)
        XCTAssertEqual(payload.toolName, "MappingStubTool")
        XCTAssertEqual(payload.message.text, StubFailure.boom.localizedDescription)
    }

    func testUnknownErrorMapsToUnknown() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires the macOS 26 SDK") }
        let error = NSError(domain: "test", code: 7, userInfo: [NSLocalizedDescriptionKey: "kaput"])
        let payload = FMGenerationErrorPayload(error: error, turnIndex: 0, redaction: .full)
        XCTAssertEqual(payload.kind, .unknown)
        XCTAssertEqual(payload.message.text, "kaput")
        XCTAssertNil(payload.toolName)
    }

    func testMessageRedactionFollowsErrorMessagesPolicy() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires the macOS 26 SDK") }
        typealias GenError = LanguageModelSession.GenerationError
        let error = GenError.guardrailViolation(GenError.Context(debugDescription: "sensitive"))

        let omitted = FMGenerationErrorPayload(error: error, turnIndex: 0, redaction: .omitted)
        XCTAssertEqual(omitted.message.redaction, .omitted)
        XCTAssertNil(omitted.message.text)
        XCTAssertNil(omitted.message.sha256)

        let hashed = FMGenerationErrorPayload(error: error, turnIndex: 0, redaction: .hashed)
        XCTAssertEqual(hashed.message.redaction, .hashed)
        XCTAssertNil(hashed.message.text)
        XCTAssertNotNil(hashed.message.sha256)
    }

    func testUnavailableReasonIdentifiers() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires the macOS 26 SDK") }
        XCTAssertEqual(FMModelAvailabilityPayload.reasonIdentifier(.deviceNotEligible), "device_not_eligible")
        XCTAssertEqual(FMModelAvailabilityPayload.reasonIdentifier(.appleIntelligenceNotEnabled), "apple_intelligence_not_enabled")
        XCTAssertEqual(FMModelAvailabilityPayload.reasonIdentifier(.modelNotReady), "model_not_ready")
    }

    func testAvailabilityPayloadFromDefaultModel() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires the macOS 26 SDK") }
        let model = SystemLanguageModel.default
        let payload = FMModelAvailabilityPayload(model: model)
        XCTAssertEqual(payload.provider, "apple.foundationmodels")
        XCTAssertEqual(payload.isAvailable, model.isAvailable)
        XCTAssertEqual(payload.contextSize, model.contextSize)
        if payload.isAvailable {
            XCTAssertNil(payload.unavailableReason)
        } else {
            XCTAssertNotNil(payload.unavailableReason)
        }
    }

    func testRecordAvailabilityRecordsIntoAmbientRun() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires the macOS 26 SDK") }
        nonisolated(unsafe) var returned: Bool?
        let events = try await TestSupport.recordedFMEvents {
            returned = SystemLanguageModel.default.recordAvailability()
        }
        XCTAssertEqual(events.count, 1)
        guard case .modelAvailability(let payload) = events[0].payload else {
            return XCTFail("Expected fm_model_availability")
        }
        XCTAssertEqual(returned, payload.isAvailable)
        XCTAssertEqual(events[0].engineName, "FoundationModels")
    }
}
#endif
