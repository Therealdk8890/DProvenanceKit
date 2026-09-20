import Foundation

/// Canonical claim-path step types for `VerificationInvariant` matching and
/// `VerificationReceipt.steps`. Do not expand without a new invariant id.
///
/// Distinct from causal / completeness / fidelity invariants under `Verification/`.
public enum ClaimPathStepType: String, Codable, Sendable, Equatable, CaseIterable {
    case evidence
    case extract
    case verify
    case claim

    /// Default UI label matching golden fixtures under `fixtures/verification-receipt/`.
    public var defaultLabel: String {
        switch self {
        case .evidence: return "Evidence"
        case .extract: return "Extract"
        case .verify: return "Verify"
        case .claim: return "Claim"
        }
    }
}

/// Machine-readable verification requirements shared by VerificationReceipt projection
/// consumers (DPK runtime, CaseClarity UI, CI Action, golden fixtures).
///
/// Matches `schemas/verification-invariant.schema.json`. JSON Schema validates shape;
/// `evaluate(steps:)` validates semantics.
public struct VerificationInvariant: Codable, Equatable, Sendable {
    public let id: String
    public let version: String
    public let description: String?
    public let requiredSteps: [ClaimPathStepType]
    public let mustInclude: [ClaimPathStepType]
    public let ordering: [OrderingConstraint]

    public struct OrderingConstraint: Codable, Equatable, Sendable {
        public let before: ClaimPathStepType
        public let after: ClaimPathStepType

        public init(before: ClaimPathStepType, after: ClaimPathStepType) {
            self.before = before
            self.after = after
        }
    }

    public struct Evaluation: Equatable, Sendable {
        public let satisfied: Bool
        public let reason: String?

        public init(satisfied: Bool, reason: String?) {
            self.satisfied = satisfied
            self.reason = reason
        }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case version
        case description
        case requiredSteps = "required_steps"
        case mustInclude = "must_include"
        case ordering
    }

    public init(
        id: String,
        version: String = "1.0",
        description: String? = nil,
        requiredSteps: [ClaimPathStepType],
        mustInclude: [ClaimPathStepType],
        ordering: [OrderingConstraint]
    ) {
        self.id = id
        self.version = version
        self.description = description
        self.requiredSteps = requiredSteps
        self.mustInclude = mustInclude
        self.ordering = ordering
    }

    /// Canonical `claim-path-v1` — field-for-field match of
    /// `fixtures/verification-receipt/invariant-claim-path-v1.json`.
    public static let claimPathV1 = VerificationInvariant(
        id: "claim-path-v1",
        version: "1.0",
        description: "Minimal claim-path invariant for Verification Receipt projection. Shared by DPK runtime, CaseClarity, dprovenancekit-action, and golden fixtures.",
        requiredSteps: [.evidence, .extract, .verify, .claim],
        mustInclude: [.verify],
        ordering: [
            OrderingConstraint(before: .evidence, after: .extract),
            OrderingConstraint(before: .extract, after: .verify),
            OrderingConstraint(before: .verify, after: .claim)
        ]
    )

    public static func decodeJSON(_ data: Data) throws -> VerificationInvariant {
        try JSONDecoder().decode(VerificationInvariant.self, from: data)
    }

    public func jsonData(prettyPrinted: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        var formatting: JSONEncoder.OutputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if prettyPrinted { formatting.insert(.prettyPrinted) }
        encoder.outputFormatting = formatting
        return try encoder.encode(self)
    }

    /// Evaluates whether projected `steps` satisfy `required_steps`, `must_include`, and
    /// `ordering`. Ordering uses first-occurrence indices of each step type.
    public func evaluate(steps: [VerificationReceipt.Step]) -> Evaluation {
        evaluate(stepTypes: steps.map(\.type))
    }

    public func evaluate(stepTypes types: [ClaimPathStepType]) -> Evaluation {
        for required in requiredSteps {
            guard types.contains(required) else {
                return Evaluation(
                    satisfied: false,
                    reason: "Required step type \(required.rawValue) is missing; \(id) invariant is not satisfied."
                )
            }
        }

        for required in mustInclude {
            guard types.contains(required) else {
                return Evaluation(
                    satisfied: false,
                    reason: "Required step type \(required.rawValue) is missing; \(id) invariant is not satisfied."
                )
            }
        }

        for constraint in ordering {
            guard let beforeIndex = types.firstIndex(of: constraint.before) else {
                return Evaluation(
                    satisfied: false,
                    reason: "Required step type \(constraint.before.rawValue) is missing; \(id) invariant is not satisfied."
                )
            }
            guard let afterIndex = types.firstIndex(of: constraint.after) else {
                return Evaluation(
                    satisfied: false,
                    reason: "Required step type \(constraint.after.rawValue) is missing; \(id) invariant is not satisfied."
                )
            }
            if beforeIndex >= afterIndex {
                return Evaluation(
                    satisfied: false,
                    reason: "Step ordering violated for \(id): \(constraint.before.rawValue) must appear before \(constraint.after.rawValue)."
                )
            }
        }

        return Evaluation(satisfied: true, reason: nil)
    }
}
