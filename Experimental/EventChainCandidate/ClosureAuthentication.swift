import CryptoKit
import Foundation

enum AuthenticationFailure: String, Error {
    case traceMismatch = "TRACE_MISMATCH"
    case invalidEdge = "INVALID_TRACE_EDGE"
    case invalidPublicKey = "INVALID_PUBLIC_KEY"
    case keyMismatch = "KEY_ID_MISMATCH"
    case untrustedKey = "UNTRUSTED_KEY"
    case invalidSignature = "INVALID_SIGNATURE"
}

struct TraceEdge: Sendable {
    let sourceID: String
    let targetID: String
    let type: String
}

struct CoveredTrace: Sendable {
    let runID: String
    let contextID: String
    let events: [ChainEvent]
    let edges: [TraceEdge]
}

struct SignedClose: Sendable {
    var close: RunClose
    var publicKeyX963: Data
    var signatureDER: Data
}

private struct CanonicalEdge: Hashable {
    let source: UUID
    let target: UUID
    let type: String
}

enum ClosureAuthentication {
    private static let edgeTypes: Set<String> = [
        "derivedFrom", "influencedBy", "generatedFrom", "verifiedBy", "correctedBy", "informed"
    ]

    static func traceBytes(
        _ chain: EventChain, _ trace: CoveredTrace, expectedRunID: String
    ) throws -> Data {
        try ChainCodec.verify(chain, expectedRunID: expectedRunID)
        let run = try ChainCodec.uuid(expectedRunID)
        guard try ChainCodec.uuid(trace.runID) == run,
              trace.events.count == chain.entries.count else { throw AuthenticationFailure.traceMismatch }
        var result = ChainCodec.string("DPROVENANCEKIT-TRACE-ATTESTATION-V1") + ChainCodec.i64(1)
        result += try ChainCodec.uuidBytes(expectedRunID)
        result += ChainCodec.string(trace.contextID) + ChainCodec.u64(UInt64(trace.events.count))
        var ids = Set<UUID>()
        for (index, event) in trace.events.enumerated() {
            guard try ChainCodec.uuid(event.runID) == run,
                  Data(event.contextID.utf8) == Data(trace.contextID.utf8) else {
                throw AuthenticationFailure.traceMismatch
            }
            let bytes = try ChainCodec.eventBytes(event)
            guard try ChainCodec.eventBytes(chain.entries[index].event) == bytes else {
                throw AuthenticationFailure.traceMismatch
            }
            ids.insert(try ChainCodec.uuid(event.eventID))
            result += ChainCodec.u64(UInt64(index)) + bytes
        }
        var edges = Set<CanonicalEdge>()
        for edge in trace.edges {
            let source = try ChainCodec.uuid(edge.sourceID)
            let target = try ChainCodec.uuid(edge.targetID)
            guard source != target, ids.contains(source), ids.contains(target),
                  edgeTypes.contains(edge.type),
                  edges.insert(CanonicalEdge(source: source, target: target, type: edge.type)).inserted
            else { throw AuthenticationFailure.invalidEdge }
        }
        result += ChainCodec.u64(UInt64(edges.count))
        for edge in edges.sorted(by: {
            ($0.source.uuidString, $0.target.uuidString, $0.type) <
                ($1.source.uuidString, $1.target.uuidString, $1.type)
        }) {
            result += try ChainCodec.uuidBytes(edge.source.uuidString)
            result += try ChainCodec.uuidBytes(edge.target.uuidString)
            result += ChainCodec.string(edge.type)
        }
        return result
    }

    private static func publicKey(_ raw: Data) throws -> P256.Signing.PublicKey {
        guard raw.count == 65, raw.first == 4 else { throw AuthenticationFailure.invalidPublicKey }
        do {
            return try P256.Signing.PublicKey(x963Representation: raw)
        } catch {
            throw AuthenticationFailure.invalidPublicKey
        }
    }

    static func verify(
        _ chain: EventChain, _ trace: CoveredTrace, _ signed: SignedClose,
        expectedRunID: String, trustedKeyID: Data, requireEvidence: Bool = false
    ) throws {
        let trusted = try ChainCodec.hash(trustedKeyID)
        let preimage = try ChainCodec.closePreimage(signed.close)
        let key = try publicKey(signed.publicKeyX963)
        let keyID = ChainCodec.digest(signed.publicKeyX963)
        guard keyID == signed.close.keyID else { throw AuthenticationFailure.keyMismatch }
        guard keyID == trusted else { throw AuthenticationFailure.untrustedKey }
        guard (8...72).contains(signed.signatureDER.count),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: signed.signatureDER),
              signature.derRepresentation == signed.signatureDER,
              key.isValidSignature(signature, for: preimage) else {
            throw AuthenticationFailure.invalidSignature
        }
        try ChainCodec.verifyCloseBinding(chain, signed.close, expectedRunID: expectedRunID)
        let digest = try ChainCodec.digest(traceBytes(chain, trace, expectedRunID: expectedRunID))
        guard digest == signed.close.traceDigest else { throw AuthenticationFailure.traceMismatch }
        if requireEvidence && chain.entries.isEmpty { throw ChainFailure.empty }
    }

    // Provider takes message bytes, not a prehash. Software and Secure Enclave adapters
    // may supply their X9.63 key and DER-signing closure; hardware custody is not verified.
    static func sign(
        _ chain: EventChain, _ trace: CoveredTrace, expectedRunID: String,
        issuedAt: Int64, publicKeyX963: Data, signatureDER: (Data) throws -> Data
    ) throws -> SignedClose {
        _ = try publicKey(publicKeyX963)
        let digest = try ChainCodec.digest(traceBytes(chain, trace, expectedRunID: expectedRunID))
        let keyID = ChainCodec.digest(publicKeyX963)
        let count = UInt64(chain.entries.count)
        let close = RunClose(runID: expectedRunID, chainVersion: 1,
                             finalChainIndex: count == 0 ? nil : count - 1,
                             finalChainHead: chain.head, eventCount: count,
                             traceDigest: digest, keyID: keyID, issuedAtUnixMicroseconds: issuedAt)
        let signed = try SignedClose(close: close, publicKeyX963: publicKeyX963,
                                    signatureDER: signatureDER(ChainCodec.closePreimage(close)))
        try verify(chain, trace, signed, expectedRunID: expectedRunID, trustedKeyID: keyID)
        return signed
    }
}
