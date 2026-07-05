#if canImport(FoundationModels)
import XCTest
import Foundation
import FoundationModels
import DProvenanceKit
@testable import DProvenanceFoundationModels

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
private struct EchoTool: Tool {
    typealias Arguments = GeneratedContent
    var description: String { "Echoes the message property." }
    func call(arguments: GeneratedContent) async throws -> String {
        "echo:\(try arguments.value(String.self, forProperty: "message"))"
    }
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
private struct CityArguments: ConvertibleFromGeneratedContent {
    let city: String
    init(_ content: GeneratedContent) throws {
        self.city = try content.value(String.self, forProperty: "city")
    }
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
private struct TypedTool: Tool {
    typealias Arguments = CityArguments
    var description: String { "Typed decode target." }
    var parameters: GenerationSchema {
        GenerationSchema(type: GeneratedContent.self, properties: [])
    }
    func call(arguments: CityArguments) async throws -> String {
        "weather:\(arguments.city)"
    }
}

private enum ToolFailure: Error, Equatable { case boom }

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
private struct ThrowingTool: Tool {
    typealias Arguments = GeneratedContent
    var description: String { "Always throws." }
    func call(arguments: GeneratedContent) async throws -> String {
        throw ToolFailure.boom
    }
}

final class TracedToolTests: XCTestCase {
    func testRecordsCallBeforeOutputWithCanonicalArgumentsUnderEachPolicy() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires the macOS 26 SDK") }
        let arguments = try GeneratedContent(json: #"{"message": "hi"}"#)

        for policy in [FMRedactionPolicy.full, .hashed, .omitted] {
            let traced = TracedTool(EchoTool(), configuration: FMTracingConfiguration(redaction: policy))
            let events = try await TestSupport.recordedFMEventsAsync {
                let output = try await traced.call(arguments: arguments)
                XCTAssertEqual(output, "echo:hi")
            }

            XCTAssertEqual(events.map { $0.payload.typeIdentifier }, ["fm_tool_call", "fm_tool_output"])
            guard case .toolCall(let call) = events[0].payload,
                  case .toolOutput(let output) = events[1].payload else {
                return XCTFail("Expected call then output")
            }
            XCTAssertEqual(call.arguments.redaction, policy.toolArguments)
            if policy.toolArguments == .full {
                XCTAssertEqual(call.arguments.text, arguments.jsonString)
            }
            XCTAssertEqual(call.invocationIndex, 0)
            XCTAssertFalse(output.isError)
            XCTAssertEqual(events[0].spanID, "fm.tool.EchoTool.0")
            XCTAssertEqual(events[1].spanID, "fm.tool.EchoTool.0")
        }
    }

    func testTypedArgumentsDecodeCorrectly() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires the macOS 26 SDK") }
        let traced = TracedTool(TypedTool())
        let events = try await TestSupport.recordedFMEventsAsync {
            let output = try await traced.call(arguments: try GeneratedContent(json: #"{"city": "Paris"}"#))
            XCTAssertEqual(output, "weather:Paris")
        }
        XCTAssertEqual(events.map { $0.payload.typeIdentifier }, ["fm_tool_call", "fm_tool_output"])
    }

    func testDecodeFailureRecordsCallThenErrorAndRethrows() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires the macOS 26 SDK") }
        let traced = TracedTool(TypedTool())
        let mismatched = try GeneratedContent(json: #"{"zip": "75001"}"#)
        let events = try await TestSupport.recordedFMEventsAsync {
            do {
                _ = try await traced.call(arguments: mismatched)
                XCTFail("Decode must throw")
            } catch {
                // Rethrown unchanged; the raw arguments were already captured.
            }
        }
        XCTAssertEqual(events.map { $0.payload.typeIdentifier }, ["fm_tool_call", "fm_generation_error"])
        guard case .toolCall(let call) = events[0].payload,
              case .generationError(let failure) = events[1].payload else {
            return XCTFail("Expected call then error")
        }
        XCTAssertEqual(call.arguments.text, mismatched.jsonString, "Raw arguments survive the decode failure")
        XCTAssertEqual(failure.kind, .toolCallError)
        XCTAssertEqual(failure.toolName, "TypedTool")
    }

    func testThrowingBaseRecordsErrorOutputAndRethrowsUnchanged() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires the macOS 26 SDK") }
        let traced = TracedTool(ThrowingTool())
        let events = try await TestSupport.recordedFMEventsAsync {
            do {
                _ = try await traced.call(arguments: try GeneratedContent(json: "{}"))
                XCTFail("Base tool must throw")
            } catch let error as ToolFailure {
                XCTAssertEqual(error, .boom, "Error must be rethrown unchanged")
            }
        }
        XCTAssertEqual(
            events.map { $0.payload.typeIdentifier },
            ["fm_tool_call", "fm_tool_output", "fm_generation_error"]
        )
        guard case .toolOutput(let output) = events[1].payload,
              case .generationError(let failure) = events[2].payload else {
            return XCTFail("Expected output then error")
        }
        XCTAssertTrue(output.isError)
        XCTAssertEqual(failure.kind, .toolCallError)
        XCTAssertEqual(failure.toolName, "ThrowingTool")
    }

    func testForwardsToolSurfaceExactly() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires the macOS 26 SDK") }
        let base = EchoTool()
        let traced = TracedTool(base)
        XCTAssertEqual(traced.name, base.name)
        XCTAssertEqual(traced.name, "EchoTool")
        XCTAssertEqual(traced.description, base.description)
        XCTAssertEqual(traced.includesSchemaInInstructions, base.includesSchemaInInstructions)
        XCTAssertEqual(traced.parameters.debugDescription, base.parameters.debugDescription)
        XCTAssertEqual(base.traced().name, "EchoTool")
    }

    /// The @concurrent-safety guarantee: a session-owned tool invoked from a
    /// detached task (no task-locals at all) still records into the armed
    /// run with the correct span identity.
    func testDetachedInvocationLandsInArmedRun() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires the macOS 26 SDK") }
        let context = FMToolCaptureContext(configuration: .default, startingTurnIndex: 0, liveToolTracing: true)
        let traced = TracedTool(EchoTool(), context: context)
        let arguments = try GeneratedContent(json: #"{"message": "detached"}"#)

        let events = try await TestSupport.recordedFMEventsAsync {
            _ = context.beginTurn(promptOrdinal: 0)
            let output = try await Task.detached {
                try await traced.call(arguments: arguments)
            }.value
            XCTAssertEqual(output, "echo:detached")
        }

        XCTAssertEqual(events.map { $0.payload.typeIdentifier }, ["fm_tool_call", "fm_tool_output"])
        XCTAssertEqual(events[0].spanID, "fm.turn.0.tool.EchoTool.0")
        XCTAssertEqual(events[0].parentSpanID, "fm.turn.0")
        XCTAssertEqual(events[1].spanID, "fm.turn.0.tool.EchoTool.0")
        XCTAssertEqual(events[1].parentSpanID, "fm.turn.0")
        XCTAssertEqual(events[0].engineName, "FoundationModels")
    }

    func testStandaloneCounterIncrementsPerInstance() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires the macOS 26 SDK") }
        let traced = TracedTool(EchoTool())
        let arguments = try GeneratedContent(json: #"{"message": "hi"}"#)
        let events = try await TestSupport.recordedFMEventsAsync {
            _ = try await traced.call(arguments: arguments)
            _ = try await traced.call(arguments: arguments)
        }
        XCTAssertEqual(events.count, 4)
        XCTAssertEqual(events[0].spanID, "fm.tool.EchoTool.0")
        XCTAssertEqual(events[2].spanID, "fm.tool.EchoTool.1")

        guard case .toolCall(let second) = events[2].payload else { return XCTFail("tool call") }
        XCTAssertEqual(second.invocationIndex, 1)
    }
}
#endif
