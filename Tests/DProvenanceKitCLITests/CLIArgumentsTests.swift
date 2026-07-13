import XCTest
@testable import DProvenanceKitCLI

/// The CLI's trust controls must fail CLOSED: any argument the parser does not fully
/// understand — empty, malformed, non-finite, duplicated, out of range, or simply
/// unknown — throws (and exits 2 in `main`), and can never silently downgrade a
/// verification or a CI gate that still reports success.
final class CLIArgumentsTests: XCTestCase {
    private let validKeyID = String(repeating: "ab", count: 32) // 64 hex chars

    // MARK: - --trusted-key

    func testEmptyTrustedKeyIsRejected() {
        XCTAssertThrowsError(try CLIArguments.parse(["verify", "--in=doc.json", "--trusted-key="])) { error in
            XCTAssertEqual(error as? CLIArgumentError, .emptyValue("--trusted-key"))
        }
    }

    func testBareTrustedKeyFlagIsRejected() {
        XCTAssertThrowsError(try CLIArguments.parse(["verify", "--in=doc.json", "--trusted-key"])) { error in
            XCTAssertEqual(error as? CLIArgumentError, .unknownFlag("--trusted-key"))
        }
    }

    func testMalformedTrustedKeyIsRejected() {
        for bad in ["abc123", "not-a-key", String(repeating: "g", count: 64), String(repeating: "a", count: 63)] {
            XCTAssertThrowsError(try CLIArguments.parse(["verify", "--in=doc.json", "--trusted-key=\(bad)"]),
                                 "expected '\(bad)' to be rejected") { error in
                guard case .invalidValue(let flag, _, _)? = error as? CLIArgumentError else {
                    return XCTFail("unexpected error \(error) for '\(bad)')")
                }
                XCTAssertEqual(flag, "--trusted-key")
            }
        }
    }

    func testFullwidthUnicodeHexIsRejected() {
        // Character.isHexDigit matches fullwidth compatibility forms (U+FF10…), which
        // can never equal a real ASCII key ID — they must fail at parse (exit 2), not
        // verify as "signer not trusted".
        for bad in [String(repeating: "ａ", count: 64), String(repeating: "０", count: 64)] {
            XCTAssertThrowsError(try CLIArguments.parse(["verify", "--in=doc.json", "--trusted-key=\(bad)"]),
                                 "expected fullwidth pseudo-hex to be rejected")
        }
    }

    func testDuplicateGateIsRejected() {
        XCTAssertThrowsError(try CLIArguments.parse(["evaluate", "--gate", "--gate"])) { error in
            XCTAssertEqual(error as? CLIArgumentError, .duplicateFlag("--gate"))
        }
    }

    func testValidTrustedKeyIsAcceptedAndNormalized() throws {
        let upper = validKeyID.uppercased()
        let invocation = try CLIArguments.parse(["verify", "--in=doc.json", "--trusted-key=\(upper)"])
        // Generated key IDs are lowercase hex; a case-mismatched pin must still match.
        XCTAssertEqual(invocation.trustedKeyIDs, [validKeyID])
    }

    func testTrustedKeyIsRepeatable() throws {
        let other = String(repeating: "cd", count: 32)
        let invocation = try CLIArguments.parse([
            "verify", "--in=doc.json", "--trusted-key=\(validKeyID)", "--trusted-key=\(other)",
        ])
        XCTAssertEqual(invocation.trustedKeyIDs, [validKeyID, other])
    }

    func testVerifyRequiresInputPath() {
        XCTAssertThrowsError(try CLIArguments.parse(["verify"])) { error in
            XCTAssertEqual(error as? CLIArgumentError, .missingRequiredFlag("--in=<attestation.json>"))
        }
    }

    // MARK: - --proof-pack

    func testProofPackFlagIsAcceptedOnVerify() throws {
        let invocation = try CLIArguments.parse(["verify", "--in=pack.json", "--proof-pack"])
        XCTAssertEqual(invocation.mode, .verify)
        XCTAssertTrue(invocation.proofPack)

        // And it stays off unless explicitly requested.
        XCTAssertFalse(try CLIArguments.parse(["verify", "--in=doc.json"]).proofPack)
    }

    func testProofPackFlagIsRejectedOutsideVerify() {
        for mode in ["evaluate", "diagnose", "stability", "web-export", "attest-demo"] {
            XCTAssertThrowsError(try CLIArguments.parse([mode, "--proof-pack"]),
                                 "expected --proof-pack to be rejected for '\(mode)'") { error in
                XCTAssertEqual(error as? CLIArgumentError, .unknownFlag("--proof-pack"))
            }
        }
    }

    func testProofPackStillRequiresInputPath() {
        XCTAssertThrowsError(try CLIArguments.parse(["verify", "--proof-pack"])) { error in
            XCTAssertEqual(error as? CLIArgumentError, .missingRequiredFlag("--in=<attestation.json>"))
        }
    }

    func testProofPackWithValueIsRejected() {
        // Boolean flags never take a value; `--proof-pack=value` goes down the value-flag
        // path and must be rejected as unknown, not treated as the boolean.
        XCTAssertThrowsError(try CLIArguments.parse(["verify", "--in=pack.json", "--proof-pack=yes"])) { error in
            XCTAssertEqual(error as? CLIArgumentError, .unknownFlag("--proof-pack"))
        }
    }

    func testDuplicateProofPackIsRejected() {
        XCTAssertThrowsError(try CLIArguments.parse(["verify", "--in=pack.json", "--proof-pack", "--proof-pack"])) { error in
            XCTAssertEqual(error as? CLIArgumentError, .duplicateFlag("--proof-pack"))
        }
    }

    // MARK: - --min-f1

    func testMalformedMinF1IsRejected() {
        for bad in ["bogus", "", "0.9.1", "1,0"] {
            XCTAssertThrowsError(try CLIArguments.parse(["evaluate", "--gate", "--min-f1=\(bad)"]),
                                 "expected '\(bad)' to be rejected")
        }
    }

    func testNonFiniteMinF1IsRejected() {
        for bad in ["nan", "NaN", "inf", "infinity", "-inf"] {
            XCTAssertThrowsError(try CLIArguments.parse(["evaluate", "--gate", "--min-f1=\(bad)"]),
                                 "expected '\(bad)' to be rejected") { error in
                guard case .invalidValue(let flag, _, _)? = error as? CLIArgumentError else {
                    return XCTFail("unexpected error \(error) for '\(bad)')")
                }
                XCTAssertEqual(flag, "--min-f1")
            }
        }
    }

    func testOutOfRangeMinF1IsRejected() {
        for bad in ["-0.1", "1.1", "100"] {
            XCTAssertThrowsError(try CLIArguments.parse(["evaluate", "--gate", "--min-f1=\(bad)"]),
                                 "expected '\(bad)' to be rejected")
        }
    }

    func testDuplicateMinF1IsRejected() {
        XCTAssertThrowsError(try CLIArguments.parse(["evaluate", "--gate", "--min-f1=0.9", "--min-f1=0.5"])) { error in
            XCTAssertEqual(error as? CLIArgumentError, .duplicateFlag("--min-f1"))
        }
    }

    func testMinF1WithoutGateIsRejected() {
        // Without --gate the threshold is never enforced; accepting it would let a CI
        // job believe it has an F1 floor that does nothing.
        XCTAssertThrowsError(try CLIArguments.parse(["evaluate", "--min-f1=0.9"])) { error in
            XCTAssertEqual(error as? CLIArgumentError, .minF1RequiresGate)
        }
    }

    func testValidGateAndMinF1() throws {
        let invocation = try CLIArguments.parse(["evaluate", "--gate", "--min-f1=0.95"])
        XCTAssertTrue(invocation.gate)
        XCTAssertEqual(invocation.minF1, 0.95)
    }

    func testBoundaryMinF1ValuesAreAccepted() throws {
        XCTAssertEqual(try CLIArguments.parse(["evaluate", "--gate", "--min-f1=0"]).minF1, 0)
        XCTAssertEqual(try CLIArguments.parse(["evaluate", "--gate", "--min-f1=1"]).minF1, 1)
    }

    // MARK: - unknown/misplaced arguments

    func testUnknownFlagIsRejected() {
        XCTAssertThrowsError(try CLIArguments.parse(["evaluate", "--gaet"])) { error in
            XCTAssertEqual(error as? CLIArgumentError, .unknownFlag("--gaet"))
        }
        XCTAssertThrowsError(try CLIArguments.parse(["verify", "--in=doc.json", "--trusted-keys=\(validKeyID)"])) { error in
            XCTAssertEqual(error as? CLIArgumentError, .unknownFlag("--trusted-keys"))
        }
    }

    func testFlagFromAnotherModeIsRejected() {
        // --gate silently doing nothing outside `evaluate` is the same trap as a typo.
        XCTAssertThrowsError(try CLIArguments.parse(["diagnose", "--gate"])) { error in
            XCTAssertEqual(error as? CLIArgumentError, .unknownFlag("--gate"))
        }
        XCTAssertThrowsError(try CLIArguments.parse(["evaluate", "--trusted-key=\(validKeyID)"])) { error in
            XCTAssertEqual(error as? CLIArgumentError, .unknownFlag("--trusted-key"))
        }
    }

    func testUnknownModeIsRejected() {
        XCTAssertThrowsError(try CLIArguments.parse(["evaluat"])) { error in
            XCTAssertEqual(error as? CLIArgumentError, .unknownMode("evaluat"))
        }
    }

    func testExtraPositionalIsRejected() {
        XCTAssertThrowsError(try CLIArguments.parse(["evaluate", "extra"])) { error in
            XCTAssertEqual(error as? CLIArgumentError, .unexpectedPositional("extra"))
        }
    }

    func testDuplicateInPathIsRejected() {
        XCTAssertThrowsError(try CLIArguments.parse(["verify", "--in=a.json", "--in=b.json"])) { error in
            XCTAssertEqual(error as? CLIArgumentError, .duplicateFlag("--in"))
        }
    }

    // MARK: - defaults

    func testDefaultsToEvaluate() throws {
        let invocation = try CLIArguments.parse([])
        XCTAssertEqual(invocation.mode, .evaluate)
        XCTAssertFalse(invocation.gate)
        XCTAssertNil(invocation.minF1)
        XCTAssertTrue(invocation.trustedKeyIDs.isEmpty)
    }

    func testWebExportFlags() throws {
        let invocation = try CLIArguments.parse(["web-export", "--case=my-case", "--out=/tmp/x.json"])
        XCTAssertEqual(invocation.mode, .webExport)
        XCTAssertEqual(invocation.caseName, "my-case")
        XCTAssertEqual(invocation.outPath, "/tmp/x.json")
    }
}
