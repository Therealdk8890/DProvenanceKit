import Foundation

/// The outcome of one DProvenanceKit gate check, as OpenTelemetry attributes.
///
/// Swift twin of the Python `dprovenancekit.exporters.GateVerdict`. The `dpk.*`
/// attribute names, value shapes and bounds are a cross-SDK contract specified in
/// the Python repo's `conformance/OTEL_GENAI_MAPPING_v1.md` §3 and pinned by
/// `ConformanceHarness/vectors/otel_verdict_attributes.json`. Change them only by
/// regenerating that vector in the canonical Python repo.
///
/// Only `passed` is required; absent optional fields are omitted from the
/// attributes (never emitted as empty values).
public struct DPKGateVerdict: Sendable, Equatable {
    /// Version of the attribute contract emitted by `attributes()`.
    public static let schema = "dpk.gate.verdict.v1"
    /// Free-text attributes (reasoning, explanation) are cut to this many Unicode
    /// scalars, ending in "…", so every backend shows the same text.
    public static let maxTextLength = 1024
    /// Step-list attributes keep at most this many items; the count stays exact.
    public static let maxListItems = 64
    /// `gen_ai.evaluation.name` of the standard GenAI evaluation event.
    public static let evaluationName = "dpk_gate"
    /// Name of the standard OTel GenAI evaluation event.
    public static let evaluationEventName = "gen_ai.evaluation.result"
    /// `dpk.sdk.name` emitted by this SDK.
    public static let sdkName = "dprovenancekit-swift"

    public var passed: Bool
    public var regressionLevel: String?
    public var strength: Double?
    public var fingerprintMatch: Bool?
    public var goldenFingerprint: String?
    public var candidateFingerprint: String?
    public var goldenRunID: String?
    public var candidateRunID: String?
    public var maxRegressionLevel: String?
    public var allowDivergentSteps: Bool?
    public var profile: String?
    public var removedSteps: [String]
    public var addedSteps: [String]
    public var divergentSteps: [String]
    public var reasoning: String?
    /// Evidence references (attestation digest, signer key id, …), emitted as
    /// `dpk.evidence.<key>` in key order.
    public private(set) var evidence: [String: String]

    public enum Error: Swift.Error, Equatable, Sendable {
        /// Evidence keys must be non-empty and use only letters, digits, `_` or `.`.
        case invalidEvidenceKey(String)
        /// Gate JSON is missing the required `passed` field.
        case missingPassed
    }

    public init(passed: Bool,
                regressionLevel: String? = nil,
                strength: Double? = nil,
                fingerprintMatch: Bool? = nil,
                goldenFingerprint: String? = nil,
                candidateFingerprint: String? = nil,
                goldenRunID: String? = nil,
                candidateRunID: String? = nil,
                maxRegressionLevel: String? = nil,
                allowDivergentSteps: Bool? = nil,
                profile: String? = nil,
                removedSteps: [String] = [],
                addedSteps: [String] = [],
                divergentSteps: [String] = [],
                reasoning: String? = nil,
                evidence: [String: String] = [:]) throws {
        for key in evidence.keys where !Self.isValidEvidenceKey(key) {
            throw Error.invalidEvidenceKey(key)
        }
        self.passed = passed
        self.regressionLevel = regressionLevel
        self.strength = strength
        self.fingerprintMatch = fingerprintMatch
        self.goldenFingerprint = goldenFingerprint
        self.candidateFingerprint = candidateFingerprint
        self.goldenRunID = goldenRunID
        self.candidateRunID = candidateRunID
        self.maxRegressionLevel = maxRegressionLevel
        self.allowDivergentSteps = allowDivergentSteps
        self.profile = profile
        self.removedSteps = removedSteps
        self.addedSteps = addedSteps
        self.divergentSteps = divergentSteps
        self.reasoning = (reasoning?.isEmpty ?? true) ? nil : reasoning
        self.evidence = evidence
    }

    /// Builds a verdict from the object `dpk gate --json` prints (either SDK).
    ///
    /// Accepts output from older SDKs: run ids and profile are optional, and step
    /// lists come from `steps_by_change` (divergent = removed + added + reordered +
    /// ambiguous, in that order).
    public init(gateJSON object: [String: Any], evidence: [String: String] = [:]) throws {
        guard let passed = Self.bool(object["passed"]) else { throw Error.missingPassed }
        let steps = object["steps_by_change"] as? [String: Any] ?? [:]
        var divergent: [String] = []
        for kind in ["removed", "added", "reordered", "ambiguous"] {
            divergent += Self.strings(steps[kind])
        }
        try self.init(
            passed: passed,
            regressionLevel: Self.string(object["regression_level"]),
            strength: Self.double(object["strength"]),
            fingerprintMatch: Self.bool(object["fingerprint_match"]),
            goldenFingerprint: Self.string(object["golden_fingerprint"]),
            candidateFingerprint: Self.string(object["candidate_fingerprint"]),
            goldenRunID: Self.string(object["golden_run_id"]),
            candidateRunID: Self.string(object["candidate_run_id"]),
            maxRegressionLevel: Self.string(object["max_regression_level"]),
            allowDivergentSteps: Self.bool(object["allow_divergent_steps"]),
            profile: Self.string(object["profile"]),
            removedSteps: Self.strings(steps["removed"]),
            addedSteps: Self.strings(steps["added"]),
            divergentSteps: divergent,
            reasoning: Self.string(object["reasoning"]),
            evidence: evidence
        )
    }

    /// Builds a verdict from its JSON object form: the shape of Python's
    /// `GateVerdict.to_dict()` and of the `verdict` field in the conformance vector.
    public init(verdictObject object: [String: Any]) throws {
        guard let passed = Self.bool(object["passed"]) else { throw Error.missingPassed }
        var evidence: [String: String] = [:]
        for (key, value) in object["evidence"] as? [String: Any] ?? [:] {
            evidence[key] = Self.string(value)
        }
        try self.init(
            passed: passed,
            regressionLevel: Self.string(object["regression_level"]),
            strength: Self.double(object["strength"]),
            fingerprintMatch: Self.bool(object["fingerprint_match"]),
            goldenFingerprint: Self.string(object["golden_fingerprint"]),
            candidateFingerprint: Self.string(object["candidate_fingerprint"]),
            goldenRunID: Self.string(object["golden_run_id"]),
            candidateRunID: Self.string(object["candidate_run_id"]),
            maxRegressionLevel: Self.string(object["max_regression_level"]),
            allowDivergentSteps: Self.bool(object["allow_divergent_steps"]),
            profile: Self.string(object["profile"]),
            removedSteps: Self.strings(object["removed_steps"]),
            addedSteps: Self.strings(object["added_steps"]),
            divergentSteps: Self.strings(object["divergent_steps"]),
            reasoning: Self.string(object["reasoning"]),
            evidence: evidence
        )
    }

    /// Builds a verdict from `dpk gate --json` bytes.
    public init(gateJSONData data: Data, evidence: [String: String] = [:]) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Error.missingPassed
        }
        try self.init(gateJSON: object, evidence: evidence)
    }

    // MARK: - Views

    /// `"pass"` or `"fail"`.
    public var label: String { passed ? "pass" : "fail" }

    /// `1.0` for a pass, `0.0` for a fail.
    public var score: Double { passed ? 1.0 : 0.0 }

    /// One-line explanation, truncated to `maxTextLength`.
    public var summary: String {
        var parts = ["DProvenanceKit gate: " + (passed ? "PASS" : "FAIL")]
        if let regressionLevel { parts.append("severity " + regressionLevel) }
        if let fingerprintMatch { parts.append("fingerprint " + (fingerprintMatch ? "match" : "differs")) }
        if !removedSteps.isEmpty { parts.append("removed: " + removedSteps.joined(separator: ", ")) }
        if !addedSteps.isEmpty { parts.append("added: " + addedSteps.joined(separator: ", ")) }
        var text = parts.joined(separator: "; ")
        if let reasoning { text += ". " + reasoning }
        return Self.truncate(text)
    }

    /// The `dpk.*` span attributes, in contract order.
    public func attributes(sdkName: String = DPKGateVerdict.sdkName,
                           sdkVersion: String = OTelBridge.version) -> [OTLPKeyValue] {
        var attributes: [OTLPKeyValue] = [
            .string("dpk.schema", Self.schema),
            .string("dpk.sdk.name", sdkName),
            .string("dpk.sdk.version", sdkVersion),
            .bool("dpk.gate.passed", passed),
            .string("dpk.gate.verdict", label),
        ]
        if let regressionLevel { attributes.append(.string("dpk.gate.regression_level", regressionLevel)) }
        if let strength { attributes.append(.double("dpk.gate.strength", strength)) }
        if let fingerprintMatch { attributes.append(.bool("dpk.gate.fingerprint_match", fingerprintMatch)) }
        if let maxRegressionLevel {
            attributes.append(.string("dpk.gate.policy.max_regression_level", maxRegressionLevel))
        }
        if let allowDivergentSteps {
            attributes.append(.bool("dpk.gate.policy.allow_divergent_steps", allowDivergentSteps))
        }
        if let profile { attributes.append(.string("dpk.gate.policy.profile", profile)) }
        if let goldenRunID { attributes.append(.string("dpk.golden.run_id", goldenRunID)) }
        if let goldenFingerprint { attributes.append(.string("dpk.golden.fingerprint", goldenFingerprint)) }
        if let candidateRunID { attributes.append(.string("dpk.candidate.run_id", candidateRunID)) }
        if let candidateFingerprint {
            attributes.append(.string("dpk.candidate.fingerprint", candidateFingerprint))
        }
        for (key, steps) in [("dpk.gate.steps.removed", removedSteps),
                             ("dpk.gate.steps.added", addedSteps),
                             ("dpk.gate.steps.divergent", divergentSteps)] where !steps.isEmpty {
            attributes.append(.stringArray(key, Array(steps.prefix(Self.maxListItems))))
        }
        if !divergentSteps.isEmpty {
            attributes.append(.int("dpk.gate.steps.divergent_count", Int64(divergentSteps.count)))
        }
        if let reasoning { attributes.append(.string("dpk.gate.reasoning", Self.truncate(reasoning))) }
        for key in evidence.keys.sorted() {
            attributes.append(.string("dpk.evidence." + key, evidence[key]!))
        }
        return attributes
    }

    /// Attributes of the standard `gen_ai.evaluation.result` event: a binary
    /// evaluation (score 1.0/0.0, label pass/fail) any GenAI-aware backend reads.
    public func evaluationResultAttributes(name: String = DPKGateVerdict.evaluationName) -> [OTLPKeyValue] {
        [
            .string("gen_ai.evaluation.name", name),
            .double("gen_ai.evaluation.score.value", score),
            .string("gen_ai.evaluation.score.label", label),
            .string("gen_ai.evaluation.explanation", summary),
        ]
    }

    /// The `gen_ai.evaluation.result` span event, ready to append to an `OTLPSpan`.
    public func evaluationResultEvent(timeUnixNano: String,
                                      name: String = DPKGateVerdict.evaluationName) -> OTLPSpanEvent {
        OTLPSpanEvent(timeUnixNano: timeUnixNano,
                      name: Self.evaluationEventName,
                      attributes: evaluationResultAttributes(name: name))
    }

    // MARK: - Helpers

    static func isValidEvidenceKey(_ key: String) -> Bool {
        !key.isEmpty && key.unicodeScalars.allSatisfy {
            $0 == "_" || $0 == "." || CharacterSet.alphanumerics.contains($0)
        }
    }

    /// Truncates by Unicode scalars (the Python reference counts code points).
    static func truncate(_ text: String) -> String {
        let scalars = text.unicodeScalars
        guard scalars.count > maxTextLength else { return text }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars.prefix(maxTextLength - 1))
        view.append("\u{2026}")
        return String(view)
    }

    private static func string(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let text = value as? String { return text }
        return "\(value)"
    }

    private static func strings(_ value: Any?) -> [String] {
        (value as? [Any] ?? []).compactMap { string($0) }
    }

    private static func bool(_ value: Any?) -> Bool? {
        guard let value, !(value is NSNull) else { return nil }
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number.boolValue }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        guard let value, !(value is NSNull) else { return nil }
        if let number = value as? NSNumber { return number.doubleValue }
        return value as? Double
    }
}
