import Foundation
import XCTest
@testable import DProvenanceKit

final class ReasoningRepositoryConformanceTests: XCTestCase {
    private func corpus() throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("ConformanceHarness/vectors/repository_v1.json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func bytes(_ hex: String) throws -> Data {
        let characters = Array(hex.utf8)
        guard characters.count % 2 == 0 else { throw ReasoningRepositoryError.malformed("fixture hex") }
        var result = Data()
        for index in stride(from: 0, to: characters.count, by: 2) {
            let text = String(bytes: characters[index..<(index + 2)], encoding: .utf8)!
            result.append(try XCTUnwrap(UInt8(text, radix: 16)))
        }
        return result
    }

    func testSharedPythonObjectsDecodeAndReencodeByteExactly() throws {
        let fixture = try corpus()
        XCTAssertEqual(fixture["spec_version"] as? String, "DPK-REPOSITORY-V1")
        let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(cases.count, 7)
        for item in cases {
            let raw = try bytes(XCTUnwrap(item["canonical_hex"] as? String))
            let object = try ReasoningRepositoryObject.decodeCanonical(raw)
            XCTAssertEqual(object.id, item["object_id"] as? String, item["id"] as? String ?? "fixture")
            XCTAssertEqual(object.type.rawValue, item["type"] as? String)
            XCTAssertEqual(try object.checkedCanonicalData(), raw)
        }
    }

    func testAdmissionRejectsUnexpectedSchemaAndUnreachableObjects() throws {
        let blob = ReasoningRepositoryObject(type: .blob,
            payload: .map(ReasoningRepositoryMap(["data": .bytes(Data())])))
        let extra = ReasoningRepositoryObject(type: .blob,
            payload: .map(ReasoningRepositoryMap(["data": .bytes(Data([1]))])))
        try ReasoningRepositorySchema.validate(objects: [blob.id: blob], roots: [blob.id],
                                               refs: ReasoningRepositoryMap([:]))
        XCTAssertThrowsError(try ReasoningRepositorySchema.validate(
            objects: [blob.id: blob, extra.id: extra], roots: [blob.id], refs: ReasoningRepositoryMap([:])))
        let bad = ReasoningRepositoryObject(type: .blob,
            payload: .map(ReasoningRepositoryMap(["data": .string("bytes required")])))
        XCTAssertThrowsError(try ReasoningRepositorySchema.validate(objects: [bad.id: bad],
            roots: [bad.id], refs: ReasoningRepositoryMap([:])))
    }

    func testSharedPythonBundlesVerifyOfflineAndRejectTampering() throws {
        let fixtures = try XCTUnwrap(corpus()["bundles"] as? [[String: Any]])
        XCTAssertEqual(fixtures.count, 2)
        for fixture in fixtures {
            let raw = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(fixture["base64"] as? String)))
            XCTAssertEqual(ReasoningRepositoryObject.digest(raw), fixture["sha256"] as? String)
            let bundle = try ReasoningRepositoryBundle.verify(raw)
            let ids = try XCTUnwrap(fixture["object_ids"] as? [String])
            XCTAssertEqual(bundle.objects.keys.sorted(), ids)
            let commit = try XCTUnwrap(fixture["commit"] as? String)
            XCTAssertTrue(bundle.roots.contains(commit))
            XCTAssertEqual(bundle.refs["refs/heads/main"], .string(commit))
            if fixture["id"] as? String == "signed" {
                let signatures = bundle.signatureVerifications()
                XCTAssertEqual(signatures.count, 1)
                XCTAssertEqual(signatures.first?.subject, commit)
                XCTAssertEqual(signatures.first?.trustedKey, false)
                let keyID = try XCTUnwrap(signatures.first?.keyID)
                XCTAssertEqual(bundle.signatureVerifications(trustedKeyIDs: [keyID]).first?.trustedKey, true)
                let signatureID = try XCTUnwrap(signatures.first?.signatureID)
                let signatureObject = try XCTUnwrap(bundle.objects[signatureID])
                guard case .map(let fields) = signatureObject.payload,
                      let signatureValue = fields["signature"], case .bytes(let signatureBytes) = signatureValue else {
                    return XCTFail("signature bytes expected")
                }
                var badBytes = Array(signatureBytes)
                badBytes[badBytes.count - 1] ^= 1
                let invalidSignature = ReasoningRepositoryObject(type: .signature, payload: .map(
                    try ReasoningRepositoryMap(fields: fields.fields.map {
                        $0.key == "signature" ? .init($0.key, .bytes(Data(badBytes))) : $0
                    })))
                var invalidObjects = bundle.objects
                invalidObjects.removeValue(forKey: signatureID)
                invalidObjects[invalidSignature.id] = invalidSignature
                XCTAssertThrowsError(try ReasoningRepositorySchema.validate(objects: invalidObjects,
                    roots: bundle.roots, refs: bundle.refs))
            } else {
                XCTAssertTrue(bundle.signatureVerifications().isEmpty)
            }
            var corrupt = Array(raw)
            let objectDomain = Array("DPK-OBJECT-V1".utf8)
            let start = try XCTUnwrap((0..<(corrupt.count - objectDomain.count)).first { index in
                Array(corrupt[index..<(index + objectDomain.count)]) == objectDomain
            })
            corrupt[start] ^= 1
            XCTAssertThrowsError(try ReasoningRepositoryBundle.verify(Data(corrupt)))
            var unsafe = raw
            let originalName = Data("manifest.json".utf8)
            let unsafeName = Data("../escape.txt".utf8)
            while let range = unsafe.range(of: originalName) { unsafe.replaceSubrange(range, with: unsafeName) }
            XCTAssertThrowsError(try ReasoningRepositoryBundle.verify(unsafe))
            if ids.count >= 2 {
                var duplicate = raw
                let originalPath = Data("objects/\(ids[0]).bin".utf8)
                let duplicatePath = Data("objects/\(ids[1]).bin".utf8)
                while let range = duplicate.range(of: originalPath) {
                    duplicate.replaceSubrange(range, with: duplicatePath)
                }
                XCTAssertThrowsError(try ReasoningRepositoryBundle.verify(duplicate))
            }
            XCTAssertThrowsError(try ReasoningRepositoryBundle.verify(raw, limits: .init(maxObjects: 1)))
            XCTAssertThrowsError(try ReasoningRepositoryBundle.verify(Data(raw.dropLast())))
        }
    }
}
