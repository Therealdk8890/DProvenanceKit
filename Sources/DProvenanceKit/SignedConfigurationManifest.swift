import Foundation
import CryptoKit

/// A public key and lifecycle policy supplied by an independently trusted source.
/// The manifest itself is never allowed to introduce or replace this trust anchor.
public struct DPKTrustedConfigurationKeyV1: Sendable, Equatable {
    public let publicKey: Data
    public let revoked: Bool
    public let notBeforeUnixSeconds: Int64?
    /// Exclusive expiry boundary, expressed as Unix seconds.
    public let expiresAtUnixSeconds: Int64?

    public init(
        publicKey: Data,
        revoked: Bool = false,
        notBeforeUnixSeconds: Int64? = nil,
        expiresAtUnixSeconds: Int64? = nil
    ) {
        self.publicKey = publicKey
        self.revoked = revoked
        self.notBeforeUnixSeconds = notBeforeUnixSeconds
        self.expiresAtUnixSeconds = expiresAtUnixSeconds
    }
}

/// Fail-closed verification of the detached Ed25519 dpk-config-manifest-v1 format.
public extension DPKConfigurationAuthorizationV1 {
    /// Verify a manifest using an external key policy and return the validated fingerprint.
    ///
    /// If a trusted key has a validity bound, verificationTimeUnixSeconds is required.
    /// Expiry is exclusive: a key is expired when verification time >= expiresAt.
    func verifySignedManifest(
        _ manifest: [String: Any],
        trustedKeys: [String: DPKTrustedConfigurationKeyV1],
        verificationTimeUnixSeconds: Int64? = nil
    ) throws -> String {
        let requiredFields: Set<String> = [
            "manifest_version",
            "algorithm",
            "key_id",
            "configuration_fingerprint",
            "signature"
        ]
        let fields = Set(manifest.keys)
        if let missing = requiredFields.subtracting(fields).sorted().first {
            throw DPKSignedConfigurationManifestError.manifestMissingField(missing)
        }
        if let unknown = fields.subtracting(requiredFields).sorted().first {
            throw DPKSignedConfigurationManifestError.manifestUnknownField(unknown)
        }

        guard let version = manifest["manifest_version"] as? String,
              version == "dpk-config-manifest-v1" else {
            throw DPKSignedConfigurationManifestError.unsupportedManifestVersion
        }
        guard let algorithm = manifest["algorithm"] as? String,
              algorithm == "Ed25519" else {
            throw DPKSignedConfigurationManifestError.unsupportedSignatureAlgorithm
        }
        guard let keyID = manifest["key_id"] as? String,
              Self.isValidManifestKeyID(keyID) else {
            throw DPKSignedConfigurationManifestError.invalidKeyID
        }
        guard let expectedFingerprint = manifest["configuration_fingerprint"] as? String,
              Self.isLowercaseHex(expectedFingerprint, count: 64) else {
            throw DPKSignedConfigurationManifestError.invalidManifestFingerprint
        }
        guard let signatureHex = manifest["signature"] as? String,
              Self.isLowercaseHex(signatureHex, count: 128),
              let signature = Self.decodeHex(signatureHex) else {
            throw DPKSignedConfigurationManifestError.invalidSignatureEncoding
        }

        let actualFingerprint = fingerprint
        guard Self.constantTimeEqual(
            Data(actualFingerprint.utf8),
            Data(expectedFingerprint.utf8)
        ) else {
            throw DPKSignedConfigurationManifestError.configurationFingerprintMismatch
        }

        guard let trustedKey = trustedKeys[keyID] else {
            throw DPKSignedConfigurationManifestError.untrustedKey
        }
        guard trustedKey.publicKey.count == 32 else {
            throw DPKSignedConfigurationManifestError.invalidTrustedKey
        }
        if trustedKey.revoked {
            throw DPKSignedConfigurationManifestError.keyRevoked
        }

        if trustedKey.notBeforeUnixSeconds != nil || trustedKey.expiresAtUnixSeconds != nil {
            guard let verificationTimeUnixSeconds else {
                throw DPKSignedConfigurationManifestError.keyPolicyTimeRequired
            }
            if let notBefore = trustedKey.notBeforeUnixSeconds,
               verificationTimeUnixSeconds < notBefore {
                throw DPKSignedConfigurationManifestError.keyNotYetValid
            }
            if let expiresAt = trustedKey.expiresAtUnixSeconds,
               verificationTimeUnixSeconds >= expiresAt {
                throw DPKSignedConfigurationManifestError.keyExpired
            }
        }

        let publicKey: Curve25519.Signing.PublicKey
        do {
            publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: trustedKey.publicKey)
        } catch {
            throw DPKSignedConfigurationManifestError.invalidTrustedKey
        }

        let domainSeparator = Data("DPK-CONFIG-MANIFEST-V1\n".utf8)
        let signedMessage = domainSeparator + canonicalJSON
        guard publicKey.isValidSignature(signature, for: signedMessage) else {
            throw DPKSignedConfigurationManifestError.signatureInvalid
        }
        return actualFingerprint
    }
}

private extension DPKConfigurationAuthorizationV1 {
    static func isValidManifestKeyID(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        guard !scalars.isEmpty, scalars.count <= 128 else { return false }
        func isAlphaNumeric(_ scalar: Unicode.Scalar) -> Bool {
            (48...57).contains(scalar.value)
                || (65...90).contains(scalar.value)
                || (97...122).contains(scalar.value)
        }
        guard isAlphaNumeric(scalars[0]) else { return false }
        return scalars.dropFirst().allSatisfy {
            isAlphaNumeric($0) || [45, 46, 58, 95].contains($0.value)
        }
    }

    static func isLowercaseHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    static func decodeHex(_ value: String) -> Data? {
        let bytes = Array(value.utf8)
        guard bytes.count.isMultiple(of: 2) else { return nil }
        var result = Data()
        result.reserveCapacity(bytes.count / 2)
        for index in stride(from: 0, to: bytes.count, by: 2) {
            guard let high = hexNibble(bytes[index]),
                  let low = hexNibble(bytes[index + 1]) else { return nil }
            result.append((high << 4) | low)
        }
        return result
    }

    static func hexNibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: return byte - 48
        case 97...102: return byte - 97 + 10
        default: return nil
        }
    }

    static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }
}

/// Stable machine-readable failures shared with the Python verifier.
public enum DPKSignedConfigurationManifestError: Error, Equatable {
    case manifestMissingField(String)
    case manifestUnknownField(String)
    case unsupportedManifestVersion
    case unsupportedSignatureAlgorithm
    case invalidKeyID
    case invalidManifestFingerprint
    case invalidSignatureEncoding
    case configurationFingerprintMismatch
    case untrustedKey
    case invalidTrustedKey
    case keyRevoked
    case keyPolicyTimeRequired
    case keyNotYetValid
    case keyExpired
    case signatureInvalid

    public var code: String {
        switch self {
        case .manifestMissingField: return "MANIFEST_MISSING_FIELD"
        case .manifestUnknownField: return "MANIFEST_UNKNOWN_FIELD"
        case .unsupportedManifestVersion: return "UNSUPPORTED_MANIFEST_VERSION"
        case .unsupportedSignatureAlgorithm: return "UNSUPPORTED_SIGNATURE_ALGORITHM"
        case .invalidKeyID: return "INVALID_KEY_ID"
        case .invalidManifestFingerprint: return "INVALID_MANIFEST_FINGERPRINT"
        case .invalidSignatureEncoding: return "INVALID_SIGNATURE_ENCODING"
        case .configurationFingerprintMismatch: return "CONFIGURATION_FINGERPRINT_MISMATCH"
        case .untrustedKey: return "UNTRUSTED_KEY"
        case .invalidTrustedKey: return "INVALID_TRUSTED_KEY"
        case .keyRevoked: return "KEY_REVOKED"
        case .keyPolicyTimeRequired: return "KEY_POLICY_TIME_REQUIRED"
        case .keyNotYetValid: return "KEY_NOT_YET_VALID"
        case .keyExpired: return "KEY_EXPIRED"
        case .signatureInvalid: return "SIGNATURE_INVALID"
        }
    }
}
