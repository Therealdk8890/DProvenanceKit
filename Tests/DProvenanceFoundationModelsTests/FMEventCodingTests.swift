import XCTest
import DProvenanceKit
@testable import DProvenanceFoundationModels

/// Schema lock: the golden literals below ARE the wire shape. Payload
/// evolution is additive optional fields only — an expected-string change
/// here means the contract broke.
final class FMEventCodingTests: XCTestCase {
    private static let full = FMRedactedText("abc", redaction: .full)
    private static let hashed = FMRedactedText("abc", redaction: .hashed)

    private static let goldens: [(event: FoundationModelTraceEvent, json: String)] = [
        (
            .instructions(FMInstructionsPayload(content: full, toolNames: ["WeatherTool"], toolDescriptions: ["WeatherTool": "abc"])),
            #"{"instructions":{"_0":{"content":{"redaction":"full","sha256":"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad","text":"abc","utf8Count":3},"toolDescriptions":{"WeatherTool":"abc"},"toolNames":["WeatherTool"]}}}"#
        ),
        (
            .prompt(FMPromptPayload(content: full, options: FMGenerationOptionsSnapshot(temperature: 0.5, maximumResponseTokens: 100, sampling: .greedy), responseFormatName: "abc", turnIndex: 0)),
            #"{"prompt":{"_0":{"content":{"redaction":"full","sha256":"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad","text":"abc","utf8Count":3},"options":{"maximumResponseTokens":100,"sampling":"greedy","temperature":0.5},"responseFormatName":"abc","turnIndex":0}}}"#
        ),
        (
            .toolCall(FMToolCallPayload(toolName: "WeatherTool", arguments: full, turnIndex: 0, invocationIndex: 0)),
            #"{"toolCall":{"_0":{"arguments":{"redaction":"full","sha256":"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad","text":"abc","utf8Count":3},"invocationIndex":0,"toolName":"WeatherTool","turnIndex":0}}}"#
        ),
        (
            .toolOutput(FMToolOutputPayload(toolName: "WeatherTool", content: hashed, isError: false, turnIndex: 0, invocationIndex: 0)),
            #"{"toolOutput":{"_0":{"content":{"redaction":"hashed","sha256":"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad","utf8Count":3},"invocationIndex":0,"isError":false,"toolName":"WeatherTool","turnIndex":0}}}"#
        ),
        (
            .response(FMResponsePayload(content: full, assetIDCount: 1, turnIndex: 0)),
            #"{"response":{"_0":{"assetIDCount":1,"content":{"redaction":"full","sha256":"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad","text":"abc","utf8Count":3},"turnIndex":0}}}"#
        ),
        (
            .generationError(FMGenerationErrorPayload(kind: .refusal, message: full, toolName: nil, refusalEntryCount: 2, turnIndex: 1)),
            #"{"generationError":{"_0":{"kind":"refusal","message":{"redaction":"full","sha256":"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad","text":"abc","utf8Count":3},"refusalEntryCount":2,"turnIndex":1}}}"#
        ),
        (
            .modelAvailability(FMModelAvailabilityPayload(isAvailable: true, unavailableReason: nil, contextSize: 4096)),
            #"{"modelAvailability":{"_0":{"contextSize":4096,"isAvailable":true,"provider":"apple.foundationmodels"}}}"#
        ),
        (
            .streamSnapshot(FMStreamSnapshotPayload(snapshotIndex: 3, contentUTF8Count: 42, turnIndex: 1)),
            #"{"streamSnapshot":{"_0":{"contentUTF8Count":42,"snapshotIndex":3,"turnIndex":1}}}"#
        ),
        (
            .unknownEntry(FMUnknownEntryPayload(kindDescription: .omitted, turnIndex: nil)),
            #"{"unknownEntry":{"_0":{"kindDescription":{"redaction":"omitted"}}}}"#
        ),
    ]

    func testGoldenJSONFixtures() throws {
        for golden in Self.goldens {
            XCTAssertEqual(try TestSupport.sortedKeysJSON(golden.event), golden.json)
        }
        XCTAssertEqual(Self.goldens.count, 9)
    }

    func testCodableRoundTripEveryCase() throws {
        let decoder = JSONDecoder()
        for golden in Self.goldens {
            let encoded = try JSONEncoder().encode(golden.event)
            let decoded = try decoder.decode(FoundationModelTraceEvent.self, from: encoded)
            XCTAssertEqual(decoded, golden.event)

            let fromGolden = try decoder.decode(
                FoundationModelTraceEvent.self, from: Data(golden.json.utf8)
            )
            XCTAssertEqual(fromGolden, golden.event)
        }
    }

    func testEraseToAnyPreservesIdentityAndIsDeterministic() throws {
        let decoder = JSONDecoder()
        for golden in Self.goldens {
            let erased = golden.event.eraseToAny()
            XCTAssertEqual(erased.typeIdentifier, golden.event.typeIdentifier)
            XCTAssertEqual(erased.priorityValue, golden.event.priority.rawValue)
            XCTAssertEqual(erased.priority, golden.event.priority)
            XCTAssertEqual(erased.rawJSON, golden.json)

            let secondErase = golden.event.eraseToAny()
            XCTAssertEqual(erased.rawJSON, secondErase.rawJSON, "rawJSON must be byte-identical across encodes")

            let decoded = try decoder.decode(FoundationModelTraceEvent.self, from: Data(erased.rawJSON.utf8))
            XCTAssertEqual(decoded, golden.event)
        }
    }
}
