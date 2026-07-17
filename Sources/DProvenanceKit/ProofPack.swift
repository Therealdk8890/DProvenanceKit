import CryptoKit
import Foundation

/// One artifact embedded in a proof pack: the exact bytes being vouched for, plus the
/// producer-declared SHA-256 that binds those bytes to the signed trace.
///
/// The digest is the binding key, not a trust anchor by itself — the verifier re-derives it
/// from the embedded bytes and then requires it to appear inside a signed event payload.
public struct ProofPackArtifact: Codable, Equatable, Sendable {
    /// How the artifact bytes are carried in `content`.
    public enum Encoding: String, Codable, Equatable, Sendable {
        /// `content` is the artifact interpreted as a UTF-8 string.
        case utf8
        /// `content` is the standard Base64 encoding of the artifact bytes.
        case base64
    }

    /// Producer-defined label for what the artifact is (for example `claim-proof-report`).
    /// Must be non-empty; the verifier rejects unlabeled artifacts.
    ///
    /// In a `proofPackVersion: 2` pack the `role` is signer-vouched: verification requires
    /// it to appear co-located with `sha256` in a signed event payload, so it cannot be
    /// relabeled after signing. In a v1 pack `role` is producer-asserted only (see
    /// `ProofPackBindingStrength`).
    public let role: String
    /// Informational media type (for example `application/json`). Not covered by any
    /// binding check in either version — a consumer must not treat it as signer-vouched.
    public let mediaType: String
    public let encoding: Encoding
    /// The artifact bytes, encoded per `encoding`.
    public let content: String
    /// Lowercase 64-hex SHA-256 of the decoded bytes. Uppercase digests are rejected as
    /// malformed rather than normalized — the verifier never repairs a producer's claim.
    public let sha256: String

    public init(
        role: String,
        mediaType: String,
        encoding: Encoding,
        content: String,
        sha256: String
    ) {
        self.role = role
        self.mediaType = mediaType
        self.encoding = encoding
        self.content = content
        self.sha256 = sha256
    }

    /// The artifact's exact bytes per `encoding`, or nil when `content` is not valid Base64.
    public func decodedContent() -> Data? {
        switch encoding {
        case .utf8:
            return Data(content.utf8)
        case .base64:
            return Data(base64Encoded: content)
        }
    }
}

/// A self-contained bundle for offline review: a signed trace attestation plus the artifact
/// bytes the trace vouches for (see `docs/PROOF_PACK.md`).
///
/// Wrapping adds nothing to the attestation's canonical or signed bytes — a document signed
/// before proof packs existed can be wrapped, and unwrapping never invalidates it. This holds
/// in both versions: v2 strengthens the *binding check* (the role must be co-located with the
/// digest in a signed payload), not the signed bytes, so any existing attestation whose trace
/// already records `{role, sha256}` per `docs/PROOF_PACK.md` can be wrapped as v2 without
/// re-signing.
public struct ProofPackDocument: Codable, Equatable, Sendable {
    /// The version new packs are stamped with by default. v2 binds the artifact `role`
    /// (not just its `sha256`) into what the signature covers; see `ProofPackVerifier`.
    public static let schemaVersion = 2
    /// The oldest `proofPackVersion` the verifier still accepts. v1 packs verify but bind
    /// only on digest presence, so their `role`/`mediaType` are producer-asserted — the
    /// verification result labels this via `ProofPackBindingStrength.valuePresenceOnly`.
    public static let minimumSupportedVersion = 1

    public let proofPackVersion: Int
    /// An unmodified `TraceAttestationDocument`; verified exactly as `dpk verify` does.
    public let attestation: TraceAttestationDocument
    /// Must contain at least one entry — a pack with no artifacts is just an attestation.
    public let artifacts: [ProofPackArtifact]

    public init(
        proofPackVersion: Int = ProofPackDocument.schemaVersion,
        attestation: TraceAttestationDocument,
        artifacts: [ProofPackArtifact]
    ) {
        self.proofPackVersion = proofPackVersion
        self.attestation = attestation
        self.artifacts = artifacts
    }

    public func jsonData(prettyPrinted: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        var formatting: JSONEncoder.OutputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if prettyPrinted { formatting.insert(.prettyPrinted) }
        encoder.outputFormatting = formatting
        return try encoder.encode(self)
    }

    public static func decodeJSON(_ data: Data) throws -> ProofPackDocument {
        try JSONDecoder().decode(ProofPackDocument.self, from: data)
    }

    /// Verify the pack. Pass `requireRoleBinding: true` to fail-close on packs whose `role`
    /// is not signer-vouched (any v1 pack), so a consumer that integrates on the pass/fail
    /// bit cannot be handed a value-presence-only pack with an attacker-chosen role.
    public func verify(
        trustedKeyIDs: Set<String>? = nil,
        requireRoleBinding: Bool = false
    ) -> ProofPackVerification {
        ProofPackVerifier.verify(self, trustedKeyIDs: trustedKeyIDs, requireRoleBinding: requireRoleBinding)
    }
}

/// Why a single artifact entry is unusable before any cryptography runs.
public enum ProofPackArtifactDefect: String, Sendable, Equatable {
    case emptyRole
    /// The declared digest is not exactly 64 lowercase hex characters.
    case malformedDigest
    /// `content` could not be decoded per the declared `encoding`.
    case undecodableContent
}

public enum ProofPackVerificationFailure: Sendable, Equatable {
    case unsupportedVersion
    case noArtifacts
    case malformedArtifact(index: Int, reason: ProofPackArtifactDefect)
    /// The embedded attestation failed verification; artifact checks never ran, because
    /// binding against an unsigned or altered trace would certify nothing.
    case attestationFailed(TraceAttestationVerificationFailure)
    /// The recomputed SHA-256 of the embedded bytes does not equal the declared digest.
    case artifactDigestMismatch(index: Int)
    /// The declared digest does not appear as a string leaf in any signed event payload
    /// (v1), or the digest is not co-located with the artifact's `role` (v2).
    case artifactNotBound(index: Int)
    /// The caller required role-bound (v2) verification, but the pack is a v1 pack whose
    /// binding covers only the digest — its `role` is producer-asserted, not signer-vouched.
    case roleBindingRequired
}

extension ProofPackVerificationFailure: CustomStringConvertible {
    public var description: String {
        switch self {
        case .unsupportedVersion:
            return "unsupportedVersion"
        case .noArtifacts:
            return "noArtifacts"
        case .malformedArtifact(let index, let reason):
            return "malformedArtifact(index: \(index), reason: \(reason.rawValue))"
        case .attestationFailed(let underlying):
            return "attestationFailed(\(underlying.rawValue))"
        case .artifactDigestMismatch(let index):
            return "artifactDigestMismatch(index: \(index))"
        case .artifactNotBound(let index):
            return "artifactNotBound(index: \(index))"
        case .roleBindingRequired:
            return "roleBindingRequired"
        }
    }
}

/// How strongly the signature covers an artifact's binding — the difference between "the
/// signer vouched for these bytes under this role" and "the signer vouched for these bytes,
/// and the producer asserts this role."
public enum ProofPackBindingStrength: String, Sendable, Equatable {
    /// v2: the artifact's `role` and `sha256` were found co-located in a signed event
    /// payload, so the signature covers the bytes-to-role binding. A relabel after
    /// signing fails verification.
    case roleBound
    /// v1: only the artifact's `sha256` was found in a signed payload. The bytes are
    /// signer-vouched, but `role` (and `mediaType`) are producer-asserted and could have
    /// been changed after signing without invalidating the pack. Re-issue as v2 to bind
    /// the role.
    case valuePresenceOnly
}

/// Where a verified artifact is anchored in the signed trace: the first event whose payload
/// carries the artifact's digest (v1) or its digest co-located with its role (v2).
public struct ProofPackArtifactBinding: Sendable, Equatable {
    public let artifactIndex: Int
    public let role: String
    public let sha256: String
    /// Zero-based position of the binding event in `trace.events`.
    public let eventIndex: Int
    public let eventTypeIdentifier: String
    /// Whether the signature covers this artifact's `role`, or only its bytes.
    public let strength: ProofPackBindingStrength

    public init(
        artifactIndex: Int,
        role: String,
        sha256: String,
        eventIndex: Int,
        eventTypeIdentifier: String,
        strength: ProofPackBindingStrength
    ) {
        self.artifactIndex = artifactIndex
        self.role = role
        self.sha256 = sha256
        self.eventIndex = eventIndex
        self.eventTypeIdentifier = eventTypeIdentifier
        self.strength = strength
    }
}

public struct ProofPackVerification: Sendable, Equatable {
    public let isValid: Bool
    /// The underlying attestation outcome, or nil when the pack was rejected before the
    /// attestation was checked (version or artifact well-formedness).
    public let attestation: TraceAttestationVerification?
    /// One entry per artifact, in artifact order. Empty unless `isValid`.
    public let bindings: [ProofPackArtifactBinding]
    public let failure: ProofPackVerificationFailure?

    public init(
        isValid: Bool,
        attestation: TraceAttestationVerification?,
        bindings: [ProofPackArtifactBinding],
        failure: ProofPackVerificationFailure?
    ) {
        self.isValid = isValid
        self.attestation = attestation
        self.bindings = bindings
        self.failure = failure
    }

    /// The weakest binding strength across all artifacts, or nil when the pack is invalid
    /// (no bindings). `valuePresenceOnly` here means at least one artifact's role is
    /// producer-asserted, not signer-vouched — surface it before trusting the role.
    public var bindingStrength: ProofPackBindingStrength? {
        guard isValid, !bindings.isEmpty else { return nil }
        return bindings.contains { $0.strength == .valuePresenceOnly } ? .valuePresenceOnly : .roleBound
    }
}

public enum ProofPackVerifier {
    private static let hexDigits = Set("0123456789abcdef")

    /// Fail-closed verification per `docs/PROOF_PACK.md`: version check, artifact
    /// well-formedness, attestation verification (including trusted-key pinning), then per
    /// artifact a declared-digest check and a binding check against the signed payloads.
    /// Every artifact must bind; the first failure stops the run.
    public static func verify(
        _ pack: ProofPackDocument,
        trustedKeyIDs: Set<String>? = nil,
        requireRoleBinding: Bool = false
    ) -> ProofPackVerification {
        func failure(
            _ reason: ProofPackVerificationFailure,
            attestation: TraceAttestationVerification? = nil
        ) -> ProofPackVerification {
            ProofPackVerification(
                isValid: false,
                attestation: attestation,
                bindings: [],
                failure: reason
            )
        }

        guard pack.proofPackVersion >= ProofPackDocument.minimumSupportedVersion,
              pack.proofPackVersion <= ProofPackDocument.schemaVersion else {
            return failure(.unsupportedVersion)
        }
        // v2 binds the role alongside the digest; v1 binds digest presence only. The
        // version is validated above, so anything below the current schema is exactly v1.
        let packBindsRole = pack.proofPackVersion >= 2
        // Caller policy: reject a value-presence-only (v1) pack up front, before spending
        // cryptography on a binding it has already declared insufficient.
        guard !requireRoleBinding || packBindsRole else {
            return failure(.roleBindingRequired)
        }
        guard !pack.artifacts.isEmpty else {
            return failure(.noArtifacts)
        }

        // Well-formedness before any cryptography. Digests must already be lowercase hex:
        // normalizing case here would silently accept a claim the producer never made.
        var decodedContents: [Data] = []
        for (index, artifact) in pack.artifacts.enumerated() {
            guard !artifact.role.isEmpty else {
                return failure(.malformedArtifact(index: index, reason: .emptyRole))
            }
            guard artifact.sha256.count == 64,
                  artifact.sha256.allSatisfy(hexDigits.contains) else {
                return failure(.malformedArtifact(index: index, reason: .malformedDigest))
            }
            guard let bytes = artifact.decodedContent() else {
                return failure(.malformedArtifact(index: index, reason: .undecodableContent))
            }
            decodedContents.append(bytes)
        }

        // The attestation must stand on its own — same semantics as `dpk verify`, including
        // trusted-key pinning. Any failure fails the pack.
        let attestationResult = pack.attestation.verify(trustedKeyIDs: trustedKeyIDs)
        if let underlying = attestationResult.failure {
            return failure(.attestationFailed(underlying), attestation: attestationResult)
        }
        guard attestationResult.isValid else {
            // Defensive: an invalid attestation always carries a reason today; if that
            // invariant ever breaks, refuse the pack rather than bind against it.
            return failure(.attestationFailed(.invalidSignature), attestation: attestationResult)
        }

        // Payloads were already structurally validated by attestation verification; a payload
        // that fails to parse here simply binds nothing (fail-closed).
        let payloads: [Any?] = pack.attestation.trace.events.map { event in
            guard let data = event.payloadJSON.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        }

        var bindings: [ProofPackArtifactBinding] = []
        for (index, artifact) in pack.artifacts.enumerated() {
            let recomputed = TraceAttestationCanonicalizer.hex(
                SHA256.hash(data: decodedContents[index])
            )
            guard recomputed == artifact.sha256 else {
                return failure(.artifactDigestMismatch(index: index), attestation: attestationResult)
            }
            guard let eventIndex = payloads.firstIndex(where: { payload in
                guard let payload else { return false }
                if packBindsRole {
                    // v2: the role must be signer-vouched, so a signed payload object must
                    // carry this artifact's role under a `role` key beside its digest under
                    // a `sha256` key — a relabel after signing leaves no such object.
                    return containsRoleBinding(payload, sha256: artifact.sha256, role: artifact.role)
                }
                return containsStringLeaf(payload, equalTo: artifact.sha256)
            }) else {
                return failure(.artifactNotBound(index: index), attestation: attestationResult)
            }
            bindings.append(ProofPackArtifactBinding(
                artifactIndex: index,
                role: artifact.role,
                sha256: artifact.sha256,
                eventIndex: eventIndex,
                eventTypeIdentifier: pack.attestation.trace.events[eventIndex].typeIdentifier,
                strength: packBindsRole ? .roleBound : .valuePresenceOnly
            ))
        }

        return ProofPackVerification(
            isValid: true,
            attestation: attestationResult,
            bindings: bindings,
            failure: nil
        )
    }

    /// Walks a parsed JSON value and reports whether any string leaf — at any depth, inside
    /// objects or arrays — equals `target` exactly. The verifier matches the value, not the
    /// schema, so any event type can carry the binding.
    private static func containsStringLeaf(_ value: Any, equalTo target: String) -> Bool {
        switch value {
        case let string as String:
            return string == target
        case let array as [Any]:
            return array.contains { containsStringLeaf($0, equalTo: target) }
        case let object as [String: Any]:
            return object.values.contains { containsStringLeaf($0, equalTo: target) }
        default:
            return false
        }
    }

    /// Reports whether some JSON object in `value` has a `role` key equal to `role` AND a
    /// `sha256` key equal to `sha256` — the canonical shape a producer records per
    /// `docs/PROOF_PACK.md` (`{"role": "...", "sha256": "..."}`).
    ///
    /// The check matches these two SPECIFIC keys, not arbitrary sibling strings. Binding the
    /// role's value against any string in the object would let an attacker relabel an
    /// artifact to any other string the signer happened to co-locate (a `status`, a `stage`,
    /// a free-form note), none of which the signer vouched as the artifact's *role*. Keying
    /// the check on `role`/`sha256` is what actually makes the role signer-vouched — and
    /// requiring both in the same object stops splicing one artifact's digest onto another's
    /// role from elsewhere in the same signed trace.
    private static func containsRoleBinding(_ value: Any, sha256: String, role: String) -> Bool {
        switch value {
        case let object as [String: Any]:
            if (object["sha256"] as? String) == sha256, (object["role"] as? String) == role {
                return true
            }
            return object.values.contains { containsRoleBinding($0, sha256: sha256, role: role) }
        case let array as [Any]:
            return array.contains { containsRoleBinding($0, sha256: sha256, role: role) }
        default:
            return false
        }
    }
}
