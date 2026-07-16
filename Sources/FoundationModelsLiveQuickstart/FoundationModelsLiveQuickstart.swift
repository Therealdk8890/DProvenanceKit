import Foundation
import DProvenanceFoundationModels

#if canImport(FoundationModels)
import FoundationModels
#endif

// Keep this @main entry point out of a file named main.swift. Xcode's generated
// package scheme otherwise treats it as top-level code for iOS builds.
@main
struct FoundationModelsLiveQuickstart {
    private enum GenerationOutcome: Sendable {
        case answer(String)
        case unavailable
        case failed(String)
    }

    static func main() async throws {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else {
            print("FoundationModelsLiveQuickstart requires iOS 26, macOS 26, or visionOS 26.")
            return
        }
        try await runLiveTrace()
        #else
        print("FoundationModelsLiveQuickstart requires an SDK that includes FoundationModels.")
        #endif
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    nonisolated private static func runLiveTrace() async throws {
        var promptArguments = Array(CommandLine.arguments.dropFirst())
        if promptArguments.first == "--" {
            promptArguments.removeFirst()
        }
        let suppliedPrompt = promptArguments.joined(separator: " ")
        let prompt = suppliedPrompt.isEmpty
            ? "In one sentence, explain what a software execution trace records."
            : suppliedPrompt
        let traceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dpk-foundation-model-\(UUID().uuidString).sqlite")
        let store = try SQLiteTraceStore<FoundationModelTraceEvent>(fileURL: traceURL)
        let model = SystemLanguageModel.default
        let configuration = FMTracingConfiguration(
            sessionLabel: "live-quickstart",
            recordAvailabilityOnFirstUse: false
        )
        let startedAt = Date()

        let (outcome, runID) = await FMTrace.runReturningID(
            contextID: "foundation-models-live-quickstart",
            store: store
        ) { _ -> GenerationOutcome in
            guard model.recordAvailability(configuration: configuration) else {
                return .unavailable
            }
            let session = LanguageModelSession.traced(
                model: model,
                instructions: "Answer accurately and in one short sentence.",
                configuration: configuration
            )
            do {
                return .answer(try await session.respond(to: prompt).content)
            } catch {
                return .failed(String(describing: error))
            }
        }

        try await store.flush()
        guard let run = try await store.getRun(id: runID) else {
            fatalError("DProvenanceKit did not return the run it just recorded.")
        }

        print("DProvenanceKit + Apple Foundation Models")
        print("========================================")
        print("Prompt: \(prompt)")
        switch outcome {
        case .answer(let answer):
            print("Answer: \(answer)")
        case .unavailable:
            print("Generation skipped: \(unavailableReason(in: run) ?? "model unavailable")")
        case .failed(let message):
            print("Generation failed: \(message)")
        }
        print("Elapsed generation + capture: \(String(format: "%.2f", Date().timeIntervalSince(startedAt)))s")
        print("\nCaptured trace (\(run.events.count) events):")
        for event in run.events.sorted(by: { $0.sequence < $1.sequence }) {
            print("  \(event.sequence). \(event.payload.typeIdentifier) [\(event.engineName)] "
                + "span=\(event.spanID ?? "root") — \(detail(for: event.payload))")
        }

        let drops = store.dropStats
        let standaloneArchive = await store.close()
        print("\nDropped events: \(drops.total); structural integrity preserved: \(drops.preservedIntegrity)")
        print("SQLite trace: \(traceURL.path)")
        print("Standalone archive complete: \(standaloneArchive)")
    }

    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    private static func unavailableReason(
        in run: TraceRun<FoundationModelTraceEvent>
    ) -> String? {
        for event in run.events {
            if case .modelAvailability(let payload) = event.payload,
               !payload.isAvailable {
                return payload.unavailableReason
            }
        }
        return nil
    }

    private static func detail(for payload: FoundationModelTraceEvent) -> String {
        switch payload {
        case .modelAvailability(let value):
            let contextSize = value.contextSize.map(String.init) ?? "unknown"
            return "available=\(value.isAvailable), contextSize=\(contextSize)"
        case .instructions(let value):
            return "text=\(value.content.text ?? "<redacted>")"
        case .prompt(let value):
            return "text=\(value.content.text ?? "<redacted>"), turn=\(value.turnIndex)"
        case .response(let value):
            return "text=\(value.content.text ?? "<redacted>"), turn=\(value.turnIndex)"
        case .toolCall(let value):
            return "tool=\(value.toolName), turn=\(value.turnIndex)"
        case .toolOutput(let value):
            return "tool=\(value.toolName), turn=\(value.turnIndex), error=\(value.isError)"
        case .generationError(let value):
            return "kind=\(value.kind.rawValue), turn=\(value.turnIndex)"
        case .streamSnapshot(let value):
            return "snapshot=\(value.snapshotIndex), turn=\(value.turnIndex)"
        case .unknownEntry:
            return "unrecognized transcript entry"
        }
    }
    #endif
}
