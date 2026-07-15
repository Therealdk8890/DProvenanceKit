import Foundation
import DProvenanceKit

// Keep this @main entry point out of a file named main.swift. Xcode's generated
// package scheme otherwise treats it as top-level code for iOS builds.
// A runnable end-to-end tour of the core loop: Run → Record → Query → Diff → Detect.
// `git clone && swift run Quickstart` prints a visible trace and a regression. This
// file also serves as a compile-check of the documented public API — if a README
// snippet drifts from the real signatures, this stops building.

/// Your own reasoning vocabulary. `typeIdentifier` is the stable key diffing and
/// querying are defined over; payloads can evolve, identifiers cannot.
enum MyAIDecision: TraceableEvent {
    case documentEvaluated(documentID: String, score: Double)
    case conflictDetected(reason: String)
    case finalDecisionMade(approved: Bool)

    var typeIdentifier: String {
        switch self {
        case .documentEvaluated: return "documentEvaluated"
        case .conflictDetected: return "conflictDetected"
        case .finalDecisionMade: return "finalDecisionMade"
        }
    }

    var priority: TracePriority {
        switch self {
        case .conflictDetected, .finalDecisionMade: return .critical
        case .documentEvaluated: return .structural
        }
    }
}

@main
struct Quickstart {
    // `main` is main-actor-isolated under @main; run the demo off it so the recording
    // closures stay nonisolated (Swift 6 would otherwise flag sending them across the
    // boundary). A real app records from its own nonisolated/background contexts.
    static func main() async throws {
        try await demo()
    }

    nonisolated static func demo() async throws {
        let store = InMemoryTraceStore<MyAIDecision>()

        print("DProvenanceKit Quickstart")
        print("=========================\n")

        // 1 + 2. Record a run and get its id back so we can fetch it for diffing.
        let (_, runA) = await DProvenanceKit<MyAIDecision>.runReturningID(contextID: "caseA", store: store) { _ in
            DProvenanceKit<MyAIDecision>.record(.documentEvaluated(documentID: "DocA", score: 0.95))
            DProvenanceKit<MyAIDecision>.record(.conflictDetected(reason: "timeline_inconsistency"))
            DProvenanceKit<MyAIDecision>.record(.finalDecisionMade(approved: false))
        }

        // A second run where the document-evaluation step went missing — the kind of
        // silent drift DPK is built to catch.
        let (_, runB) = await DProvenanceKit<MyAIDecision>.runReturningID(contextID: "caseB", store: store) { _ in
            DProvenanceKit<MyAIDecision>.record(.conflictDetected(reason: "timeline_inconsistency"))
            DProvenanceKit<MyAIDecision>.record(.finalDecisionMade(approved: false))
        }

        // 3. Fetch both runs straight back by id — the loop closes from the run call.
        guard let a = try await store.getRun(id: runA), let b = try await store.getRun(id: runB) else {
            fatalError("Quickstart: recorded runs should be fetchable by id")
        }
        print("Run A: \(a.events.map(\.payload.typeIdentifier).joined(separator: " → "))")
        print("Run B: \(b.events.map(\.payload.typeIdentifier).joined(separator: " → "))\n")

        // 4. Diff the two reasoning paths.
        let diff = TraceDiffEngine<MyAIDecision>().diff(base: a, comparison: b, minimumPriority: .structural)
        print("Structural diff (A → B):")
        if diff.changes.isEmpty {
            print("  (identical)")
        } else {
            for change in diff.changes {
                print("  \(change.kind): \(change.typeIdentifier)")
            }
        }
        print("")

        // 5. Detect regressions declaratively with a batteries-included rule.
        let detector = AnomalyDetector(store: store)
        let rule = MissingSupportRule<MyAIDecision>(
            name: "UnsupportedConflict",
            whenPresent: "conflictDetected",
            isMissing: "documentEvaluated"
        )
        let anomalies = try await detector.detectAnomalies(rules: [rule])
        print("Anomalies (\(rule.name)):")
        if anomalies.isEmpty {
            print("  (none)")
        } else {
            for anomaly in anomalies {
                print("  🚨 \(anomaly.description)")
            }
        }
    }
}
