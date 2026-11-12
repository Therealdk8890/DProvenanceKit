import Foundation
import XCTest
@testable import DProvenanceKit

final class ConfigurationAuthorizationTests: XCTestCase {
    private func vectors() throws -> [String: Any] {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let repositoryRoot = testDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repositoryRoot
            .appendingPathComponent("ConformanceHarness/vectors/configuration_authorization_v1.json")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func validConfiguration() throws -> [String: Any] {
        let root = try vectors()
        let valid = try XCTUnwrap(root["valid"] as? [[String: Any]])
        return try XCTUnwrap(valid.first?["input"] as? [String: Any])
    }

    func testSharedGoldenVectorsMatchCanonicalBytesAndFingerprint() throws {
        let root = try vectors()
        let valid = try XCTUnwrap(root["valid"] as? [[String: Any]])
        for vector in valid {
            let input = try XCTUnwrap(vector["input"] as? [String: Any])
            let configuration = try DPKConfigurationAuthorizationV1(jsonObject: input)
            let expectedBytes = try XCTUnwrap(vector["canonical_utf8"] as? String)
            let expectedDigest = try XCTUnwrap(vector["sha256"] as? String)
            XCTAssertEqual(String(data: configuration.canonicalJSON, encoding: .utf8), expectedBytes)
            XCTAssertEqual(configuration.fingerprint, expectedDigest)
            XCTAssertEqual(try configuration.verifyPinnedFingerprint(expectedDigest), expectedDigest)
        }
    }

    func testEverySharedInvalidVectorIsRejectedWithItsStableReasonCode() throws {
        let root = try vectors()
        let invalid = try XCTUnwrap(root["invalid"] as? [[String: Any]])
        let base = try validConfiguration()

        for vector in invalid {
            var candidate = base
            if let mutation = vector["mutation"] as? [String: Any] {
                candidate.merge(mutation) { _, new in new }
            }
            if let remove = vector["remove"] as? String {
                candidate.removeValue(forKey: remove)
            }
            if let additions = vector["add"] as? [String: Any] {
                candidate.merge(additions) { _, new in new }
            }
            let expectedCode = try XCTUnwrap(vector["error"] as? String)
            XCTAssertThrowsError(try DPKConfigurationAuthorizationV1(jsonObject: candidate), vector["id"] as? String ?? "") { error in
                XCTAssertEqual((error as? DPKConfigurationAuthorizationError)?.code, expectedCode)
            }
        }
    }

    func testChangedThresholdChangesFingerprint() throws {
        let root = try vectors()
        let base = try validConfiguration()
        let changedCases = try XCTUnwrap(root["changed_configuration"] as? [[String: Any]])
        let mutation = try XCTUnwrap(changedCases.first?["mutation"] as? [String: Any])
        var changed = base
        changed.merge(mutation) { _, new in new }

        let originalFingerprint = try DPKConfigurationAuthorizationV1(jsonObject: base).fingerprint
        let changedFingerprint = try DPKConfigurationAuthorizationV1(jsonObject: changed).fingerprint
        XCTAssertNotEqual(originalFingerprint, changedFingerprint)
    }

    func testUnknownFieldsAndBooleanNumbersAreRejected() throws {
        var unknown = try validConfiguration()
        unknown["unreviewed_override"] = true
        XCTAssertThrowsError(try DPKConfigurationAuthorizationV1(jsonObject: unknown)) { error in
            XCTAssertEqual((error as? DPKConfigurationAuthorizationError)?.code, "UNKNOWN_FIELD")
        }

        var boolean = try validConfiguration()
        boolean["weight_type_bps"] = true
        XCTAssertThrowsError(try DPKConfigurationAuthorizationV1(jsonObject: boolean)) { error in
            XCTAssertEqual((error as? DPKConfigurationAuthorizationError)?.code, "NON_INTEGER_NUMERIC_VALUE")
        }
    }

    func testPinnedFingerprintMismatchFailsClosed() throws {
        let configuration = try DPKConfigurationAuthorizationV1(jsonObject: validConfiguration())
        XCTAssertThrowsError(try configuration.verifyPinnedFingerprint(String(repeating: "0", count: 64))) { error in
            XCTAssertEqual((error as? DPKConfigurationAuthorizationError)?.code, "FINGERPRINT_MISMATCH")
        }
        XCTAssertThrowsError(try configuration.verifyPinnedFingerprint(String(repeating: "A", count: 64))) { error in
            XCTAssertEqual((error as? DPKConfigurationAuthorizationError)?.code, "INVALID_EXPECTED_FINGERPRINT")
        }
    }
    private func signatureVector() throws -> [String: Any] {
        let root = try vectors()
        return try XCTUnwrap(root["signature"] as? [String: Any])
    }

    private func dataFromHex(_ value: String) throws -> Data {
        var data = Data()
        let bytes = Array(value.utf8)
        guard bytes.count.isMultiple(of: 2) else {
            throw DPKSignedConfigurationManifestError.invalidTrustedKey
        }
        for index in stride(from: 0, to: bytes.count, by: 2) {
            guard let high = UInt8(String(decoding: [bytes[index]], as: UTF8.self), radix: 16),
                  let low = UInt8(String(decoding: [bytes[index + 1]], as: UTF8.self), radix: 16) else {
                throw DPKSignedConfigurationManifestError.invalidTrustedKey
            }
            data.append((high << 4) | low)
        }
        return data
    }

    func testSharedEd25519ManifestVectorVerifies() throws {
        let vector = try signatureVector()
        let manifest = try XCTUnwrap(vector["manifest"] as? [String: Any])
        let trusted = try XCTUnwrap(vector["trusted_key"] as? [String: Any])
        let keyID = try XCTUnwrap(trusted["key_id"] as? String)
        let publicKeyHex = try XCTUnwrap(trusted["public_key_hex"] as? String)
        let key = DPKTrustedConfigurationKeyV1(publicKey: try dataFromHex(publicKeyHex))
        let configuration = try DPKConfigurationAuthorizationV1(jsonObject: validConfiguration())

        XCTAssertEqual(
            try configuration.verifySignedManifest(manifest, trustedKeys: [keyID: key]),
            manifest["configuration_fingerprint"] as? String
        )
    }

    func testSharedSignedManifestNegativeCasesFailClosed() throws {
        let vector = try signatureVector()
        let baseManifest = try XCTUnwrap(vector["manifest"] as? [String: Any])
        let trusted = try XCTUnwrap(vector["trusted_key"] as? [String: Any])
        let trustedKeyID = try XCTUnwrap(trusted["key_id"] as? String)
        let publicKeyHex = try XCTUnwrap(trusted["public_key_hex"] as? String)
        let publicKey = try dataFromHex(publicKeyHex)
        let invalidCases = try XCTUnwrap(vector["invalid_cases"] as? [[String: Any]])
        let configuration = try DPKConfigurationAuthorizationV1(jsonObject: validConfiguration())

        for testCase in invalidCases {
            var manifest = baseManifest
            if let changes = testCase["manifest_mutation"] as? [String: Any] {
                manifest.merge(changes) { _, new in new }
            }

            let changes = testCase["trusted_key_mutation"] as? [String: Any] ?? [:]
            let revoked = changes["revoked"] as? Bool ?? false
            let notBefore = changes["not_before"] as? Int64
            let expiresAt = changes["expires_at"] as? Int64
            let key = DPKTrustedConfigurationKeyV1(
                publicKey: publicKey,
                revoked: revoked,
                notBeforeUnixSeconds: notBefore,
                expiresAtUnixSeconds: expiresAt
            )
            let verificationTime = testCase["verification_time"] as? Int64
            let expectedCode = try XCTUnwrap(testCase["error"] as? String)

            XCTAssertThrowsError(
                try configuration.verifySignedManifest(
                    manifest,
                    trustedKeys: [trustedKeyID: key],
                    verificationTimeUnixSeconds: verificationTime
                ),
                testCase["id"] as? String ?? ""
            ) { error in
                XCTAssertEqual(
                    (error as? DPKSignedConfigurationManifestError)?.code,
                    expectedCode
                )
            }
        }
    }

    func testChangedConfigurationCannotReuseSignedManifest() throws {
        let vector = try signatureVector()
        let manifest = try XCTUnwrap(vector["manifest"] as? [String: Any])
        let trusted = try XCTUnwrap(vector["trusted_key"] as? [String: Any])
        let keyID = try XCTUnwrap(trusted["key_id"] as? String)
        let publicKeyHex = try XCTUnwrap(trusted["public_key_hex"] as? String)
        var changed = try validConfiguration()
        changed["min_global_f1_bps"] = 9400
        let configuration = try DPKConfigurationAuthorizationV1(jsonObject: changed)
        let key = DPKTrustedConfigurationKeyV1(publicKey: try dataFromHex(publicKeyHex))

        XCTAssertThrowsError(
            try configuration.verifySignedManifest(manifest, trustedKeys: [keyID: key])
        ) { error in
            XCTAssertEqual(
                (error as? DPKSignedConfigurationManifestError)?.code,
                "CONFIGURATION_FINGERPRINT_MISMATCH"
            )
        }
    }

}
