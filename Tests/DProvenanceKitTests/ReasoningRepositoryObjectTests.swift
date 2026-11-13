import Foundation
import XCTest
@testable import DProvenanceKit

final class ReasoningRepositoryObjectTests: XCTestCase {
    func testPythonCanonicalIDsAndTypedValues() throws {
        let blob = ReasoningRepositoryObject(type: .blob,
            payload: .map(ReasoningRepositoryMap(["data": .bytes(Data("hello".utf8))])))
        XCTAssertEqual(blob.id, "720acbfc69b6006a5c14405678d6bfbf5e68c3a56db18250af870d39fc409bb6")
        let value = ReasoningRepositoryObject(type: .workflow, payload: .map(ReasoningRepositoryMap([
            "null": .null, "false": .bool(false), "true": .bool(true),
            "min": .integer(.min), "max": .integer(.max), "text": .string("é"),
            "array": .array([.integer(1), .string("x"), .bytes(Data([0, 255]))])
        ])))
        XCTAssertEqual(value.id, "7d68bdddddd4e07dcbad5f1c702aa0759338646970e52faa79df68a1c7631044")
        for object in [blob, value] {
            let restored = try ReasoningRepositoryObject.decodeCanonical(object.canonicalData())
            XCTAssertEqual(restored, object)
            XCTAssertEqual(restored.canonicalData(), object.canonicalData())
        }
    }

    func testUTF8KeyIdentityDoesNotNormalizeUnicode() throws {
        let object = ReasoningRepositoryObject(type: .blob, payload: .map(
            try ReasoningRepositoryMap(fields: [
                .init("é", .integer(1)), .init("e\u{301}", .integer(2))
            ])))
        XCTAssertEqual(object.id, "97524f1a6f317c2437c8eec7db27094622b88f0158493794be897ae1bf80fc6f")
        let restored = try ReasoningRepositoryObject.decodeCanonical(object.canonicalData())
        guard case .map(let fields) = restored.payload else { return XCTFail("map expected") }
        XCTAssertEqual(fields.fields.count, 2)
        XCTAssertEqual(fields["é"], .integer(1))
        XCTAssertEqual(fields["e\u{301}"], .integer(2))
        XCTAssertEqual(restored.canonicalData(), object.canonicalData())
    }

    func testRejectsEveryTruncatedPrefixAndTrailingBytes() throws {
        let object = ReasoningRepositoryObject(type: .blob, payload: .bytes(Data([0, 1, 2])))
        let data = object.canonicalData()
        for end in 0..<data.count {
            XCTAssertThrowsError(try ReasoningRepositoryObject.decodeCanonical(Data(data.prefix(end))))
        }
        XCTAssertThrowsError(try ReasoningRepositoryObject.decodeCanonical(data + Data([0])))
    }

    func testRejectsDuplicateAndOutOfOrderKeys() throws {
        let object = ReasoningRepositoryObject(type: .blob,
            payload: .map(ReasoningRepositoryMap(["a": .null, "b": .null])))
        var bytes = Array(object.canonicalData())
        XCTAssertEqual(bytes[58], 97)
        XCTAssertEqual(bytes[68], 98)
        bytes[68] = 97
        XCTAssertThrowsError(try ReasoningRepositoryObject.decodeCanonical(Data(bytes)))
        bytes[58] = 98
        XCTAssertThrowsError(try ReasoningRepositoryObject.decodeCanonical(Data(bytes)))
        XCTAssertThrowsError(try ReasoningRepositoryMap(fields: [.init("a", .null), .init("a", .null)]))
    }

    func testRejectsUnsupportedTagVersionAndResourceLimits() {
        let object = ReasoningRepositoryObject(type: .blob, payload: .array([.null]))
        var bytes = Array(object.canonicalData())
        bytes[41] = 255
        XCTAssertThrowsError(try ReasoningRepositoryObject.decodeCanonical(Data(bytes)))
        bytes = Array(object.canonicalData())
        bytes[40] = 2
        XCTAssertThrowsError(try ReasoningRepositoryObject.decodeCanonical(Data(bytes)))
        XCTAssertThrowsError(try ReasoningRepositoryObject.decodeCanonical(object.canonicalData(),
            limits: .init(maxObjectBytes: 1)))
        XCTAssertThrowsError(try ReasoningRepositoryObject.decodeCanonical(object.canonicalData(),
            limits: .init(maxDepth: 0)))
        XCTAssertThrowsError(try ReasoningRepositoryObject.decodeCanonical(object.canonicalData(),
            limits: .init(maxContainerItems: 1)))
        XCTAssertThrowsError(try object.checkedCanonicalData(limits: .init(maxDepth: 0)))
        XCTAssertThrowsError(try object.checkedCanonicalData(limits: .init(maxObjectBytes: 1)))
        XCTAssertThrowsError(try object.checkedCanonicalData(limits: .init(maxContainerItems: 1)))
    }
}
