import Foundation

/// Human-facing projection of an existing `ProofPackDocument` + `TraceAttestation`.
/// Matches `schemas/verification-receipt.schema.json`.
///
/// Not a cryptographic artifact. JSON Schema validates structure; status requires the
/// `VerificationInvariant` evaluator plus proof-pack / attestation integrity checks.
/// **Verified does not mean the claim is objectively true** — only that integrity-protected
/// provenance satisfied the declared invariant.
public struct VerificationReceipt: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable, Equatable {
        case verified
        case incomplete
        case tampered
    }

    public struct Claim: Codable, Equatable, Sendable {
        public let text: String

        public init(text: String) {
            self.text = text
        }
    }

    public struct Source: Codable, Equatable, Sendable {
        public let name: String
        public let contentHash: String
        public let role: String?

        enum CodingKeys: String, CodingKey {
            case name
            case contentHash = "content_hash"
            case role
        }

        public init(name: String, contentHash: String, role: String? = nil) {
            self.name = name
            self.contentHash = contentHash
            self.role = role
        }
    }

    public struct Step: Codable, Equatable, Sendable {
        public let type: ClaimPathStepType
        public let label: String

        public init(type: ClaimPathStepType, label: String) {
            self.type = type
            self.label = label
        }

        public init(type: ClaimPathStepType) {
            self.type = type
            self.label = type.defaultLabel
        }
    }

    public struct Integrity: Codable, Equatable, Sendable {
        public let evidence: Bool
        public let trace: Bool
        public let filesUnchanged: Bool

        enum CodingKeys: String, CodingKey {
            case evidence
            case trace
            case filesUnchanged = "files_unchanged"
        }

        public init(evidence: Bool, trace: Bool, filesUnchanged: Bool) {
            self.evidence = evidence
            self.trace = trace
            self.filesUnchanged = filesUnchanged
        }

        public var allPassed: Bool { evidence && trace && filesUnchanged }
    }

    public struct AttestationRef: Codable, Equatable, Sendable {
        public let receiptID: String
        public let shortHash: String
        public let runID: String?
        public let contextID: String?
        public let traceDigest: String?
        public let keyID: String?

        enum CodingKeys: String, CodingKey {
            case receiptID = "receipt_id"
            case shortHash = "short_hash"
            case runID = "run_id"
            case contextID = "context_id"
            case traceDigest = "trace_digest"
            case keyID = "key_id"
        }

        public init(
            receiptID: String,
            shortHash: String,
            runID: String? = nil,
            contextID: String? = nil,
            traceDigest: String? = nil,
            keyID: String? = nil
        ) {
            self.receiptID = receiptID
            self.shortHash = shortHash
            self.runID = runID
            self.contextID = contextID
            self.traceDigest = traceDigest
            self.keyID = keyID
        }
    }

    public struct Projection: Codable, Equatable, Sendable {
        public let from: String
        public let proofPackVersion: Int?

        enum CodingKeys: String, CodingKey {
            case from
            case proofPackVersion = "proof_pack_version"
        }

        public init(from: String = "proof_pack", proofPackVersion: Int? = nil) {
            self.from = from
            self.proofPackVersion = proofPackVersion
        }
    }

    public let version: String
    public let claim: Claim
    public let status: Status
    public let statusReason: String?
    public let sources: [Source]
    public let steps: [Step]
    public let integrity: Integrity
    public let attestation: AttestationRef
    public let invariantID: String
    public let projection: Projection

    enum CodingKeys: String, CodingKey {
        case version
        case claim
        case status
        case statusReason = "status_reason"
        case sources
        case steps
        case integrity
        case attestation
        case invariantID = "invariant_id"
        case projection
    }

    public init(
        version: String = "1.0",
        claim: Claim,
        status: Status,
        statusReason: String? = nil,
        sources: [Source],
        steps: [Step],
        integrity: Integrity,
        attestation: AttestationRef,
        invariantID: String,
        projection: Projection
    ) {
        self.version = version
        self.claim = claim
        self.status = status
        self.statusReason = statusReason
        self.sources = sources
        self.steps = steps
        self.integrity = integrity
        self.attestation = attestation
        self.invariantID = invariantID
        self.projection = projection
    }

    public static func decodeJSON(_ data: Data) throws -> VerificationReceipt {
        try JSONDecoder().decode(VerificationReceipt.self, from: data)
    }

    public func jsonData(prettyPrinted: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        var formatting: JSONEncoder.OutputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if prettyPrinted { formatting.insert(.prettyPrinted) }
        encoder.outputFormatting = formatting
        return try encoder.encode(self)
    }
}
