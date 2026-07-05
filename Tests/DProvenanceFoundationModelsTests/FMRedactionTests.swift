import XCTest
@testable import DProvenanceFoundationModels

final class FMRedactionTests: XCTestCase {
    /// FIPS 180-4 known vector: SHA-256("abc").
    private let abcSHA256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    private let emptySHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    func testKnownVector() {
        XCTAssertEqual(FMRedactedText("abc", redaction: .full).sha256, abcSHA256)
        XCTAssertEqual(FMRedactedText("abc", redaction: .hashed).sha256, abcSHA256)
    }

    func testFullCarriesTextHashAndCount() {
        let redacted = FMRedactedText("abc", redaction: .full)
        XCTAssertEqual(redacted.redaction, .full)
        XCTAssertEqual(redacted.text, "abc")
        XCTAssertEqual(redacted.sha256, abcSHA256)
        XCTAssertEqual(redacted.utf8Count, 3)
    }

    func testHashedCarriesHashAndCountOnly() {
        let redacted = FMRedactedText("abc", redaction: .hashed)
        XCTAssertEqual(redacted.redaction, .hashed)
        XCTAssertNil(redacted.text)
        XCTAssertEqual(redacted.sha256, abcSHA256)
        XCTAssertEqual(redacted.utf8Count, 3)
    }

    func testOmittedCarriesNothing() {
        let redacted = FMRedactedText.omitted
        XCTAssertEqual(redacted.redaction, .omitted)
        XCTAssertNil(redacted.text)
        XCTAssertNil(redacted.sha256)
        XCTAssertNil(redacted.utf8Count)
        XCTAssertEqual(FMRedactedText("anything", redaction: .omitted), .omitted)
    }

    func testCrossPolicyEquality() {
        XCTAssertEqual(FMRedactedText("x", redaction: .full), FMRedactedText("x", redaction: .hashed))
        XCTAssertNotEqual(FMRedactedText("x", redaction: .full), FMRedactedText("y", redaction: .hashed))
        XCTAssertNotEqual(FMRedactedText("x", redaction: .full), .omitted)
        XCTAssertNotEqual(FMRedactedText("x", redaction: .hashed), .omitted)
        XCTAssertEqual(FMRedactedText.omitted, FMRedactedText("other", redaction: .omitted))
    }

    func testHashableConsistencyWithEquality() {
        let full = FMRedactedText("payload", redaction: .full)
        let hashed = FMRedactedText("payload", redaction: .hashed)
        XCTAssertEqual(full.hashValue, hashed.hashValue)

        var set = Set<FMRedactedText>()
        set.insert(full)
        set.insert(hashed)
        XCTAssertEqual(set.count, 1, "Cross-policy equal values must collapse in a Set")
        XCTAssertTrue(set.contains(hashed))
    }

    func testEmptyString() {
        let redacted = FMRedactedText("", redaction: .full)
        XCTAssertEqual(redacted.text, "")
        XCTAssertEqual(redacted.sha256, emptySHA256)
        XCTAssertEqual(redacted.utf8Count, 0)
        XCTAssertNotEqual(redacted, .omitted, "Empty content is not the same as omitted content")
    }

    func testMultiByteUTF8Count() {
        // h(1) + é(2) + l(1) + l(1) + o(1) + 🚀(4) = 10 UTF-8 bytes.
        let redacted = FMRedactedText("héllo🚀", redaction: .hashed)
        XCTAssertEqual(redacted.utf8Count, 10)
    }

    func testPolicyPresets() {
        XCTAssertEqual(FMRedactionPolicy.full, FMRedactionPolicy())
        XCTAssertEqual(FMRedactionPolicy.hashed.promptContent, .hashed)
        XCTAssertEqual(FMRedactionPolicy.hashed.errorMessages, .hashed)
        XCTAssertEqual(FMRedactionPolicy.omitted.toolArguments, .omitted)
        XCTAssertEqual(FMRedactionPolicy.full.responseContent, .full)
    }
}
