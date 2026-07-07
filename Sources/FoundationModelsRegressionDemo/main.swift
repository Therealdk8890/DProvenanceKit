import Foundation
import DProvenanceKit
import DProvenanceFoundationModels

// ─────────────────────────────────────────────────────────────────────────────
// Foundation Models regression demo
//
// A weather agent, traced through the DProvenanceKit Foundation Models adapter
// (post-hoc transcript ingestion — the zero-refactor entry point). BEFORE an
// OS/model update it calls a tool for live conditions; AFTER the update the same
// prompt is answered from the model's prior — fluent, plausible, and wrong. No
// crash, no error, no failing assertion. Just a dropped reasoning step.
//
// This is the failure mode DProvenanceKit exists for. Run it:
//     swift run FoundationModelsRegressionDemo
//     swift run FoundationModelsRegressionDemo --gate   # exit non-zero (CI mode)
// ─────────────────────────────────────────────────────────────────────────────

@main
struct FoundationModelsRegressionDemo {

    /// The transcript captured BEFORE the update: the model called `getWeather`,
    /// read the live conditions, and answered from them.
    static let baseline = FMTranscriptSnapshot(entries: [
        .instructions(
            text: "You are a weather assistant. Use getWeather for live conditions.",
            toolNames: ["getWeather"],
            toolDescriptions: ["getWeather": "Current conditions for a city"]
        ),
        .prompt(text: "What's the weather in Paris right now?", options: nil, responseFormatName: nil),
        .toolCalls([.init(toolName: "getWeather", argumentsJSON: #"{"city":"Paris"}"#)]),
        .toolOutput(toolName: "getWeather", text: #"{"tempC":14,"conditions":"light rain"}"#),
        .response(text: "It's 14°C with light rain in Paris — bring a jacket.", assetIDCount: 0),
    ])

    /// The SAME prompt AFTER the update: the model skipped the tool and answered
    /// from memory. Same shape of reply, no tool call, no live data.
    static let candidate = FMTranscriptSnapshot(entries: [
        .instructions(
            text: "You are a weather assistant. Use getWeather for live conditions.",
            toolNames: ["getWeather"],
            toolDescriptions: ["getWeather": "Current conditions for a city"]
        ),
        .prompt(text: "What's the weather in Paris right now?", options: nil, responseFormatName: nil),
        .response(text: "It's sunny and about 22°C in Paris — a lovely day!", assetIDCount: 0),
    ])

    static func main() async throws {
        let gate = CommandLine.arguments.contains("--gate")
        let outPath = value(for: "--out=") ?? "fm-regression.json"

        print("""
        DProvenanceKit — Foundation Models regression demo
        ==================================================
        A weather agent traced via the Foundation Models adapter (post-hoc
        transcript ingestion). The candidate is the same agent after an OS/model
        update — it silently stopped calling its tool.
        """)

        let base = try await ingest(baseline, contextID: "weather-baseline")
        let cand = try await ingest(candidate, contextID: "weather-candidate")

        printRun("BASELINE  (macOS 26.0 · model 2025-09)", base)
        printRun("CANDIDATE (macOS 26.1 · model 2025-11)", cand)

        // 1. Structural diff — which reasoning steps appeared or disappeared.
        let diff = TraceDiffEngine<FoundationModelTraceEvent>().diff(base: base, comparison: cand)
        print("\nStructural diff (baseline → candidate):")
        let removed = diff.changes.filter { $0.kind == .removed }
        if removed.isEmpty {
            print("  (no steps removed)")
        } else {
            for change in removed {
                let name = base.events.first { $0.sequence == change.originalSequence }
                    .map { label($0.payload) } ?? change.typeIdentifier
                print("  removed: \(name)")
            }
        }

        // 2. Semantic alignment — behavioral equivalence + regression risk.
        let alignment = TraceAlignmentEngine(configuration: FoundationModelAlignment.configuration())
            .align(base: base, comparison: cand)
        let risk = alignment.regressionRisk
        print("\nSemantic alignment:")
        print("  regression risk: \(risk.level.rawValue.uppercased()) — \(risk.reasoning)")

        // 3. WebVisualizer export — a shareable, diffable artifact.
        let export = WebDiffExport.make(
            base: base, comparison: cand, alignment: alignment,
            baseLabel: "Before update", comparisonLabel: "After update", rootLabel: "Weather agent"
        )
        try export.jsonData().write(to: URL(fileURLWithPath: outPath))
        print("\nWebVisualizer export → \(outPath)")
        print("  open WebVisualizer, click \u{201C}Load JSON\u{201D}, and select that file.")

        // 4. CI gate — fail the build on a reasoning regression.
        let regressed = risk.level == .high || risk.level == .medium
        print("\nCI gate: \(regressed ? "\u{274C} FAILED \u{2014} reasoning regression detected" : "\u{2705} passed")")
        if regressed {
            print("  A dropped critical step (the getWeather tool call) changed the agent's")
            print("  behavior with no crash or error. In CI, `--gate` exits non-zero here.")
            if gate {
                FileHandle.standardError.write(Data("reasoning regression: \(risk.reasoning)\n".utf8))
                exit(1)
            }
        }
    }

    // MARK: - Helpers

    /// Ingest a transcript snapshot into a run and return it — mirrors the
    /// `session.recordProvenance()` post-hoc path with no live model.
    static func ingest(
        _ snapshot: FMTranscriptSnapshot,
        contextID: String
    ) async throws -> TraceRun<FoundationModelTraceEvent> {
        let store = InMemoryTraceStore<FoundationModelTraceEvent>()
        DProvenanceKit<FoundationModelTraceEvent>.runSync(contextID: contextID, store: store) {
            FMSnapshotIngestion.record(snapshot)
        }
        guard let run = try await store.queryRuns(TraceQueryDSL()).first else {
            throw DemoError.noRunRecorded(contextID)
        }
        return run
    }

    static func printRun(_ title: String, _ run: TraceRun<FoundationModelTraceEvent>) {
        print("\n\(title):")
        for event in run.events.sorted(by: { $0.sequence < $1.sequence }) {
            print("  → \(label(event.payload))")
        }
    }

    static func label(_ payload: FoundationModelTraceEvent) -> String {
        switch payload {
        case .instructions: return "instructions"
        case .prompt: return "prompt"
        case .toolCall(let call): return "tool call · \(call.toolName)"
        case .toolOutput(let output): return "tool output · \(output.toolName)"
        case .response: return "response"
        case .generationError(let error): return "generation error · \(error.kind.rawValue)"
        case .modelAvailability: return "model availability"
        case .streamSnapshot: return "stream snapshot"
        case .unknownEntry: return "unknown entry"
        }
    }

    static func value(for prefix: String) -> String? {
        CommandLine.arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }

    enum DemoError: Error { case noRunRecorded(String) }
}
