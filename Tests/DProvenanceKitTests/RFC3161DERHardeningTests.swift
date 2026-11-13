import XCTest
@testable import DProvenanceKit

final class RFC3161DERHardeningTests: XCTestCase {
    func testDERParserAcceptsWellFormedSequence() throws {
        let encoded = Data([0x30, 0x03, 0x02, 0x01, 0x01])

        let root = try RFC3161DER.parse(encoded)

        XCTAssertEqual(root.tag, 0x30)
        XCTAssertEqual(root.children.count, 1)
        XCTAssertEqual(root.children[0].integer, 1)
    }

    func testDERParserRejectsNonCanonicalLongFormLength() {
        // DER must use short-form lengths for values smaller than 128.
        let encoded = Data([0x30, 0x81, 0x01, 0x00])

        XCTAssertThrowsError(try RFC3161DER.parse(encoded))
    }

    func testDERParserRejectsOverflowingLength() {
        let encoded = Data([0x30, 0x88] + Array(repeating: 0xFF, count: 8))

        XCTAssertThrowsError(try RFC3161DER.parse(encoded))
    }

    func testDERParserRejectsTruncatedLength() {
        let encoded = Data([0x30, 0x82, 0x01])

        XCTAssertThrowsError(try RFC3161DER.parse(encoded))
    }

    func testDERParserRejectsUnsupportedHighTagNumberForm() {
        let encoded = Data([0x1F, 0x01, 0x00])

        XCTAssertThrowsError(try RFC3161DER.parse(encoded))
    }

    func testTimestampResponseRejectsUnexpectedTrailingFields() {
        // TimeStampResp contains statusInfo and at most one timeStampToken.
        let statusInfo = Data([0x30, 0x03, 0x02, 0x01, 0x00])
        let unexpectedField = Data([0x05, 0x00])
        let body = statusInfo + unexpectedField
        let encoded = derSequence(body)

        XCTAssertThrowsError(try RFC3161DER.parseResponse(encoded))
    }

    func testDERParserRejectsInputAboveConfiguredLimit() {
        let encoded = Data(repeating: 0x00, count: RFC3161DER.maximumTokenSize + 1)

        XCTAssertThrowsError(try RFC3161DER.parse(encoded))
    }

    func testTimestampRejectsOversizedBase64BeforeDecoding() {
        let timestamp = RFC3161Timestamp(
            tsaURL: "https://tsa.example.test/timestamp",
            messageImprintSHA256: String(repeating: "0", count: 64),
            nonce: 1,
            genTimeUnixMicroseconds: 0,
            tokenBase64: String(repeating: "A", count: RFC3161DER.maximumBase64Size + 1)
        )

        XCTAssertNil(timestamp.tokenData)
    }

    func testDERParserRejectsExcessiveNesting() {
        var encoded = Data([0x05, 0x00])
        for _ in 0..<(RFC3161DER.maximumNestingDepth + 2) {
            encoded = derSequence(encoded)
        }

        XCTAssertThrowsError(try RFC3161DER.parse(encoded))
    }

    func testDERIntegerRejectsNegativeAndNonMinimalEncodings() {
        let negative = RFC3161DER.Node(tag: 0x02, value: Data([0x80]), children: [])
        let nonMinimal = RFC3161DER.Node(tag: 0x02, value: Data([0x00, 0x01]), children: [])
        let valid = RFC3161DER.Node(tag: 0x02, value: Data([0x00, 0x80]), children: [])

        XCTAssertNil(negative.integer)
        XCTAssertNil(nonMinimal.integer)
        XCTAssertEqual(valid.integer, 128)
    }

    func testOIDDecoderHandlesSHA256OID() throws {
        let sha256OID = Data([0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01])

        XCTAssertEqual(
            try RFC3161DER.decodeOID(sha256OID),
            [2, 16, 840, 1, 101, 3, 4, 2, 1]
        )
    }

    func testOIDDecoderRejectsOverflowAndTruncatedArc() {
        let overflowingOID = Data([0x2A] + Array(repeating: 0xFF, count: 12))
        let truncatedOID = Data([0x2A, 0x81])

        XCTAssertThrowsError(try RFC3161DER.decodeOID(overflowingOID))
        XCTAssertThrowsError(try RFC3161DER.decodeOID(truncatedOID))
    }

    func testOIDDecoderRejectsNonMinimalAndOversizedArcs() {
        let nonMinimalOID = Data([0x2A, 0x80, 0x01])
        let oversizedOID = Data(repeating: 0x01, count: 129)

        XCTAssertThrowsError(try RFC3161DER.decodeOID(nonMinimalOID))
        XCTAssertThrowsError(try RFC3161DER.decodeOID(oversizedOID))
    }

    func testGeneralizedTimePreservesMicroseconds() {
        XCTAssertEqual(
            RFC3161DER.parseGeneralizedTimeMicroseconds("19700101000000.123456789Z"),
            123_456
        )
        XCTAssertEqual(
            RFC3161DER.parseGeneralizedTimeMicroseconds("19700101000000.7Z"),
            700_000
        )
        XCTAssertEqual(
            RFC3161DER.parseGeneralizedTimeMicroseconds("19700101000000Z"),
            0
        )
    }

    func testGeneralizedTimeRejectsMalformedFractionAndTimezone() {
        XCTAssertNil(RFC3161DER.parseGeneralizedTimeMicroseconds("19700101000000.AZ"))
        XCTAssertNil(RFC3161DER.parseGeneralizedTimeMicroseconds("19700101000000.123"))
        XCTAssertNil(RFC3161DER.parseGeneralizedTimeMicroseconds("1970010100000Z"))
        XCTAssertNil(RFC3161DER.parseGeneralizedTimeMicroseconds("197001010000000Z"))
        XCTAssertNil(RFC3161DER.parseGeneralizedTimeMicroseconds("1970-01-01T00:00:00Z"))
    }

    #if os(macOS)
    func testTSTInfoAcceptsValidStructureAndPreservesMicroseconds() throws {
        let imprint = Data(repeating: 0xA5, count: 32)
        let content = makeTSTInfo(
            imprint: imprint,
            generationTime: "20261102202529Z",
            nonce: 42
        )

        let parsed = try RFC3161DER.inspectTSTInfo(
            token: content,
            expectedMessageImprint: imprint,
            expectedNonce: 42
        )

        XCTAssertEqual(
            parsed.genTimeUnixMicroseconds,
            try XCTUnwrap(RFC3161DER.parseGeneralizedTimeMicroseconds("20261102202529Z"))
        )
    }

    func testTSTInfoRejectsUnsupportedVersion() {
        let imprint = Data(repeating: 0xA5, count: 32)
        let content = makeTSTInfo(imprint: imprint, version: 2, nonce: 42)

        XCTAssertThrowsError(
            try RFC3161DER.inspectTSTInfo(
                token: content,
                expectedMessageImprint: imprint,
                expectedNonce: 42
            )
        )
    }

    func testTSTInfoRejectsOutOfOrderOptionalFields() {
        let imprint = Data(repeating: 0xA5, count: 32)
        let content = makeTSTInfo(
            imprint: imprint,
            nonce: 42,
            optionalFields: derBoolean(true) + derSequence(Data())
        )

        XCTAssertThrowsError(
            try RFC3161DER.inspectTSTInfo(
                token: content,
                expectedMessageImprint: imprint,
                expectedNonce: 42
            )
        )
    }

    func testTSTInfoRejectsMessageImprintMismatch() {
        let imprint = Data(repeating: 0xA5, count: 32)
        let differentImprint = Data(repeating: 0x5A, count: 32)
        let content = makeTSTInfo(imprint: differentImprint, nonce: 42)

        XCTAssertThrowsError(
            try RFC3161DER.inspectTSTInfo(
                token: content,
                expectedMessageImprint: imprint,
                expectedNonce: 42
            )
        )
    }



    func testTSAProfileRequiresSoleCriticalTimestampingEKU() throws {
        let time = try XCTUnwrap(RFC3161DER.parseGeneralizedTimeMicroseconds("20261113210519Z"))
        XCTAssertNoThrow(try RFC3161TSAProfile.validate(
            certificateDER: makeProfileCertificate(), generationTimeUnixMicroseconds: time
        ))
        XCTAssertThrowsError(try RFC3161TSAProfile.validate(
            certificateDER: makeProfileCertificate(includeEKU: false),
            generationTimeUnixMicroseconds: time
        ))
        XCTAssertThrowsError(try RFC3161TSAProfile.validate(
            certificateDER: makeProfileCertificate(critical: false),
            generationTimeUnixMicroseconds: time
        ))
        XCTAssertThrowsError(try RFC3161TSAProfile.validate(
            certificateDER: makeProfileCertificate(includeExtraPurpose: true),
            generationTimeUnixMicroseconds: time
        ))
    }

    func testTSAProfileChecksCertificateValidityAtGenerationTime() throws {
        let before = try XCTUnwrap(RFC3161DER.parseGeneralizedTimeMicroseconds("20261112210519Z"))
        let inside = try XCTUnwrap(RFC3161DER.parseGeneralizedTimeMicroseconds("20261113210519Z"))
        let after = try XCTUnwrap(RFC3161DER.parseGeneralizedTimeMicroseconds("20361111210519Z"))
        let certificate = makeProfileCertificate()
        XCTAssertThrowsError(try RFC3161TSAProfile.validate(
            certificateDER: certificate, generationTimeUnixMicroseconds: before
        ))
        XCTAssertNoThrow(try RFC3161TSAProfile.validate(
            certificateDER: certificate, generationTimeUnixMicroseconds: inside
        ))
        XCTAssertThrowsError(try RFC3161TSAProfile.validate(
            certificateDER: certificate, generationTimeUnixMicroseconds: after
        ))
    }

    private func makeProfileCertificate(
        includeEKU: Bool = true, critical: Bool = true, includeExtraPurpose: Bool = false
    ) -> Data {
        let algorithm = derSequence(derTLV(0x06, Data([0x2A, 0x03])))
        let usages = derTLV(0x06, Data([0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x08]))
            + (includeExtraPurpose ? derTLV(0x06, Data([0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01])) : Data())
        let eku = derSequence(derTLV(0x06, Data([0x55, 0x1D, 0x25]))
            + (critical ? derBoolean(true) : Data())
            + derTLV(0x04, derSequence(usages)))
        let extensions = derSequence(includeEKU ? eku : Data())
        let validity = derSequence(
            derTLV(0x17, Data("261113210517Z".utf8))
                + derTLV(0x17, Data("361110210517Z".utf8))
        )
        let tbs = derSequence(
            derTLV(0xA0, derInteger(2)) + derInteger(1) + algorithm
                + derSequence(Data()) + validity + derSequence(Data())
                + derSequence(Data()) + derTLV(0xA3, extensions)
        )
        return derSequence(tbs + algorithm + derTLV(0x03, Data([0x00])))
    }

    func testCMSFixtureVerifiesSignatureImprintNonceAndCertificate() throws {
        let token = try XCTUnwrap(Data(base64Encoded: signedTimestampTokenBase64))
        let imprint = Data(repeating: 0xA5, count: 32)

        let info = try RFC3161CMS.inspect(
            token: token,
            expectedMessageImprint: imprint,
            expectedNonce: 42
        )

        XCTAssertEqual(
            info.certificateSHA256,
            "0709b3073dfde7fc50eb7f814135b7722b10bc6459051d034e750c1f7a555f10"
        )
        XCTAssertEqual(
            info.genTimeUnixMicroseconds,
            try XCTUnwrap(RFC3161DER.parseGeneralizedTimeMicroseconds("20261113210519Z"))
        )
    }

    func testCMSFixtureRejectsWrongMessageImprint() throws {
        let token = try XCTUnwrap(Data(base64Encoded: signedTimestampTokenBase64))
        let wrongImprint = Data(repeating: 0x5A, count: 32)

        XCTAssertThrowsError(
            try RFC3161CMS.inspect(
                token: token,
                expectedMessageImprint: wrongImprint,
                expectedNonce: 42
            )
        )
    }

    func testCMSFixtureRejectsWrongNonce() throws {
        let token = try XCTUnwrap(Data(base64Encoded: signedTimestampTokenBase64))
        let imprint = Data(repeating: 0xA5, count: 32)

        XCTAssertThrowsError(
            try RFC3161CMS.inspect(
                token: token,
                expectedMessageImprint: imprint,
                expectedNonce: 43
            )
        )
    }

    func testCMSFixtureRejectsModifiedSignature() throws {
        var token = try XCTUnwrap(Data(base64Encoded: signedTimestampTokenBase64))
        let imprint = Data(repeating: 0xA5, count: 32)
        token[token.count - 1] ^= 0x01

        XCTAssertThrowsError(
            try RFC3161CMS.inspect(
                token: token,
                expectedMessageImprint: imprint,
                expectedNonce: 42
            )
        )
    }

    // OpenSSL-generated RFC 3161 test token: critical timestamping-only EKU,
    // SHA-256 imprint A5*32, nonce 42. Public test certificate only.
    private let signedTimestampTokenBase64 = """
    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
    """

    private func makeTSTInfo(
        imprint: Data,
        version: UInt8 = 1,
        generationTime: String = "20261102202529Z",
        nonce: UInt8?,
        optionalFields: Data = Data()
    ) -> Data {
        let sha256OID = derTLV(0x06, Data([0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01]))
        let algorithm = derSequence(sha256OID + Data([0x05, 0x00]))
        let messageImprint = derSequence(algorithm + derTLV(0x04, imprint))
        let policy = derTLV(0x06, Data([0x2A, 0x03]))
        var fields = derInteger(UInt64(version))
            + policy
            + messageImprint
            + derInteger(1)
            + derTLV(0x18, Data(generationTime.utf8))
            + optionalFields
        if let nonce {
            fields.append(derInteger(UInt64(nonce)))
        }
        return derSequence(fields)
    }
    #endif

    private func derSequence(_ contents: Data) -> Data {
        var result = Data([0x30])
        if contents.count < 128 {
            result.append(UInt8(contents.count))
        } else {
            var value = contents.count
            var bytes: [UInt8] = []
            while value > 0 {
                bytes.insert(UInt8(value & 0xFF), at: 0)
                value >>= 8
            }
            result.append(0x80 | UInt8(bytes.count))
            result.append(contentsOf: bytes)
        }
        result.append(contents)
        return result
    }

    private func derTLV(_ tag: UInt8, _ contents: Data) -> Data {
        var result = Data([tag])
        if contents.count < 128 {
            result.append(UInt8(contents.count))
        } else {
            var value = contents.count
            var bytes: [UInt8] = []
            while value > 0 {
                bytes.insert(UInt8(value & 0xFF), at: 0)
                value >>= 8
            }
            result.append(0x80 | UInt8(bytes.count))
            result.append(contentsOf: bytes)
        }
        result.append(contents)
        return result
    }

    private func derInteger(_ value: UInt64) -> Data {
        var bytes: [UInt8] = []
        var remaining = value
        repeat {
            bytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        } while remaining > 0
        if bytes[0] & 0x80 != 0 {
            bytes.insert(0, at: 0)
        }
        return derTLV(0x02, Data(bytes))
    }

    private func derBoolean(_ value: Bool) -> Data {
        derTLV(0x01, Data([value ? 0xFF : 0x00]))
    }
}
