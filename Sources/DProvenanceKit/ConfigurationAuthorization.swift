import Foundation
import CryptoKit
import CoreFoundation

/// Fail-closed validation and pinned-fingerprint authorization for dpk-config-v1.
///
/// This is separate from AlignmentExecutionContract.computeProfileHash: the latter
/// identifies an execution profile, while this type fingerprints a closed policy
/// document that must be authorized against an independently supplied expectation.
public struct DPKConfigurationAuthorizationV1: Sendable, Equatable {
    public static let schemaVersion = "dpk-config-v1"

    public let algorithm: String
    public let minGlobalF1Bps: Int
    public let minNodeConformanceBps: Int
    public let weightHierarchyBps: Int
    public let weightPayloadBps: Int
    public let weightTypeBps: Int

    private static let requiredFields: Set<String> = [
        "algorithm",
        "min_global_f1_bps",
        "min_node_conformance_bps",
        "schema_version",
        "weight_hierarchy_bps",
        "weight_payload_bps",
        "weight_type_bps"
    ]

    /// Construct from a JSONSerialization object, rejecting missing, unknown,
    /// non-integer, out-of-range, and otherwise invalid fields before hashing.
    public init(jsonObject: [String: Any]) throws {
        let keys = Set(jsonObject.keys)
        if let missing = Self.requiredFields.subtracting(keys).sorted().first {
            throw DPKConfigurationAuthorizationError.missingField(missing)
        }
        if let unknown = keys.subtracting(Self.requiredFields).sorted().first {
            throw DPKConfigurationAuthorizationError.unknownField(unknown)
        }

        guard let algorithm = jsonObject["algorithm"] as? String,
              Self.isValidIdentifier(algorithm) else {
            throw DPKConfigurationAuthorizationError.invalidIdentifier
        }
        guard let schemaVersion = jsonObject["schema_version"] as? String,
              schemaVersion == Self.schemaVersion else {
            throw DPKConfigurationAuthorizationError.unsupportedSchemaVersion
        }

        let minGlobal = try Self.integer(jsonObject["min_global_f1_bps"], field: "min_global_f1_bps")
        let minNode = try Self.integer(jsonObject["min_node_conformance_bps"], field: "min_node_conformance_bps")
        let hierarchy = try Self.integer(jsonObject["weight_hierarchy_bps"], field: "weight_hierarchy_bps")
        let payload = try Self.integer(jsonObject["weight_payload_bps"], field: "weight_payload_bps")
        let type = try Self.integer(jsonObject["weight_type_bps"], field: "weight_type_bps")

        for (field, value) in [
            ("min_global_f1_bps", minGlobal),
            ("min_node_conformance_bps", minNode)
        ] where !(0...10_000).contains(value) {
            throw DPKConfigurationAuthorizationError.thresholdOutOfRange(field)
        }
        for (field, value) in [
            ("weight_hierarchy_bps", hierarchy),
            ("weight_payload_bps", payload),
            ("weight_type_bps", type)
        ] where !(0...10_000).contains(value) {
            throw DPKConfigurationAuthorizationError.weightOutOfRange(field)
        }
        guard hierarchy + payload + type == 10_000 else {
            throw DPKConfigurationAuthorizationError.weightsSumInvalid
        }

        self.algorithm = algorithm
        self.minGlobalF1Bps = minGlobal
        self.minNodeConformanceBps = minNode
        self.weightHierarchyBps = hierarchy
        self.weightPayloadBps = payload
        self.weightTypeBps = type
    }

    /// Exact compact UTF-8 JSON bytes in the contract's ascending key order.
    public var canonicalJSON: Data {
        let json = "{\"algorithm\":\"\(algorithm)\","
            + "\"min_global_f1_bps\":\(minGlobalF1Bps),"
            + "\"min_node_conformance_bps\":\(minNodeConformanceBps),"
            + "\"schema_version\":\"\(Self.schemaVersion)\","
            + "\"weight_hierarchy_bps\":\(weightHierarchyBps),"
            + "\"weight_payload_bps\":\(weightPayloadBps),"
            + "\"weight_type_bps\":\(weightTypeBps)}"
        return Data(json.utf8)
    }

    /// Lowercase SHA-256 of the validated canonical configuration bytes.
    public var fingerprint: String {
        SHA256.hash(data: canonicalJSON)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Compare against a separately reviewed policy value; never self-authorize.
    @discardableResult
    public func verifyPinnedFingerprint(_ expected: String) throws -> String {
        guard expected.count == 64,
              expected.unicodeScalars.allSatisfy({
                  (48...57).contains($0.value) || (97...102).contains($0.value)
              }) else {
            throw DPKConfigurationAuthorizationError.invalidExpectedFingerprint
        }
        let actualBytes = Array(fingerprint.utf8)
        let expectedBytes = Array(expected.utf8)
        var difference: UInt8 = 0
        for index in 0..<64 {
            difference |= actualBytes[index] ^ expectedBytes[index]
        }
        guard difference == 0 else {
            throw DPKConfigurationAuthorizationError.fingerprintMismatch
        }
        return fingerprint
    }

    private static func integer(_ value: Any?, field: String) throws -> Int {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw DPKConfigurationAuthorizationError.nonIntegerNumericValue(field)
        }
        let type = String(cString: number.objCType)
        guard type != "f", type != "d",
              let integer = Int(number.stringValue) else {
            throw DPKConfigurationAuthorizationError.nonIntegerNumericValue(field)
        }
        return integer
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
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
}

public enum DPKConfigurationAuthorizationError: Error, Equatable {
    case missingField(String)
    case unknownField(String)
    case invalidIdentifier
    case unsupportedSchemaVersion
    case nonIntegerNumericValue(String)
    case thresholdOutOfRange(String)
    case weightOutOfRange(String)
    case weightsSumInvalid
    case invalidExpectedFingerprint
    case fingerprintMismatch

    public var code: String {
        switch self {
        case .missingField: return "MISSING_FIELD"
        case .unknownField: return "UNKNOWN_FIELD"
        case .invalidIdentifier: return "INVALID_IDENTIFIER"
        case .unsupportedSchemaVersion: return "UNSUPPORTED_SCHEMA_VERSION"
        case .nonIntegerNumericValue: return "NON_INTEGER_NUMERIC_VALUE"
        case .thresholdOutOfRange: return "THRESHOLD_OUT_OF_RANGE"
        case .weightOutOfRange: return "WEIGHT_OUT_OF_RANGE"
        case .weightsSumInvalid: return "WEIGHTS_SUM_INVALID"
        case .invalidExpectedFingerprint: return "INVALID_EXPECTED_FINGERPRINT"
        case .fingerprintMismatch: return "FINGERPRINT_MISMATCH"
        }
    }
}
