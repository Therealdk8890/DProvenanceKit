import XCTest
@testable import DProvenanceFoundationModels

final class FMRedactorTests: XCTestCase {

    func testMaskAppliesRulesInOrder() {
        let redactor = FMRedactor(rules: [.init(pattern: #"\d{3}-\d{2}-\d{4}"#, replacement: "[SSN]")])
        XCTAssertEqual(redactor.mask("ssn is 123-45-6789 ok"), "ssn is [SSN] ok")
    }

    func testCommonPIIMasksEmailAndSSN() {
        let masked = FMRedactor.commonPII.mask("email a@b.com and ssn 123-45-6789")
        XCTAssertFalse(masked.contains("a@b.com"))
        XCTAssertFalse(masked.contains("123-45-6789"))
        XCTAssertTrue(masked.contains("[EMAIL]"))
        XCTAssertTrue(masked.contains("[SSN]"))
    }

    /// A bad pattern must be skipped, never crash capture — and later good rules still run.
    func testInvalidPatternIsSkipped() {
        let redactor = FMRedactor(rules: [
            .init(pattern: "[unterminated", replacement: "X"),
            .init(pattern: "foo", replacement: "bar"),
        ])
        XCTAssertEqual(redactor.mask("foo baz"), "bar baz")
    }

    func testDeterministic() {
        // Live and post-hoc capture rely on this: same input → same masked output.
        XCTAssertEqual(FMRedactor.commonPII.mask("a@b.com x"), FMRedactor.commonPII.mask("a@b.com x"))
    }

    func testRedactedTextStoresMaskedTextAndKeysIdentityOnIt() {
        let redactor = FMRedactor(rules: [.init(pattern: #"\d{3}-\d{2}-\d{4}"#, replacement: "[SSN]")])
        let field = FMRedactedText("card 123-45-6789", redaction: .full, redactor: redactor)

        XCTAssertEqual(field.text, "card [SSN]", "the stored/exported text is masked")
        // Identity is derived from the masked text.
        XCTAssertEqual(field, FMRedactedText("card [SSN]", redaction: .full))
    }

    /// The invariant: within a redactor, `.full` and `.hashed` of the same content still
    /// diff equal (both key on the masked text); but a masked field is (correctly) a
    /// distinct identity from an unmasked capture of the same original.
    func testMaskedIdentityModel() {
        let raw = "ssn 123-45-6789"
        let maskedHashed = FMRedactedText(raw, redaction: .hashed, redactor: .commonPII)
        let maskedFull = FMRedactedText(raw, redaction: .full, redactor: .commonPII)
        let unmasked = FMRedactedText(raw, redaction: .full)

        XCTAssertEqual(maskedHashed, maskedFull, "full/hashed of the same masked content stay equal")
        XCTAssertNotEqual(maskedHashed, unmasked, "masked is a distinct identity — different content was recorded")
    }

    func testNilRedactorIsExactPriorBehavior() {
        let withDefault = FMRedactedText("hello", redaction: .full)
        let withNil = FMRedactedText("hello", redaction: .full, redactor: nil)
        XCTAssertEqual(withDefault, withNil)
        XCTAssertEqual(withDefault.text, "hello")
    }

    func testPolicyCarriesRedactor() {
        let policy = FMRedactionPolicy(promptContent: .full, redactor: .commonPII)
        XCTAssertNotNil(policy.redactor)
        XCTAssertEqual(policy, FMRedactionPolicy(promptContent: .full, redactor: .commonPII))
    }
}
