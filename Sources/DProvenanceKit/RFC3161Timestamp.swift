import CryptoKit
import Foundation

/// An RFC 3161 time-stamp token binding the DProvenanceKit attestation signing
/// payload to an externally asserted TSA time.
///
/// The token is retained verbatim so an auditor can verify it independently.
/// The message imprint is SHA-256 over the exact DPK attestation signing payload,
/// not the producer's local clock value.
public struct RFC3161Timestamp: Codable, Sendable, Equatable {
    public static let schemaVersion = 1

    public let version: Int
    public let tsaURL: String
    public let hashAlgorithm: String
    public let messageImprintSHA256: String
    public let nonce: UInt64
    public let genTimeUnixMicroseconds: Int64
    /// DER-encoded TimeStampToken (CMS ContentInfo), Base64 encoded.
    public let tokenBase64: String

    public init(
        version: Int = RFC3161Timestamp.schemaVersion,
        tsaURL: String,
        hashAlgorithm: String = "SHA-256",
        messageImprintSHA256: String,
        nonce: UInt64,
        genTimeUnixMicroseconds: Int64,
        tokenBase64: String
    ) {
        self.version = version
        self.tsaURL = tsaURL
        self.hashAlgorithm = hashAlgorithm
        self.messageImprintSHA256 = messageImprintSHA256
        self.nonce = nonce
        self.genTimeUnixMicroseconds = genTimeUnixMicroseconds
        self.tokenBase64 = tokenBase64
    }

    public var tokenData: Data? {
        Data(base64Encoded: tokenBase64)
    }
}

/// RFC 3161 client. The request contains only a SHA-256 message imprint and a
/// cryptographic nonce; the trace itself is never sent to the TSA.
public enum RFC3161TimestampClient {
    public enum Error: Swift.Error, Equatable {
        case invalidTSAURL
        case invalidHTTPResponse
        case tsaRejected(status: Int)
        case malformedResponse
        case missingToken
        case unsupportedHashAlgorithm
        case messageImprintMismatch
        case nonceMismatch
        case missingNonce
        case invalidGenerationTime
        case network(String)
    }

    public static func timestamp(
        document: TraceAttestationDocument,
        tsaURL: URL,
        timeout: TimeInterval = 30
    ) async throws -> RFC3161Timestamp {
        guard tsaURL.scheme?.lowercased() == "https" else {
            throw Error.invalidTSAURL
        }

        let signingPayload = TraceAttestationCanonicalizer.signingPayload(document.attestation)
        let messageImprint = Data(SHA256.hash(data: signingPayload))
        var generator = SystemRandomNumberGenerator()
        let nonce = UInt64.random(in: UInt64.min...UInt64.max, using: &generator)
        let requestData = RFC3161DER.timeStampRequest(
            messageImprint: messageImprint,
            nonce: nonce
        )

        var request = URLRequest(url: tsaURL)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/timestamp-query", forHTTPHeaderField: "Content-Type")
        request.setValue("application/timestamp-reply", forHTTPHeaderField: "Accept")
        request.httpBody = requestData

        let response: URLResponse
        let body: Data
        do {
            (body, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw Error.network(String(describing: error))
        }

        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw Error.invalidHTTPResponse
        }

        let parsed = try RFC3161DER.parseResponse(body)
        guard parsed.status == 0 || parsed.status == 1 else {
            throw Error.tsaRejected(status: parsed.status)
        }
        guard let token = parsed.token else {
            throw Error.missingToken
        }

        #if os(macOS)
        let tokenInfo = try RFC3161CMS.inspect(
            token: token,
            expectedMessageImprint: messageImprint,
            expectedNonce: nonce
        )
        #else
        // iOS does not expose Apple's CMS decoder APIs. The response is still
        // structurally checked and retained; use a macOS verifier or another
        // RFC 3161 verifier to establish TSA signature trust.
        let tokenInfo = try RFC3161DER.inspectTSTInfo(
            token: token,
            expectedMessageImprint: messageImprint,
            expectedNonce: nonce
        )
        #endif

        return RFC3161Timestamp(
            tsaURL: tsaURL.absoluteString,
            messageImprintSHA256: TraceAttestationCanonicalizer.hex(messageImprint),
            nonce: nonce,
            genTimeUnixMicroseconds: tokenInfo.genTimeUnixMicroseconds,
            tokenBase64: token.base64EncodedString()
        )
    }
}

/// A timestamped document is still the original DPK-signed artifact. Adding the
/// RFC 3161 token does not alter the DPK signature; the external token separately
/// commits to the exact signed envelope.
public extension TraceAttestationDocument {
    func addingExternalTimestamp(_ timestamp: RFC3161Timestamp) -> TraceAttestationDocument {
        TraceAttestationDocument(
            trace: trace,
            attestation: attestation,
            externalTimestamp: timestamp
        )
    }

    #if os(macOS)
    /// Verifies the DPK signature, then verifies the RFC 3161 CMS signature,
    /// SHA-256 message imprint, nonce, and a pinned TSA signer certificate.
    func verifyExternalTimestamp(
        trustedTSA: RFC3161TSATrust
    ) -> RFC3161TimestampVerification {
        RFC3161TimestampVerifier.verify(
            document: self,
            trustedTSA: trustedTSA
        )
    }
    #endif
}

#if os(macOS)

/// Trust configuration for an RFC 3161 TSA. Pin the TSA signing certificate's
/// SHA-256 fingerprint rather than trusting an arbitrary embedded certificate.
public struct RFC3161TSATrust: Sendable, Equatable {
    public let certificateSHA256: String

    public init(certificateSHA256: String) {
        self.certificateSHA256 = certificateSHA256.lowercased()
    }
}

public enum RFC3161TimestampVerificationFailure: String, Sendable, Equatable {
    case noTimestamp
    case attestationInvalid
    case malformedToken
    case unsupportedHashAlgorithm
    case messageImprintMismatch
    case nonceMismatch
    case invalidGenerationTime
    case cmsSignatureInvalid
    case tsaCertificateNotPinned
}

public struct RFC3161TimestampVerification: Sendable, Equatable {
    public let isValid: Bool
    public let generationTimeUnixMicroseconds: Int64?
    public let tsaCertificateSHA256: String?
    public let failure: RFC3161TimestampVerificationFailure?

    public init(
        isValid: Bool,
        generationTimeUnixMicroseconds: Int64?,
        tsaCertificateSHA256: String?,
        failure: RFC3161TimestampVerificationFailure?
    ) {
        self.isValid = isValid
        self.generationTimeUnixMicroseconds = generationTimeUnixMicroseconds
        self.tsaCertificateSHA256 = tsaCertificateSHA256
        self.failure = failure
    }
}

public enum RFC3161TimestampVerifier {
    public static func verify(
        document: TraceAttestationDocument,
        trustedTSA: RFC3161TSATrust
    ) -> RFC3161TimestampVerification {
        guard document.verify().isValid else {
            return RFC3161TimestampVerification(
                isValid: false,
                generationTimeUnixMicroseconds: nil,
                tsaCertificateSHA256: nil,
                failure: .attestationInvalid
            )
        }

        guard let timestamp = document.externalTimestamp else {
            return RFC3161TimestampVerification(
                isValid: false,
                generationTimeUnixMicroseconds: nil,
                tsaCertificateSHA256: nil,
                failure: .noTimestamp
            )
        }

        guard let token = timestamp.tokenData else {
            return RFC3161TimestampVerification(
                isValid: false,
                generationTimeUnixMicroseconds: nil,
                tsaCertificateSHA256: nil,
                failure: .malformedToken
            )
        }

        guard timestamp.hashAlgorithm == "SHA-256" else {
            return RFC3161TimestampVerification(
                isValid: false,
                generationTimeUnixMicroseconds: nil,
                tsaCertificateSHA256: nil,
                failure: .unsupportedHashAlgorithm
            )
        }

        let payload = TraceAttestationCanonicalizer.signingPayload(document.attestation)
        let expectedImprint = Data(SHA256.hash(data: payload))
        guard timestamp.messageImprintSHA256 == TraceAttestationCanonicalizer.hex(expectedImprint) else {
            return RFC3161TimestampVerification(
                isValid: false,
                generationTimeUnixMicroseconds: nil,
                tsaCertificateSHA256: nil,
                failure: .messageImprintMismatch
            )
        }

        do {
            let info = try RFC3161CMS.inspect(
                token: token,
                expectedMessageImprint: expectedImprint,
                expectedNonce: timestamp.nonce
            )

            guard info.genTimeUnixMicroseconds == timestamp.genTimeUnixMicroseconds else {
                return RFC3161TimestampVerification(
                    isValid: false,
                    generationTimeUnixMicroseconds: info.genTimeUnixMicroseconds,
                    tsaCertificateSHA256: info.certificateSHA256,
                    failure: .invalidGenerationTime
                )
            }

            guard info.certificateSHA256 == trustedTSA.certificateSHA256 else {
                return RFC3161TimestampVerification(
                    isValid: false,
                    generationTimeUnixMicroseconds: info.genTimeUnixMicroseconds,
                    tsaCertificateSHA256: info.certificateSHA256,
                    failure: .tsaCertificateNotPinned
                )
            }

            return RFC3161TimestampVerification(
                isValid: true,
                generationTimeUnixMicroseconds: info.genTimeUnixMicroseconds,
                tsaCertificateSHA256: info.certificateSHA256,
                failure: nil
            )
        } catch RFC3161DER.ParseError.unsupportedHashAlgorithm {
            return RFC3161TimestampVerification(
                isValid: false,
                generationTimeUnixMicroseconds: nil,
                tsaCertificateSHA256: nil,
                failure: .unsupportedHashAlgorithm
            )
        } catch RFC3161DER.ParseError.messageImprintMismatch {
            return RFC3161TimestampVerification(
                isValid: false,
                generationTimeUnixMicroseconds: nil,
                tsaCertificateSHA256: nil,
                failure: .messageImprintMismatch
            )
        } catch RFC3161DER.ParseError.nonceMismatch {
            return RFC3161TimestampVerification(
                isValid: false,
                generationTimeUnixMicroseconds: nil,
                tsaCertificateSHA256: nil,
                failure: .nonceMismatch
            )
        } catch RFC3161DER.ParseError.invalidGenerationTime {
            return RFC3161TimestampVerification(
                isValid: false,
                generationTimeUnixMicroseconds: nil,
                tsaCertificateSHA256: nil,
                failure: .invalidGenerationTime
            )
        } catch {
            return RFC3161TimestampVerification(
                isValid: false,
                generationTimeUnixMicroseconds: nil,
                tsaCertificateSHA256: nil,
                failure: .cmsSignatureInvalid
            )
        }
    }
}

private enum RFC3161CMS {
    struct Info {
        let genTimeUnixMicroseconds: Int64
        let certificateSHA256: String
    }

    static func inspect(
        token: Data,
        expectedMessageImprint: Data,
        expectedNonce: UInt64
    ) throws -> Info {
        var decoder: CMSDecoder?
        guard CMSDecoderCreate(&decoder) == errSecSuccess, let decoder else {
            throw RFC3161DER.ParseError.malformed
        }
        let updateStatus = token.withUnsafeBytes { rawBuffer -> OSStatus in
            guard let baseAddress = rawBuffer.baseAddress else {
                return errSecParam
            }
            return CMSDecoderUpdateMessage(
                decoder,
                baseAddress,
                rawBuffer.count
            )
        }
        guard updateStatus == errSecSuccess,
              CMSDecoderFinalizeMessage(decoder) == errSecSuccess else {
            throw RFC3161DER.ParseError.malformed
        }

        var signerCount = 0
        guard CMSDecoderGetNumSigners(decoder, &signerCount) == errSecSuccess,
              signerCount == 1 else {
            throw RFC3161DER.ParseError.malformed
        }

        var signerStatus = CMSSignerStatus.unsigned
        let policy = SecPolicyCreateBasicX509()
        let status = CMSDecoderCopySignerStatus(
            decoder,
            0,
            policy,
            false,
            &signerStatus,
            nil,
            nil
        )
        guard status == errSecSuccess, signerStatus == .valid else {
            throw RFC3161DER.ParseError.malformed
        }

        var certificate: SecCertificate?
        guard CMSDecoderCopySignerCert(decoder, 0, &certificate) == errSecSuccess,
              let certificate else {
            throw RFC3161DER.ParseError.malformed
        }
        let certificateData = SecCertificateCopyData(certificate) as Data
        let certificateSHA256 = TraceAttestationCanonicalizer.hex(
            SHA256.hash(data: certificateData)
        )

        var content: CFData?
        guard CMSDecoderCopyContent(decoder, &content) == errSecSuccess,
              let content else {
            throw RFC3161DER.ParseError.malformed
        }

        let info = try RFC3161DER.inspectTSTInfo(
            token: content as Data,
            expectedMessageImprint: expectedMessageImprint,
            expectedNonce: expectedNonce
        )
        return Info(
            genTimeUnixMicroseconds: info.genTimeUnixMicroseconds,
            certificateSHA256: certificateSHA256
        )
    }
}

#endif

private enum RFC3161DER {
    enum ParseError: Swift.Error {
        case malformed
        case unsupportedHashAlgorithm
        case messageImprintMismatch
        case nonceMismatch
        case missingNonce
        case invalidGenerationTime
    }

    struct Node {
        let tag: UInt8
        let value: Data
        let children: [Node]

        var isConstructed: Bool { (tag & 0x20) != 0 }

        var integer: UInt64? {
            guard tag == 0x02, !value.isEmpty else { return nil }
            var result: UInt64 = 0
            for byte in value {
                guard result <= (UInt64.max >> 8) else { return nil }
                result = (result << 8) | UInt64(byte)
            }
            return result
        }

        var stringValue: String? {
            String(data: value, encoding: .ascii)
        }
    }

    struct ParsedResponse {
        let status: Int
        let token: Data?
    }

    struct TSTInfo {
        let genTimeUnixMicroseconds: Int64
    }

    static func timeStampRequest(messageImprint: Data, nonce: UInt64) -> Data {
        let algorithmIdentifier = sequence(
            oid([2, 16, 840, 1, 101, 3, 4, 2, 1]),
            null()
        )
        let messageImprintSequence = sequence(
            algorithmIdentifier,
            octetString(messageImprint)
        )
        return sequence(
            integer(1),
            messageImprintSequence,
            integer(nonce),
            boolean(true)
        )
    }

    static func parseResponse(_ data: Data) throws -> ParsedResponse {
        let root = try parse(data)
        guard root.tag == 0x30, root.children.count >= 1,
              let statusValue = root.children[0].children.first?.integer,
              let status = Int(exactly: statusValue) else {
            throw ParseError.malformed
        }

        let token: Data?
        if root.children.count >= 2 {
            let tokenNode = root.children[1]
            guard tokenNode.tag == 0x30 else { throw ParseError.malformed }
            token = try encodeNode(tokenNode)
        } else {
            token = nil
        }
        return ParsedResponse(status: status, token: token)
    }

    static func inspectTSTInfo(
        token: Data,
        expectedMessageImprint: Data,
        expectedNonce: UInt64
    ) throws -> TSTInfo {
        let content: Data
        #if os(macOS)
        // On macOS this path is only used when the caller already extracted
        // the encapsulated TSTInfo through CMSDecoder.
        content = token
        #else
        // iOS has no public CMSDecoder API. A ContentInfo/SignedData envelope
        // contains TSTInfo inside the explicit [0] content wrapper. Locate the
        // first OCTET STRING that is the encapsulated content without accepting
        // arbitrary unrelated octet strings.
        let tokenRoot = try parse(token)
        guard tokenRoot.tag == 0x30 else { throw ParseError.malformed }
        guard let signedDataWrapper = tokenRoot.children.last(where: { $0.tag == 0xA0 }),
              let signedData = signedDataWrapper.children.first,
              signedData.tag == 0x30 else {
            throw ParseError.malformed
        }
        guard let eContentInfo = signedData.children.first(where: {
            $0.tag == 0x30 && $0.children.first?.tag == 0x06
        }) else {
            throw ParseError.malformed
        }
        guard let contentWrapper = eContentInfo.children.first(where: { $0.tag == 0xA0 }),
              let octets = contentWrapper.children.first,
              octets.tag == 0x04 else {
            throw ParseError.malformed
        }
        content = octets.value
        #endif

        let root = try parse(content)
        guard root.tag == 0x30, root.children.count >= 5 else {
            throw ParseError.malformed
        }

        let messageImprint = root.children[2]
        guard messageImprint.tag == 0x30,
              messageImprint.children.count >= 2,
              messageImprint.children[0].tag == 0x30,
              messageImprint.children[0].children.first?.tag == 0x06 else {
            throw ParseError.malformed
        }

        let sha256OID = [2, 16, 840, 1, 101, 3, 4, 2, 1]
        guard decodeOID(messageImprint.children[0].children[0].value) == sha256OID else {
            throw ParseError.unsupportedHashAlgorithm
        }
        guard messageImprint.children[1].tag == 0x04,
              messageImprint.children[1].value == expectedMessageImprint else {
            throw ParseError.messageImprintMismatch
        }

        var nonce: UInt64?
        for child in root.children.dropFirst(5) where child.tag == 0x02 {
            nonce = child.integer
            break
        }
        guard let nonce else { throw ParseError.missingNonce }
        guard nonce == expectedNonce else { throw ParseError.nonceMismatch }

        guard root.children[4].tag == 0x18,
              let generalizedTime = root.children[4].stringValue,
              let date = parseGeneralizedTime(generalizedTime) else {
            throw ParseError.invalidGenerationTime
        }

        return TSTInfo(
            genTimeUnixMicroseconds: Int64(date.timeIntervalSince1970 * 1_000_000)
        )
    }

    private static func parse(_ data: Data) throws -> Node {
        var offset = 0
        let node = try parseNode(data, offset: &offset)
        guard offset == data.count else { throw ParseError.malformed }
        return node
    }

    private static func parseNode(_ data: Data, offset: inout Int) throws -> Node {
        guard offset < data.count else { throw ParseError.malformed }
        let tag = data[offset]
        offset += 1

        guard offset < data.count else { throw ParseError.malformed }
        let firstLength = data[offset]
        offset += 1

        let length: Int
        if firstLength & 0x80 == 0 {
            length = Int(firstLength)
        } else {
            let count = Int(firstLength & 0x7F)
            guard count > 0, count <= 8, offset + count <= data.count else {
                throw ParseError.malformed
            }
            var value = 0
            for _ in 0..<count {
                guard value <= (Int.max >> 8) else { throw ParseError.malformed }
                value = (value << 8) | Int(data[offset])
                offset += 1
            }
            length = value
        }

        guard length >= 0, offset + length <= data.count else {
            throw ParseError.malformed
        }
        let value = data.subdata(in: offset..<(offset + length))
        offset += length

        if (tag & 0x20) != 0 {
            var childOffset = 0
            var children: [Node] = []
            while childOffset < value.count {
                children.append(try parseNode(value, offset: &childOffset))
            }
            guard childOffset == value.count else { throw ParseError.malformed }
            return Node(tag: tag, value: value, children: children)
        }
        return Node(tag: tag, value: value, children: [])
    }

    private static func encodeNode(_ node: Node) throws -> Data {
        var result = Data([node.tag])
        result.append(encodeLength(node.value.count))
        result.append(node.value)
        return result
    }

    private static func encodeLength(_ length: Int) -> Data {
        if length < 128 { return Data([UInt8(length)]) }
        var bytes: [UInt8] = []
        var value = length
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)]) + Data(bytes)
    }

    private static func integer(_ value: UInt64) -> Data {
        var bytes: [UInt8] = []
        var remaining = value
        repeat {
            bytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        } while remaining != 0
        if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return Data([0x02]) + encodeLength(bytes.count) + Data(bytes)
    }

    private static func oid(_ components: [Int]) -> Data {
        precondition(components.count >= 2)
        var bytes = Data([UInt8(components[0] * 40 + components[1])])
        for component in components.dropFirst(2) {
            var value = component
            var encoded: [UInt8] = [UInt8(value & 0x7F)]
            value >>= 7
            while value > 0 {
                encoded.insert(UInt8(value & 0x7F) | 0x80, at: 0)
                value >>= 7
            }
            bytes.append(contentsOf: encoded)
        }
        return Data([0x06]) + encodeLength(bytes.count) + bytes
    }

    private static func decodeOID(_ data: Data) -> [Int] {
        guard let first = data.first else { return [] }
        let firstValue = Int(first)
        var components = [min(firstValue / 40, 2), firstValue % 40]
        var value = 0
        for byte in data.dropFirst() {
            value = (value << 7) | Int(byte & 0x7F)
            if byte & 0x80 == 0 {
                components.append(value)
                value = 0
            }
        }
        return components
    }

    private static func sequence(_ values: Data...) -> Data {
        let body = values.reduce(into: Data()) { $0.append($1) }
        return Data([0x30]) + encodeLength(body.count) + body
    }

    private static func octetString(_ value: Data) -> Data {
        Data([0x04]) + encodeLength(value.count) + value
    }

    private static func null() -> Data {
        Data([0x05, 0x00])
    }

    private static func boolean(_ value: Bool) -> Data {
        Data([0x01, 0x01, value ? 0xFF : 0x00])
    }

    private static func parseGeneralizedTime(_ value: String) -> Date? {
        guard value.hasSuffix("Z") else { return nil }
        let raw = String(value.dropLast())
        let components = raw.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let base = String(components[0])

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = components.count == 1
            ? "yyyyMMddHHmmss"
            : "yyyyMMddHHmmss.SSS"

        if components.count == 1 {
            return formatter.date(from: base)
        }

        let fraction = String(components[1])
        guard fraction.allSatisfy({ $0.isNumber }) else { return nil }
        let millis = String((fraction + "000").prefix(3))
        return formatter.date(from: base + "." + millis)
    }
}
