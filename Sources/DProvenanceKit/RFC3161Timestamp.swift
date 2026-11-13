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
        guard tokenBase64.utf8.count <= RFC3161DER.maximumBase64Size else {
            return nil
        }
        return Data(base64Encoded: tokenBase64)
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
/// RFC 3161 token does not alter the DPK signature; the external token commits to
/// the canonical attestation signing payload, excluding the signature bytes.
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
    case unsupportedVersion
    case attestationInvalid
    case malformedToken
    case unsupportedHashAlgorithm
    case messageImprintMismatch
    case nonceMismatch
    case invalidGenerationTime
    case cmsSignatureInvalid
    case tsaCertificateNotPinned
    case tsaCertificateProfileInvalid
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

        guard timestamp.version == RFC3161Timestamp.schemaVersion else {
            return RFC3161TimestampVerification(
                isValid: false,
                generationTimeUnixMicroseconds: nil,
                tsaCertificateSHA256: nil,
                failure: .unsupportedVersion
            )
        }

        guard let token = timestamp.tokenData, token.count <= RFC3161DER.maximumTokenSize else {
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
        } catch is RFC3161TSAProfile.ProfileError {
            return RFC3161TimestampVerification(
                isValid: false,
                generationTimeUnixMicroseconds: nil,
                tsaCertificateSHA256: nil,
                failure: .tsaCertificateProfileInvalid
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

/// Enforce the RFC 3161 TSA signer certificate profile in addition to the
/// CMS signature and exact certificate fingerprint pin. This intentionally
/// does not evaluate a PKI chain or perform revocation checks: the independent
/// fingerprint pin is the trust anchor for this verifier.
enum RFC3161TSAProfile {
    enum ProfileError: Error {
        case invalidCertificate
        case invalidExtendedKeyUsage
        case outsideCertificateValidity
    }

    static func validate(
        certificateDER: Data,
        generationTimeUnixMicroseconds: Int64
    ) throws {
        let certificate = try RFC3161DER.parse(certificateDER)
        guard certificate.tag == 0x30, certificate.children.count == 3,
              certificate.children[0].tag == 0x30 else {
            throw ProfileError.invalidCertificate
        }
        let tbs = certificate.children[0]
        // RFC 5280 TBSCertificate: [0] version, serial, signature, issuer,
        // validity, subject, subjectPublicKeyInfo, optional [3] extensions.
        guard tbs.children.count >= 7, tbs.children[0].tag == 0xA0,
              tbs.children[0].children.count == 1,
              tbs.children[0].children[0].integer == 2,
              tbs.children[1].tag == 0x02,
              tbs.children[4].tag == 0x30,
              tbs.children[4].children.count == 2 else {
            throw ProfileError.invalidCertificate
        }
        let validity = tbs.children[4].children
        guard let notBefore = certificateTime(validity[0]),
              let notAfter = certificateTime(validity[1]),
              notBefore <= notAfter,
              generationTimeUnixMicroseconds >= notBefore,
              generationTimeUnixMicroseconds <= notAfter else {
            throw ProfileError.outsideCertificateValidity
        }

        let extensionWrappers = tbs.children.filter { $0.tag == 0xA3 }
        guard extensionWrappers.count == 1,
              extensionWrappers[0].children.count == 1,
              extensionWrappers[0].children[0].tag == 0x30 else {
            throw ProfileError.invalidExtendedKeyUsage
        }
        let extensions = extensionWrappers[0].children[0].children
        let ekuOID = [2, 5, 29, 37]
        let timestampingOID = [1, 3, 6, 1, 5, 5, 7, 3, 8]
        var foundEKU = false
        for ext in extensions {
            guard ext.tag == 0x30,
                  (2...3).contains(ext.children.count),
                  ext.children[0].tag == 0x06 else {
                throw ProfileError.invalidCertificate
            }
            let oid = try RFC3161DER.decodeOID(ext.children[0].value)
            guard oid == ekuOID else { continue }
            guard !foundEKU, ext.children.count == 3,
                  ext.children[1].tag == 0x01,
                  ext.children[1].value == Data([0xFF]),
                  ext.children[2].tag == 0x04 else {
                throw ProfileError.invalidExtendedKeyUsage
            }
            let usages = try RFC3161DER.parse(ext.children[2].value)
            guard usages.tag == 0x30, usages.children.count == 1,
                  usages.children[0].tag == 0x06,
                  try RFC3161DER.decodeOID(usages.children[0].value) == timestampingOID else {
                throw ProfileError.invalidExtendedKeyUsage
            }
            foundEKU = true
        }
        guard foundEKU else { throw ProfileError.invalidExtendedKeyUsage }
    }

    private static func certificateTime(_ node: RFC3161DER.Node) -> Int64? {
        guard let value = node.stringValue else { return nil }
        switch node.tag {
        case 0x17: // UTCTime YYMMDDHHMMSSZ, 1950-2049 per RFC 5280.
            guard value.count == 13, value.hasSuffix("Z"),
                  let year = Int(value.prefix(2)) else { return nil }
            let century = year >= 50 ? "19" : "20"
            return RFC3161DER.parseGeneralizedTimeMicroseconds(century + value)
        case 0x18: // GeneralizedTime YYYYMMDDHHMMSSZ.
            guard value.count == 15 else { return nil }
            return RFC3161DER.parseGeneralizedTimeMicroseconds(value)
        default:
            return nil
        }
    }
}

enum RFC3161CMS {
    enum CMSDecodeError: Error, CustomStringConvertible {
        case update(OSStatus)
        case finalize(OSStatus)
        case detachedContent(OSStatus)
        case signerStatus(OSStatus, UInt32, Bool)

        var description: String {
            switch self {
            case .update(let status):
                return "CMSDecoderUpdateMessage failed with OSStatus \(status)"
            case .finalize(let status):
                return "CMSDecoderFinalizeMessage failed with OSStatus \(status)"
            case .detachedContent(let status):
                return "CMSDecoderSetDetachedContent failed with OSStatus \(status)"
            case .signerStatus(let status, let signerStatus, let hasTrust):
                return "CMSDecoderCopySignerStatus failed: OSStatus \(status), signer status \(signerStatus), trust returned \(hasTrust)"
            }
        }
    }

    struct Info {
        let genTimeUnixMicroseconds: Int64
        let certificateSHA256: String
    }

    static func inspect(
        token: Data,
        expectedMessageImprint: Data,
        expectedNonce: UInt64
    ) throws -> Info {
        // Apple’s CMSDecoder can report needsDetachedContent for RFC 3161’s
        // id-ct-TSTInfo content type. Extract the embedded DER payload first;
        // if the decoder requests detached content, supply these exact bytes
        // from the token so the CMS signature is still checked over its payload.
        let encapsulatedContent = try RFC3161DER.encapsulatedTSTInfo(token: token)
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
        guard updateStatus == errSecSuccess else {
            throw CMSDecodeError.update(updateStatus)
        }
        let finalizeStatus = CMSDecoderFinalizeMessage(decoder)
        guard finalizeStatus == errSecSuccess else {
            throw CMSDecodeError.finalize(finalizeStatus)
        }

        var signerCount = 0
        guard CMSDecoderGetNumSigners(decoder, &signerCount) == errSecSuccess,
              signerCount == 1 else {
            throw RFC3161DER.ParseError.malformed
        }

        var signerStatus = CMSSignerStatus.unsigned
        var signerTrust: SecTrust?
        let policy = SecPolicyCreateBasicX509()
        var status = CMSDecoderCopySignerStatus(
            decoder,
            0,
            policy,
            false,
            &signerStatus,
            &signerTrust,
            nil
        )
        if status == errSecSuccess, signerStatus == .needsDetachedContent {
            let detachedStatus = CMSDecoderSetDetachedContent(decoder, encapsulatedContent as CFData)
            guard detachedStatus == errSecSuccess else {
                throw CMSDecodeError.detachedContent(detachedStatus)
            }
            signerStatus = .unsigned
            signerTrust = nil
            status = CMSDecoderCopySignerStatus(
                decoder,
                0,
                policy,
                false,
                &signerStatus,
                &signerTrust,
                nil
            )
        }
        guard status == errSecSuccess, signerStatus == .valid, signerTrust != nil else {
            throw CMSDecodeError.signerStatus(status, signerStatus.rawValue, signerTrust != nil)
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

        let info = try RFC3161DER.inspectTSTInfo(
            token: encapsulatedContent,
            expectedMessageImprint: expectedMessageImprint,
            expectedNonce: expectedNonce
        )
        try RFC3161TSAProfile.validate(
            certificateDER: certificateData,
            generationTimeUnixMicroseconds: info.genTimeUnixMicroseconds
        )
        return Info(
            genTimeUnixMicroseconds: info.genTimeUnixMicroseconds,
            certificateSHA256: certificateSHA256
        )
    }
}

#endif

enum RFC3161DER {
    static let maximumTokenSize = 1_048_576
    static let maximumBase64Size = ((maximumTokenSize + 2) / 3) * 4
    static let maximumNestingDepth = 32
    static let maximumNodeCount = 10_000

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
            guard tag == 0x02, !value.isEmpty,
                  value[0] & 0x80 == 0 else { return nil }
            if value.count > 1, value[0] == 0, value[1] & 0x80 == 0 {
                return nil
            }
            var result: UInt64 = 0
            for byte in value {
                let digit = UInt64(byte)
                guard result <= (UInt64.max - digit) / 256 else { return nil }
                result = result * 256 + digit
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
        guard root.tag == 0x30,
              (1...2).contains(root.children.count),
              root.children[0].tag == 0x30,
              let statusValue = root.children[0].children.first?.integer,
              let status = Int(exactly: statusValue),
              (0...5).contains(status) else {
            throw ParseError.malformed
        }

        let token: Data?
        if root.children.count == 2 {
            let tokenNode = root.children[1]
            guard tokenNode.tag == 0x30 else { throw ParseError.malformed }
            token = try encodeNode(tokenNode)
        } else {
            token = nil
        }
        return ParsedResponse(status: status, token: token)
    }

    static func encapsulatedTSTInfo(token: Data) throws -> Data {
        let root = try parse(token)
        guard root.tag == 0x30,
              root.children.count == 2,
              root.children[0].tag == 0x06,
              try decodeOID(root.children[0].value) == [1, 2, 840, 113549, 1, 7, 2],
              root.children[1].tag == 0xA0,
              root.children[1].children.count == 1 else {
            throw ParseError.malformed
        }

        let signedData = root.children[1].children[0]
        guard signedData.tag == 0x30,
              signedData.children.count >= 4,
              signedData.children[2].tag == 0x30 else {
            throw ParseError.malformed
        }

        let encapContentInfo = signedData.children[2]
        guard encapContentInfo.children.count == 2,
              encapContentInfo.children[0].tag == 0x06,
              try decodeOID(encapContentInfo.children[0].value) == [1, 2, 840, 113549, 1, 9, 16, 1, 4],
              encapContentInfo.children[1].tag == 0xA0,
              encapContentInfo.children[1].children.count == 1,
              encapContentInfo.children[1].children[0].tag == 0x04 else {
            throw ParseError.malformed
        }

        return encapContentInfo.children[1].children[0].value
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
        guard root.tag == 0x30,
              root.children.count >= 5,
              root.children.count <= 10,
              root.children[0].tag == 0x02,
              root.children[0].integer == 1,
              root.children[1].tag == 0x06,
              root.children[2].tag == 0x30,
              root.children[3].tag == 0x02,
              let serialNumber = root.children[3].integer,
              serialNumber > 0,
              root.children[4].tag == 0x18 else {
            throw ParseError.malformed
        }

        // RFC 3161 TSTInfo optional fields have a fixed order and may occur
        // at most once: accuracy, ordering, nonce, TSA name, extensions.
        let optionalTags: [UInt8] = [0x30, 0x01, 0x02, 0xA0, 0xA1]
        var previousOptionalIndex = -1
        for child in root.children.dropFirst(5) {
            guard let index = optionalTags.firstIndex(of: child.tag),
                  index > previousOptionalIndex else {
                throw ParseError.malformed
            }
            previousOptionalIndex = index
        }

        let messageImprint = root.children[2]
        guard messageImprint.tag == 0x30,
              messageImprint.children.count == 2,
              messageImprint.children[0].tag == 0x30,
              (1...2).contains(messageImprint.children[0].children.count),
              messageImprint.children[0].children.first?.tag == 0x06 else {
            throw ParseError.malformed
        }
        if messageImprint.children[0].children.count == 2 {
            let parameters = messageImprint.children[0].children[1]
            guard parameters.tag == 0x05, parameters.value.isEmpty else {
                throw ParseError.malformed
            }
        }

        let sha256OID = [2, 16, 840, 1, 101, 3, 4, 2, 1]
        guard try decodeOID(messageImprint.children[0].children[0].value) == sha256OID else {
            throw ParseError.unsupportedHashAlgorithm
        }
        guard messageImprint.children[1].tag == 0x04,
              messageImprint.children[1].value == expectedMessageImprint else {
            throw ParseError.messageImprintMismatch
        }

        let nonce = root.children.dropFirst(5).first(where: { $0.tag == 0x02 })?.integer
        guard let nonce else { throw ParseError.missingNonce }
        guard nonce == expectedNonce else { throw ParseError.nonceMismatch }

        guard let generalizedTime = root.children[4].stringValue,
              let generationTime = parseGeneralizedTimeMicroseconds(generalizedTime) else {
            throw ParseError.invalidGenerationTime
        }

        return TSTInfo(genTimeUnixMicroseconds: generationTime)
    }

    static func parse(_ data: Data) throws -> Node {
        guard !data.isEmpty, data.count <= maximumTokenSize else {
            throw ParseError.malformed
        }
        var offset = 0
        var nodeCount = 0
        let node = try parseNode(
            data,
            offset: &offset,
            depth: 0,
            nodeCount: &nodeCount
        )
        guard offset == data.count else { throw ParseError.malformed }
        return node
    }

    private static func parseNode(
        _ data: Data,
        offset: inout Int,
        depth: Int,
        nodeCount: inout Int
    ) throws -> Node {
        guard depth <= maximumNestingDepth,
              nodeCount < maximumNodeCount,
              offset < data.count else {
            throw ParseError.malformed
        }
        nodeCount += 1

        let tag = data[offset]
        offset += 1
        // High-tag-number form is not used by the RFC 3161/CMS structures
        // accepted here. Reject it rather than misreading tag octets as length.
        guard tag & 0x1F != 0x1F else { throw ParseError.malformed }

        guard offset < data.count else { throw ParseError.malformed }
        let firstLength = data[offset]
        offset += 1

        let length: Int
        if firstLength & 0x80 == 0 {
            length = Int(firstLength)
        } else {
            let count = Int(firstLength & 0x7F)
            guard count > 0,
                  count <= MemoryLayout<Int>.size,
                  count <= data.count - offset,
                  data[offset] != 0 else {
                throw ParseError.malformed
            }
            var value = 0
            for _ in 0..<count {
                let byte = Int(data[offset])
                guard value <= (Int.max - byte) / 256 else {
                    throw ParseError.malformed
                }
                value = value * 256 + byte
                offset += 1
            }
            // DER requires long-form lengths only for values >= 128.
            guard value >= 128 else { throw ParseError.malformed }
            length = value
        }

        guard length <= data.count - offset else {
            throw ParseError.malformed
        }
        let end = offset + length
        let value = data.subdata(in: offset..<end)
        offset = end

        if (tag & 0x20) != 0 {
            var childOffset = 0
            var children: [Node] = []
            while childOffset < value.count {
                children.append(try parseNode(
                    value,
                    offset: &childOffset,
                    depth: depth + 1,
                    nodeCount: &nodeCount
                ))
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

    static func decodeOID(_ data: Data) throws -> [Int] {
        guard !data.isEmpty, data.count <= 128 else {
            throw ParseError.malformed
        }

        var subidentifiers: [Int] = []
        var value = 0
        var hasContinuation = false
        var atArcStart = true

        for byte in data {
            // A leading zero base-128 digit is a non-minimal DER OID arc.
            if atArcStart, byte == 0x80 {
                throw ParseError.malformed
            }
            let digit = Int(byte & 0x7F)
            guard value <= (Int.max - digit) / 128 else {
                throw ParseError.malformed
            }
            value = value * 128 + digit
            hasContinuation = byte & 0x80 != 0
            atArcStart = !hasContinuation
            if !hasContinuation {
                subidentifiers.append(value)
                value = 0
            }
        }
        guard !hasContinuation, let firstValue = subidentifiers.first else {
            throw ParseError.malformed
        }

        let firstArc = min(firstValue / 40, 2)
        let secondArc = firstValue - (firstArc * 40)
        return [firstArc, secondArc] + subidentifiers.dropFirst()
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

    static func parseGeneralizedTimeMicroseconds(_ value: String) -> Int64? {
        guard value.hasSuffix("Z") else { return nil }
        let raw = String(value.dropLast())
        let components = raw.split(
            separator: ".",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard components[0].count == 14,
              components[0].allSatisfy({ $0.isASCII && $0.isNumber }) else {
            return nil
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.isLenient = false
        formatter.dateFormat = "yyyyMMddHHmmss"
        guard let date = formatter.date(from: String(components[0])) else {
            return nil
        }

        var fractionalMicroseconds: Int64 = 0
        if components.count == 2 {
            let fraction = String(components[1])
            guard !fraction.isEmpty, fraction.allSatisfy({ $0.isASCII && $0.isNumber }) else {
                return nil
            }
            let sixDigits = String((fraction + "000000").prefix(6))
            guard let parsed = Int64(sixDigits) else { return nil }
            fractionalMicroseconds = parsed
        }

        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite,
              seconds >= Double(Int64.min / 1_000_000),
              seconds <= Double(Int64.max / 1_000_000) else {
            return nil
        }
        let wholeSeconds = Int64(seconds.rounded(.towardZero))
        let (base, overflow) = wholeSeconds.multipliedReportingOverflow(by: 1_000_000)
        guard !overflow else { return nil }
        let (result, additionOverflow) = base.addingReportingOverflow(fractionalMicroseconds)
        return additionOverflow ? nil : result
    }
}
