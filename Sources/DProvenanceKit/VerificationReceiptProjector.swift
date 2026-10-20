import Foundation

/// Projects a `VerificationReceipt` from an existing `ProofPackDocument` through a
/// `VerificationInvariant`. Introduces no new cryptography — integrity comes from
/// `ProofPackDocument.verify` (and optional recomputed source digests); status comes from
/// that integrity summary plus invariant evaluation.
///
/// Status rules (locked, Phase 0 / 1C):
/// 1. Integrity failure → `tampered` (takes precedence over incomplete)
/// 2. Else invariant failure → `incomplete`
/// 3. Else → `verified`
///
/// **Verified ≠ claim objectively true.** It means integrity-protected provenance
/// satisfied the declared invariant.
public enum VerificationReceiptProjector {
    /// Inputs beyond the proof pack itself. Claim text and claim-path steps are projection
    /// inputs because they are not a fixed field of `ProofPackDocument` (instrumented
    /// `typeIdentifier` / role mapping lives with the consumer; Phase 1C accepts the
    /// already-projected step list).
    public struct Input: Sendable {
        public var pack: ProofPackDocument
        public var invariant: VerificationInvariant
        public var claimText: String
        public var steps: [VerificationReceipt.Step]
        /// Optional trusted-key pin forwarded to `ProofPackDocument.verify`.
        public var trustedKeyIDs: Set<String>?
        /// Optional recomputed source digests keyed by artifact `role`. If supplied,
        /// every artifact role must be present and uniquely identify its bound digest.
        /// A digest mismatch marks `files_unchanged` and `evidence` false; omitted or
        /// ambiguous roles make the receipt incomplete rather than implying tampering.
        public var currentSourceDigestsByRole: [String: String]?
        /// Optional display-name overrides keyed by artifact role (fixtures use filenames).
        public var sourceDisplayNamesByRole: [String: String]?
        /// Test / correlation overrides. When nil, derived from the attestation.
        public var receiptIDOverride: String?
        public var shortHashOverride: String?

        public init(
            pack: ProofPackDocument,
            invariant: VerificationInvariant = .claimPathV1,
            claimText: String,
            steps: [VerificationReceipt.Step],
            trustedKeyIDs: Set<String>? = nil,
            currentSourceDigestsByRole: [String: String]? = nil,
            sourceDisplayNamesByRole: [String: String]? = nil,
            receiptIDOverride: String? = nil,
            shortHashOverride: String? = nil
        ) {
            self.pack = pack
            self.invariant = invariant
            self.claimText = claimText
            self.steps = steps
            self.trustedKeyIDs = trustedKeyIDs
            self.currentSourceDigestsByRole = currentSourceDigestsByRole
            self.sourceDisplayNamesByRole = sourceDisplayNamesByRole
            self.receiptIDOverride = receiptIDOverride
            self.shortHashOverride = shortHashOverride
        }
    }

    /// Convenience: claim-path steps with optional omission of `.verify` (incomplete shape).
    public static func claimPathSteps(includeVerify: Bool = true) -> [VerificationReceipt.Step] {
        var steps: [VerificationReceipt.Step] = [
            .init(type: .evidence),
            .init(type: .extract)
        ]
        if includeVerify {
            steps.append(.init(type: .verify))
        }
        steps.append(.init(type: .claim))
        return steps
    }

    public static func project(_ input: Input) -> VerificationReceipt {
        let packVerification = input.pack.verify(trustedKeyIDs: input.trustedKeyIDs)
        let invariantResult = input.invariant.evaluate(steps: input.steps)

        // A role-keyed source-digest map cannot disambiguate two artifacts that share a
        // role but bind different bytes. Do not misclassify that missing identity as tampering.
        let digestsByRole = Dictionary(grouping: input.pack.artifacts, by: \.role)
        let ambiguousSourceRoles = input.currentSourceDigestsByRole == nil ? Set<String>() :
            Set(digestsByRole.compactMap { role, artifacts in
                Set(artifacts.map(\.sha256)).count > 1 ? role : nil
            })
        let effectiveSourceDigests = input.currentSourceDigestsByRole.map { current in
            current.filter { !ambiguousSourceRoles.contains($0.key) }
        }
        let integrity = deriveIntegrity(
            pack: input.pack,
            verification: packVerification,
            currentSourceDigestsByRole: effectiveSourceDigests
        )
        let missingSourceRoles: [String] = effectiveSourceDigests.map { current in
            Array(Set(input.pack.artifacts.map(\.role).filter { current[$0] == nil })).sorted()
        } ?? []

        let status: VerificationReceipt.Status
        let statusReason: String?
        if !integrity.allPassed {
            status = .tampered
            statusReason = tamperedReason(
                verification: packVerification,
                integrity: integrity
            )
        } else if !invariantResult.satisfied {
            status = .incomplete
            statusReason = invariantResult.reason
        } else if !missingSourceRoles.isEmpty || !ambiguousSourceRoles.isEmpty {
            status = .incomplete
            var reasons: [String] = []
            if !missingSourceRoles.isEmpty {
                reasons.append("missing digests for artifact roles: " + missingSourceRoles.joined(separator: ", "))
            }
            if !ambiguousSourceRoles.isEmpty {
                reasons.append("role-keyed recheck cannot disambiguate roles with multiple artifact digests: "
                    + ambiguousSourceRoles.sorted().joined(separator: ", "))
            }
            statusReason = "Source digest recheck is incomplete; " + reasons.joined(separator: "; ") + "."
        } else {
            status = .verified
            statusReason = nil
        }

        let attestation = input.pack.attestation.attestation
        let runID = attestation.runID.uuidString.lowercased()
        let shortHash = input.shortHashOverride
            ?? String(attestation.traceDigest.prefix(8))
        let receiptID = input.receiptIDOverride
            ?? "vr-\(input.invariant.id)-\(runID)"

        let sources: [VerificationReceipt.Source] = input.pack.artifacts.map { artifact in
            let name = input.sourceDisplayNamesByRole?[artifact.role] ?? artifact.role
            return VerificationReceipt.Source(
                name: name,
                contentHash: artifact.sha256,
                role: artifact.role
            )
        }

        return VerificationReceipt(
            version: "1.0",
            claim: .init(text: input.claimText),
            status: status,
            statusReason: statusReason,
            sources: sources,
            steps: input.steps,
            integrity: integrity,
            attestation: .init(
                receiptID: receiptID,
                shortHash: shortHash,
                runID: runID,
                contextID: attestation.contextID,
                traceDigest: attestation.traceDigest,
                keyID: attestation.keyID
            ),
            invariantID: input.invariant.id,
            projection: .init(
                from: "proof_pack",
                proofPackVersion: input.pack.proofPackVersion
            )
        )
    }

    /// Shorthand for `project(Input(...))`.
    public static func project(
        pack: ProofPackDocument,
        invariant: VerificationInvariant = .claimPathV1,
        claimText: String,
        steps: [VerificationReceipt.Step],
        trustedKeyIDs: Set<String>? = nil,
        currentSourceDigestsByRole: [String: String]? = nil,
        sourceDisplayNamesByRole: [String: String]? = nil,
        receiptIDOverride: String? = nil,
        shortHashOverride: String? = nil
    ) -> VerificationReceipt {
        project(
            Input(
                pack: pack,
                invariant: invariant,
                claimText: claimText,
                steps: steps,
                trustedKeyIDs: trustedKeyIDs,
                currentSourceDigestsByRole: currentSourceDigestsByRole,
                sourceDisplayNamesByRole: sourceDisplayNamesByRole,
                receiptIDOverride: receiptIDOverride,
                shortHashOverride: shortHashOverride
            )
        )
    }

    // MARK: - Integrity summary

    /// Maps `ProofPackDocument.verify` (+ optional source re-hash) onto receipt integrity
    /// flags. Fail-closed: unchecked dimensions after a hard failure are not reported true.
    static func deriveIntegrity(
        pack: ProofPackDocument,
        verification: ProofPackVerification,
        currentSourceDigestsByRole: [String: String]?
    ) -> VerificationReceipt.Integrity {
        var evidence = true
        var trace = true
        var filesUnchanged = true

        if verification.isValid {
            evidence = true
            trace = verification.attestation?.isValid ?? true
            filesUnchanged = true
        } else {
            switch verification.failure {
            case .attestationFailed:
                trace = false
                evidence = false
                filesUnchanged = false
            case .artifactDigestMismatch:
                trace = verification.attestation?.isValid ?? false
                evidence = false
                filesUnchanged = false
            case .artifactNotBound, .malformedArtifact, .noArtifacts, .unsupportedVersion, .roleBindingRequired:
                trace = verification.attestation?.isValid ?? false
                evidence = false
                filesUnchanged = verification.attestation?.isValid == true
            case .none:
                evidence = false
                trace = false
                filesUnchanged = false
            }
        }

        if let current = currentSourceDigestsByRole {
            for artifact in pack.artifacts {
                if let recomputed = current[artifact.role], recomputed != artifact.sha256 {
                    filesUnchanged = false
                    evidence = false
                }
            }
        }

        return VerificationReceipt.Integrity(
            evidence: evidence,
            trace: trace,
            filesUnchanged: filesUnchanged
        )
    }

    private static func tamperedReason(
        verification: ProofPackVerification,
        integrity: VerificationReceipt.Integrity
    ) -> String {
        if case .artifactDigestMismatch = verification.failure {
            return "Source content hash no longer matches the digest bound in the signed proof pack (files_unchanged=false); attestation integrity checks fail."
        }
        if case .attestationFailed = verification.failure {
            return "Bound evidence or attestation no longer validates (trace attestation verification failed)."
        }
        var failed: [String] = []
        if !integrity.evidence { failed.append("evidence=false") }
        if !integrity.trace { failed.append("trace=false") }
        if !integrity.filesUnchanged { failed.append("files_unchanged=false") }
        if failed.isEmpty {
            return "Bound evidence or attestation no longer validates (integrity check failed)."
        }
        return "Bound evidence or attestation no longer validates (" + failed.joined(separator: ", ") + ")."
    }
}

extension ProofPackDocument {
    /// Project a `VerificationReceipt` from this pack through `invariant` (default
    /// `claim-path-v1`). See `VerificationReceiptProjector`.
    public func verificationReceipt(
        invariant: VerificationInvariant = .claimPathV1,
        claimText: String,
        steps: [VerificationReceipt.Step],
        trustedKeyIDs: Set<String>? = nil,
        currentSourceDigestsByRole: [String: String]? = nil,
        sourceDisplayNamesByRole: [String: String]? = nil,
        receiptIDOverride: String? = nil,
        shortHashOverride: String? = nil
    ) -> VerificationReceipt {
        VerificationReceiptProjector.project(
            pack: self,
            invariant: invariant,
            claimText: claimText,
            steps: steps,
            trustedKeyIDs: trustedKeyIDs,
            currentSourceDigestsByRole: currentSourceDigestsByRole,
            sourceDisplayNamesByRole: sourceDisplayNamesByRole,
            receiptIDOverride: receiptIDOverride,
            shortHashOverride: shortHashOverride
        )
    }
}
