import Foundation
import DProvenanceKit

/// Minimal instrumented agent for the e2e decision-path demo.
///
/// Public SDK only (`DProvenanceKit` + `AnyTraceableEvent`). Each fixture step is one
/// recorded event; CRITICAL steps are what the CI gate refuses to lose.
public enum DecisionPathAgent {
    public struct Step: Sendable, Equatable {
        public let engine: String
        public let type: String
        public let priority: TracePriority
        public let detail: String

        public init(engine: String, type: String, priority: TracePriority, detail: String) {
            self.engine = engine
            self.type = type
            self.priority = priority
            self.detail = detail
        }
    }

    public struct PathFixture: Sendable, Equatable {
        public let contextID: String
        public let description: String
        public let steps: [Step]

        public init(contextID: String, description: String, steps: [Step]) {
            self.contextID = contextID
            self.description = description
            self.steps = steps
        }

        public var stepTypes: [String] { steps.map(\.type) }
    }

    /// Clean path: retrieve → verify (CRITICAL) → decide (CRITICAL).
    public static let baselinePath = PathFixture(
        contextID: "decision-path.baseline",
        description: "Clean instrumented decision path: retrieve → verify (CRITICAL) → decide (CRITICAL).",
        steps: [
            Step(engine: "Retriever", type: "sourcesRetrieved", priority: .structural, detail: "3 policy sources"),
            Step(engine: "Verifier", type: "claimVerified", priority: .critical, detail: "2 of 3 sources agree"),
            Step(engine: "Decider", type: "decisionMade", priority: .critical, detail: "approved"),
        ]
    )

    /// Deliberate regression: CRITICAL `claimVerified` removed (still decides).
    public static let candidateRegressed = PathFixture(
        contextID: "decision-path.candidate-regressed",
        description: "Deliberate regression: CRITICAL claimVerified step removed (still decides).",
        steps: [
            Step(engine: "Retriever", type: "sourcesRetrieved", priority: .structural, detail: "3 policy sources"),
            Step(engine: "Decider", type: "decisionMade", priority: .critical, detail: "approved"),
        ]
    )

    /// Record one fixture path into `store`. Returns the new run id.
    @discardableResult
    public static func recordPath(
        _ fixture: PathFixture,
        store: any TraceStore<AnyTraceableEvent>,
        contextID: String? = nil
    ) async -> UUID {
        let ctx = contextID ?? fixture.contextID
        let (_, runID) = await DProvenanceKit<AnyTraceableEvent>.runReturningID(
            contextID: ctx,
            store: store
        ) { _ in
            for step in fixture.steps {
                let payload = AnyTraceableEvent(
                    typeIdentifier: step.type,
                    priorityValue: step.priority.rawValue,
                    rawJSON: detailJSON(step.detail)
                )
                DProvenanceKit<AnyTraceableEvent>.withEngineSync(name: step.engine) {
                    _ = DProvenanceKit<AnyTraceableEvent>.record(payload)
                }
            }
        }
        return runID
    }

    private static func detailJSON(_ detail: String) -> String {
        let data = try! JSONSerialization.data(
            withJSONObject: ["detail": detail],
            options: [.sortedKeys]
        )
        return String(data: data, encoding: .utf8)!
    }
}
