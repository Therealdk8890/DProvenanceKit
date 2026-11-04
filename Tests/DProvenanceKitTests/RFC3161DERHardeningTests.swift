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
            "4e3998dfb1ea301de86bc35e4fe7aa836dde3d8da9b4c295d6a091ae8d6400db"
        )
        XCTAssertEqual(
            info.genTimeUnixMicroseconds,
            try XCTUnwrap(RFC3161DER.parseGeneralizedTimeMicroseconds("20261102202529Z"))
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

    private let signedTimestampTokenBase64 = """
    MIIFgwYJKoZIhvcNAQcCoIIFdDCCBXACAQMxDTALBglghkgBZQMEAgEwZAYLKoZIhvcNAQkQAQSgVQRTMFECAQEGAioDMDEwDQYJYIZIAWUDBAIBBQAEIKWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlAgEBGA8yMDI2MTEwMjIwMjUyOVoCASqgggMjMIIDHzCCAgegAwIBAgIUfKK7U7BZZIwtXYirsl55hvkvE0EwDQYJKoZIhvcNAQELBQAwHzEdMBsGA1UEAwwURFBLIFJGQzMxNjEgVGVzdCBUU0EwHhcNMjYxMTAyMjIwNDE0WhcNMzYxMDMwMjIwNDE0WjAfMR0wGwYDVQQDDBREUEsgUkZDMzE2MSBUZXN0IFRTQTCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAPesMMK/puoXS5KlhQVVp5TDXyOKAZwbH5vT+/JvnXCGvWfH+hNjWVhKElfsqfMXetYQ7RvuksUX78ogB7rXdlBMxTpHT8NsoL12oERZPnDAAU98gzsMO6flL6qarT5xM760y8IFCVxocI8p4FgV2iyZt1gFag/ZN3mMpCaIaNlVq36i3dPqe+rWn3GDicw1SP9Tg7Mo04gSqhHIu/SHd2FLM0l2Xe4OUt/ptRK1QAMav4Cu5ZYRcxZBw+3L/OLLARon8QPNhyqNiv6N6H17J9IwE1htblhkUYCOe2/jnnCgXlqdI+eOhv0N//2Fcaz8bd/VN0wQ3QB5cdTDlG3Hor8CAwEAAaNTMFEwHQYDVR0OBBYEFMSdYx76qLwk6g5UhFuwJPhWxFn8MB8GA1UdIwQYMBaAFMSdYx76qLwk6g5UhFuwJPhWxFn8MA8GA1UdEwEB/wQFMAMBAf8wDQYJKoZIhvcNAQELBQADggEBAG2MoRmb8f/Io+9HeaRHZc69/nuM6N11/nI/WyXiZacvEdo7MOpJO30YwK0uc4Bq/D2MOCafK5H4HJ/D3F1ouxXavN7eRlQZaS2ZtR+GvDP1fmpN2e1/lZqFjL8MevNBKA6rbq3Xh6VGXkul9AQc/Oo6Q2uKBKfZxv81/czspnzBMraV0NcOu+uY6dqWSFv8UqHywQhy+XNbw1jOiqDO4F8lVOg/MsSScuP0bs0zrq0RgdNo4Zf6PnKxLy1/5GW/3AHqhB7wTdypiKTRgL7j2Bh3EikEHMLB5ao2gNuZfD1a7cIjTnB7qye5T07DOJ5uatLB1ntcBrMzoIplnMtKMKQxggHNMIIByQIBATA3MB8xHTAbBgNVBAMMFERQSyBSRkMzMTYxIFRlc3QgVFNBAhR8ortTsFlkjC1diKuyXnmG+S8TQTALBglghkgBZQMEAgGgazAaBgkqhkiG9w0BCQMxDQYLKoZIhvcNAQkQAQQwHAYJKoZIhvcNAQkFMQ8XDTI2MTEwMjIyMDQxNFowLwYJKoZIhvcNAQkEMSIEIN0dckQ2PPJiFVUYUyq4+zCkJJTJJCp+IhYJX/IOZZPVMA0GCSqGSIb3DQEBAQUABIIBAFjwYbRxCQI2RePXBD33n+nC/Y9hbIsLbDUwE3BVXvUkbIBs32VXOV5Ki0Gss+Aixp16Glt5h5uL+0GOK6ZCu4Rhz/nuUNDw/StdhI1mYPzg4iRDeaHvGEcZ0FT2VA7LjWRMs4f2LckpjvOLCve5gW4WLlPnBUAupBbm2PVHwjDALR16aM3MshJ0wPzD4sbjoMaXrzvcUc4QA1wyVliYnsh/eqr+PR2cLL6oVoisB9GdKjBgg5fU5W+w5f6KiOD+mlVLGaN2mgNu/RcWrI1yvmI+qMBJ8lCMevfS9bliLPeGvGz5cKA3SWgbS2AC84ua5aCfPOo8kFS3jNeBz9+X55s=
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
