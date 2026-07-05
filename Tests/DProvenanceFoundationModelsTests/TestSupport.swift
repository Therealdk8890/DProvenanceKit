import Foundation
import XCTest
import DProvenanceKit
@testable import DProvenanceFoundationModels

enum TestSupport {
    /// Fetches the events recorded into a store, in causal (sequence) order.
    /// Expects at most one run per contextID.
    static func events<T: TraceableEvent>(
        in store: InMemoryTraceStore<T>,
        contextID: String
    ) async throws -> [TraceEvent<T>] {
        let runs = try await store.queryRuns(TraceQueryDSL<T>().filter(contextID: contextID))
        XCTAssertLessThanOrEqual(runs.count, 1, "Expected at most one run for \(contextID)")
        return runs.first?.events ?? []
    }

    /// Runs a synchronous body inside a typed FM run and returns what landed.
    static func recordedFMEvents(
        contextID: String = "fm-test",
        _ body: () -> Void
    ) async throws -> [TraceEvent<FoundationModelTraceEvent>] {
        let store = InMemoryTraceStore<FoundationModelTraceEvent>()
        DProvenanceKit<FoundationModelTraceEvent>.runSync(contextID: contextID, store: store) {
            body()
        }
        return try await events(in: store, contextID: contextID)
    }

    /// Async-body variant for tool/session tests.
    static func recordedFMEventsAsync(
        contextID: String = "fm-test",
        _ body: () async throws -> Void
    ) async throws -> [TraceEvent<FoundationModelTraceEvent>] {
        let store = InMemoryTraceStore<FoundationModelTraceEvent>()
        try await DProvenanceKit<FoundationModelTraceEvent>.run(contextID: contextID, store: store) {
            try await body()
        }
        return try await events(in: store, contextID: contextID)
    }

    static func sortedKeysJSON(_ event: FoundationModelTraceEvent) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(event), as: UTF8.self)
    }
}

/// The canonical multi-turn snapshot used across mapper and ingestion tests:
/// instructions, a tool-fanout turn (two same-name calls plus a second tool),
/// a plain second turn, and a trailing unknown entry inside turn 1.
enum SnapshotFixtures {
    static let canonical = FMTranscriptSnapshot(entries: [
        .instructions(
            text: "Be terse.",
            toolNames: ["WeatherTool"],
            toolDescriptions: ["WeatherTool": "Gets weather"]
        ),
        .prompt(text: "Weather in Paris and Lyon?", options: nil, responseFormatName: nil),
        .toolCalls([
            FMTranscriptSnapshot.Call(toolName: "WeatherTool", argumentsJSON: #"{"city":"Paris"}"#),
            FMTranscriptSnapshot.Call(toolName: "WeatherTool", argumentsJSON: #"{"city":"Lyon"}"#),
            FMTranscriptSnapshot.Call(toolName: "AirQualityTool", argumentsJSON: #"{"city":"Paris"}"#),
        ]),
        .toolOutput(toolName: "WeatherTool", text: "Sunny"),
        .toolOutput(toolName: "AirQualityTool", text: "Good"),
        .toolOutput(toolName: "WeatherTool", text: "Rainy"),
        .response(text: "Sunny in Paris, rainy in Lyon.", assetIDCount: 0),
        .prompt(text: "And tomorrow?", options: nil, responseFormatName: nil),
        .response(text: "Cloudy.", assetIDCount: 0),
        .unknown(description: "(Mystery) new entry kind"),
    ])
}
