import CryptoKit
import Foundation

/// The deterministic, payload-preserving representation covered by a trace attestation.
///
/// Event order is significant. Lineage edges are sorted canonically because their array order
/// is not semantically meaningful. Payloads use sorted-key JSON before entering the binary
/// canonicalization format.
public struct AttestableTrace: Codable, Sendable, Equatable {
    public static let schemaVersion = 1

    public let runID: UUID
    public let contextID: String
    public let events: [AttestableTraceEvent]
    public let edges: [TraceEdge]

    public init(
        runID: UUID,
        contextID: String,
        events: [AttestableTraceEvent],
        edges: [TraceEdge] = []
    ) {
        self.runID = runID
        self.contextID = contextID
        self.events = events
        self.edges = edges
    }

    public init<T: TraceableEvent>(run: TraceRun<T>, edges: [TraceEdge] = []) throws {
        // A run with undecoded events is a SUBSET of what was recorded. Signing it
        // would produce a cryptographically valid attestation that presents that
        // subset as the whole run — the exact dishonesty the count exists to prevent.
        // Re-read the store with the payload type the rows were written as, or attest
        // from the raw rows, but never silently shed the omission at the signing
        // boundary.
        guard run.undecodedEventCount == 0 else {
            throw TraceAttestationError.undecodedEvents(count: run.undecodedEventCount)
        }
        self.runID = run.runID
        self.contextID = run.contextID
        self.events = try run.events.map(AttestableTraceEvent.init)
        self.edges = edges
    }
}

/// A type-erased trace event whose canonical payload bytes can be verified without importing
/// the application's private `TraceableEvent` type.
public struct AttestableTraceEvent: Codable, Sendable, Equatable {
    public let id: UUID
    public let runID: UUID
    public let contextID: String
    public let engineName: String
    public let schemaVersion: Int
    public let sequence: UInt64
    public let spanID: String?
    public let parentSpanID: String?
    public let typeIdentifier: String
    public let priority: Int
    public let payloadJSON: String
    public let timestampUnixMicroseconds: Int64

    public init(
        id: UUID,
        runID: UUID,
        contextID: String,
        engineName: String,
        schemaVersion: Int,
        sequence: UInt64,
        spanID: String?,
        parentSpanID: String?,
        typeIdentifier: String,
        priority: Int,
        payloadJSON: String,
        timestampUnixMicroseconds: Int64
    ) {
        self.id = id
        self.runID = runID
        self.contextID = contextID
        self.engineName = engineName
        self.schemaVersion = schemaVersion
        self.sequence = sequence
        self.spanID = spanID
        self.parentSpanID = parentSpanID
        self.typeIdentifier = typeIdentifier
        self.priority = priority
        self.payloadJSON = payloadJSON
        self.timestampUnixMicroseconds = timestampUnixMicroseconds
    }

    public init<T: TraceableEvent>(_ event: TraceEvent<T>) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.dataEncodingStrategy = .base64
        encoder.nonConformingFloatEncodingStrategy = .throw

        let payloadData = try encoder.encode(event.payload)
        guard let payloadJSON = String(data: payloadData, encoding: .utf8) else {
            throw TraceAttestationError.payloadIsNotUTF8
        }

        self.init(
            id: event.id,
            runID: event.runID,
            contextID: event.contextID,
            engineName: event.engineName,
            schemaVersion: event.schemaVersion,
            sequence: event.sequence,
            spanID: event.spanID,
            parentSpanID: event.parentSpanID,
            typeIdentifier: event.payload.typeIdentifier,
            priority: event.payload.priority.rawValue,
            payloadJSON: payloadJSON,
            timestampUnixMicroseconds: Int64(event.timestamp.timeIntervalSince1970 * 1_000_000)
        )
    }
}

public enum TraceAttestationAlgorithm: String, Codable, Sendable {
    /// ECDSA over NIST P-256 with SHA-256, encoded as a DER signature.
    case p256SHA256 = "P256-SHA256"
}

public enum TraceAttestationCanonicalization: String, Codable, Sendable {
    /// Length-prefixed, big-endian DProvenanceKit trace canonicalization version 1.
    case dpkBinaryV1 = "DPK-BINARY-V1"
}

/// A portable signature envelope. It embeds the public key needed for offline verification;
/// callers that need signer identity must also pin `keyID` to a trusted key.
public struct TraceAttestation: Codable, Sendable, Equatable {
    public static let schemaVersion = 1

    public let version: Int
    public let algorithm: TraceAttestationAlgorithm
    public let canonicalization: TraceAttestationCanonicalization
    public let runID: UUID
    public let contextID: String
    public let eventCount: Int
    public let edgeCount: Int
    public let traceDigest: String
    public let issuedAtUnixMicroseconds: Int64
    public let keyID: String
    public let publicKeyBase64: String
    public let signatureBase64: String

    public init(
        version: Int = TraceAttestation.schemaVersion,
        algorithm: TraceAttestationAlgorithm = .p256SHA256,
        canonicalization: TraceAttestationCanonicalization = .dpkBinaryV1,
        runID: UUID,
        contextID: String,
        eventCount: Int,
        edgeCount: Int,
        traceDigest: String,
        issuedAtUnixMicroseconds: Int64,
        keyID: String,
        publicKeyBase64: String,
        signatureBase64: String
    ) {
        self.version = version
        self.algorithm = algorithm
        self.canonicalization = canonicalization
        self.runID = runID
        self.contextID = contextID
        self.eventCount = eventCount
        self.edgeCount = edgeCount
        self.traceDigest = traceDigest
        self.issuedAtUnixMicroseconds = issuedAtUnixMicroseconds
        self.keyID = keyID
        self.publicKeyBase64 = publicKeyBase64
        self.signatureBase64 = signatureBase64
    }
}

/// A self-contained, portable artifact for offline verification. The document contains the
/// trace and its signature envelope, but never private key material.
public struct TraceAttestationDocument: Codable, Sendable, Equatable {
    public let trace: AttestableTrace
    public let attestation: TraceAttestation

    public init(trace: AttestableTrace, attestation: TraceAttestation) {
        self.trace = trace
        self.attestation = attestation
    }

    public static func signed<T: TraceableEvent, Key: TraceAttestationSigningKey>(
        run: TraceRun<T>,
        edges: [TraceEdge] = [],
        using key: Key,
        issuedAt: Date = Date()
    ) throws -> TraceAttestationDocument {
        let trace = try AttestableTrace(run: run, edges: edges)
        let attestation = try TraceAttestor.attest(
            trace: trace,
            using: key,
            issuedAt: issuedAt
        )
        return TraceAttestationDocument(trace: trace, attestation: attestation)
    }

    public func jsonData(prettyPrinted: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        var formatting: JSONEncoder.OutputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if prettyPrinted { formatting.insert(.prettyPrinted) }
        encoder.outputFormatting = formatting
        return try encoder.encode(self)
    }

    public static func decodeJSON(_ data: Data) throws -> TraceAttestationDocument {
        try JSONDecoder().decode(TraceAttestationDocument.self, from: data)
    }

    public func verify(
        trustedKeyIDs: Set<String>? = nil
    ) -> TraceAttestationVerification {
        TraceAttestationVerifier.verify(
            attestation,
            for: trace,
            trustedKeyIDs: trustedKeyIDs
        )
    }
}

/// A signing-key abstraction shared by software and Secure Enclave-backed P-256 keys.
public protocol TraceAttestationSigningKey: Sendable {
    var publicKeyX963Representation: Data { get }
    func signatureDER(for data: Data) throws -> Data
}

/// A software P-256 key. Persist `rawRepresentation` in Keychain or another protected store;
/// never place it in a trace or attestation document.
public struct SoftwareTraceAttestationKey: TraceAttestationSigningKey, Sendable {
    private let signer: P256.Signing.PrivateKey

    public init(compactRepresentable: Bool = true) {
        self.signer = P256.Signing.PrivateKey(compactRepresentable: compactRepresentable)
    }

    public init(rawRepresentation: Data) throws {
        self.signer = try P256.Signing.PrivateKey(rawRepresentation: rawRepresentation)
    }

    public var rawRepresentation: Data { signer.rawRepresentation }
    public var publicKeyX963Representation: Data { signer.publicKey.x963Representation }

    public func signatureDER(for data: Data) throws -> Data {
        try signer.signature(for: data).derRepresentation
    }
}

/// A non-exportable Secure Enclave P-256 signing key. `dataRepresentation` is the protected
/// key reference used to reopen the same key; it is not the private scalar.
public struct SecureEnclaveTraceAttestationKey: TraceAttestationSigningKey, Sendable {
    private let signer: SecureEnclave.P256.Signing.PrivateKey

    public static var isAvailable: Bool { SecureEnclave.isAvailable }

    public init(compactRepresentable: Bool = true) throws {
        self.signer = try SecureEnclave.P256.Signing.PrivateKey(
            compactRepresentable: compactRepresentable
        )
    }

    public init(dataRepresentation: Data) throws {
        self.signer = try SecureEnclave.P256.Signing.PrivateKey(
            dataRepresentation: dataRepresentation
        )
    }

    public var dataRepresentation: Data { signer.dataRepresentation }
    public var publicKeyX963Representation: Data { signer.publicKey.x963Representation }

    public func signatureDER(for data: Data) throws -> Data {
        try signer.signature(for: data).derRepresentation
    }
}

public enum TraceAttestor {
    public static func attest<T: TraceableEvent, Key: TraceAttestationSigningKey>(
        run: TraceRun<T>,
        edges: [TraceEdge] = [],
        using key: Key,
        issuedAt: Date = Date()
    ) throws -> TraceAttestation {
        try attest(
            trace: AttestableTrace(run: run, edges: edges),
            using: key,
            issuedAt: issuedAt
        )
    }

    public static func attest<Key: TraceAttestationSigningKey>(
        trace: AttestableTrace,
        using key: Key,
        issuedAt: Date = Date()
    ) throws -> TraceAttestation {
        try TraceAttestationValidator.validateForSigning(trace)
        let publicKey = key.publicKeyX963Representation
        let keyID = TraceAttestationCanonicalizer.hex(SHA256.hash(data: publicKey))
        let digest = TraceAttestationCanonicalizer.digest(trace)
        let issuedAtMicros = Int64(issuedAt.timeIntervalSince1970 * 1_000_000)

        let unsigned = TraceAttestation(
            runID: trace.runID,
            contextID: trace.contextID,
            eventCount: trace.events.count,
            edgeCount: trace.edges.count,
            traceDigest: TraceAttestationCanonicalizer.hex(digest),
            issuedAtUnixMicroseconds: issuedAtMicros,
            keyID: keyID,
            publicKeyBase64: publicKey.base64EncodedString(),
            signatureBase64: ""
        )
        let signature = try key.signatureDER(
            for: TraceAttestationCanonicalizer.signingPayload(unsigned)
        )

        return TraceAttestation(
            version: unsigned.version,
            algorithm: unsigned.algorithm,
            canonicalization: unsigned.canonicalization,
            runID: unsigned.runID,
            contextID: unsigned.contextID,
            eventCount: unsigned.eventCount,
            edgeCount: unsigned.edgeCount,
            traceDigest: unsigned.traceDigest,
            issuedAtUnixMicroseconds: unsigned.issuedAtUnixMicroseconds,
            keyID: unsigned.keyID,
            publicKeyBase64: unsigned.publicKeyBase64,
            signatureBase64: signature.base64EncodedString()
        )
    }
}

public enum TraceAttestationTrust: String, Sendable, Equatable {
    /// The signature is valid, but signer identity has not been pinned independently.
    case embeddedKeyOnly
    /// The caller supplied a trust set containing the attestation's key identifier.
    case trustedKey
}

public enum TraceAttestationVerificationFailure: String, Sendable, Equatable {
    case unsupportedVersion
    case unsupportedAlgorithm
    case unsupportedCanonicalization
    case runIDMismatch
    case contextIDMismatch
    case eventRunIDMismatch
    case eventContextIDMismatch
    case duplicateEventID
    case nonMonotonicSequence
    case invalidPayloadJSON
    case eventCountMismatch
    case edgeCountMismatch
    case selfReferentialEdge
    case duplicateEdge
    case danglingEdge
    case malformedDigest
    case digestMismatch
    case malformedPublicKey
    case keyIDMismatch
    case untrustedKey
    case malformedSignature
    case invalidSignature
}

public struct TraceAttestationVerification: Sendable, Equatable {
    public let isValid: Bool
    public let keyID: String
    public let trust: TraceAttestationTrust
    public let failure: TraceAttestationVerificationFailure?

    public init(
        isValid: Bool,
        keyID: String,
        trust: TraceAttestationTrust,
        failure: TraceAttestationVerificationFailure?
    ) {
        self.isValid = isValid
        self.keyID = keyID
        self.trust = trust
        self.failure = failure
    }
}

public enum TraceAttestationVerifier {
    public static func verify<T: TraceableEvent>(
        _ attestation: TraceAttestation,
        for run: TraceRun<T>,
        edges: [TraceEdge] = [],
        trustedKeyIDs: Set<String>? = nil
    ) throws -> TraceAttestationVerification {
        try verify(
            attestation,
            for: AttestableTrace(run: run, edges: edges),
            trustedKeyIDs: trustedKeyIDs
        )
    }

    public static func verify(
        _ attestation: TraceAttestation,
        for trace: AttestableTrace,
        trustedKeyIDs: Set<String>? = nil
    ) -> TraceAttestationVerification {
        var trust: TraceAttestationTrust = .embeddedKeyOnly
        func failure(_ reason: TraceAttestationVerificationFailure) -> TraceAttestationVerification {
            TraceAttestationVerification(
                isValid: false,
                keyID: attestation.keyID,
                trust: trust,
                failure: reason
            )
        }

        guard attestation.version == TraceAttestation.schemaVersion else {
            return failure(.unsupportedVersion)
        }
        guard attestation.algorithm == .p256SHA256 else {
            return failure(.unsupportedAlgorithm)
        }
        guard attestation.canonicalization == .dpkBinaryV1 else {
            return failure(.unsupportedCanonicalization)
        }
        guard attestation.runID == trace.runID else { return failure(.runIDMismatch) }
        guard attestation.contextID == trace.contextID else { return failure(.contextIDMismatch) }
        if let structuralFailure = TraceAttestationValidator.verificationFailure(trace) {
            return failure(structuralFailure)
        }
        guard attestation.eventCount == trace.events.count else { return failure(.eventCountMismatch) }
        guard attestation.edgeCount == trace.edges.count else { return failure(.edgeCountMismatch) }

        guard let expectedDigest = Data(hex: attestation.traceDigest), expectedDigest.count == 32 else {
            return failure(.malformedDigest)
        }
        let actualDigest = Data(TraceAttestationCanonicalizer.digest(trace))
        guard actualDigest == expectedDigest else { return failure(.digestMismatch) }

        guard let publicKeyData = Data(base64Encoded: attestation.publicKeyBase64),
              let publicKey = try? P256.Signing.PublicKey(x963Representation: publicKeyData) else {
            return failure(.malformedPublicKey)
        }
        let actualKeyID = TraceAttestationCanonicalizer.hex(SHA256.hash(data: publicKeyData))
        guard actualKeyID == attestation.keyID else { return failure(.keyIDMismatch) }
        if let trustedKeyIDs, !trustedKeyIDs.contains(attestation.keyID) {
            return failure(.untrustedKey)
        } else if trustedKeyIDs != nil {
            trust = .trustedKey
        }

        guard let signatureData = Data(base64Encoded: attestation.signatureBase64),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: signatureData) else {
            return failure(.malformedSignature)
        }
        guard publicKey.isValidSignature(
            signature,
            for: TraceAttestationCanonicalizer.signingPayload(attestation)
        ) else {
            return failure(.invalidSignature)
        }

        return TraceAttestationVerification(
            isValid: true,
            keyID: attestation.keyID,
            trust: trust,
            failure: nil
        )
    }
}

public enum TraceAttestationError: Error, Equatable {
    case payloadIsNotUTF8
    case eventRunIDMismatch(UUID)
    case eventContextIDMismatch(UUID)
    case duplicateEventID(UUID)
    case nonMonotonicSequence(previous: UInt64, current: UInt64)
    case invalidPayloadJSON(UUID)
    /// An edge whose source and target are the same event: never meaningful lineage.
    case selfReferentialEdge(TraceEdge)
    /// The same (source, target, type) edge appears more than once.
    case duplicateEdge(TraceEdge)
    /// An edge with no connection — direct or through other edges — to any event in
    /// the attested run. Cross-run lineage chains are legitimate (upstream edges may
    /// reference events archived in other runs), but every edge must anchor to this
    /// run's events through the edge set; an unanchored edge is a construction error.
    case danglingEdge(TraceEdge)
    /// The run carries events that could not be decoded as its payload type
    /// (`TraceRun.undecodedEventCount > 0`), so `run.events` is a subset of what was
    /// recorded. An attestation over a subset would present it as the whole run.
    case undecodedEvents(count: Int)
}

private enum TraceAttestationValidator {
    static func validateForSigning(_ trace: AttestableTrace) throws {
        var eventIDs = Set<UUID>()
        var previousSequence: UInt64?
        for event in trace.events {
            guard event.runID == trace.runID else {
                throw TraceAttestationError.eventRunIDMismatch(event.id)
            }
            guard event.contextID == trace.contextID else {
                throw TraceAttestationError.eventContextIDMismatch(event.id)
            }
            guard eventIDs.insert(event.id).inserted else {
                throw TraceAttestationError.duplicateEventID(event.id)
            }
            if let previousSequence, event.sequence <= previousSequence {
                throw TraceAttestationError.nonMonotonicSequence(
                    previous: previousSequence,
                    current: event.sequence
                )
            }
            previousSequence = event.sequence
            guard let payload = event.payloadJSON.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: payload, options: .fragmentsAllowed)) != nil else {
                throw TraceAttestationError.invalidPayloadJSON(event.id)
            }
        }
        try validateEdges(trace.edges, eventIDs: eventIDs)
    }

    /// Structural checks on the lineage edge set. Events are validated individually
    /// above; without this, an attestation would happily sign self-loops, repeated
    /// edges, and edges unrelated to the run — all of which a verifier would then
    /// certify as covered evidence.
    private static func validateEdges(_ edges: [TraceEdge], eventIDs: Set<UUID>) throws {
        var seenEdges = Set<TraceEdge>()
        for edge in edges {
            guard edge.sourceID != edge.targetID else {
                throw TraceAttestationError.selfReferentialEdge(edge)
            }
            guard seenEdges.insert(edge).inserted else {
                throw TraceAttestationError.duplicateEdge(edge)
            }
        }

        // Every edge must be connected to the attested run. Both endpoints living in
        // OTHER runs is fine mid-chain (transitive upstream lineage), so anchoring is
        // computed as a fixpoint over the edge graph, not per-edge containment.
        var anchored = eventIDs
        var remaining = edges
        var grew = true
        while grew {
            grew = false
            remaining.removeAll { edge in
                guard anchored.contains(edge.sourceID) || anchored.contains(edge.targetID) else {
                    return false
                }
                anchored.insert(edge.sourceID)
                anchored.insert(edge.targetID)
                grew = true
                return true
            }
        }
        if let dangling = remaining.first {
            throw TraceAttestationError.danglingEdge(dangling)
        }
    }

    static func verificationFailure(
        _ trace: AttestableTrace
    ) -> TraceAttestationVerificationFailure? {
        do {
            try validateForSigning(trace)
            return nil
        } catch TraceAttestationError.eventRunIDMismatch {
            return .eventRunIDMismatch
        } catch TraceAttestationError.eventContextIDMismatch {
            return .eventContextIDMismatch
        } catch TraceAttestationError.duplicateEventID {
            return .duplicateEventID
        } catch TraceAttestationError.nonMonotonicSequence {
            return .nonMonotonicSequence
        } catch TraceAttestationError.invalidPayloadJSON {
            return .invalidPayloadJSON
        } catch TraceAttestationError.selfReferentialEdge {
            return .selfReferentialEdge
        } catch TraceAttestationError.duplicateEdge {
            return .duplicateEdge
        } catch TraceAttestationError.danglingEdge {
            return .danglingEdge
        } catch {
            return .invalidPayloadJSON
        }
    }
}

enum TraceAttestationCanonicalizer {
    private static let traceDomain = "DPROVENANCEKIT-TRACE-ATTESTATION-V1"
    private static let signatureDomain = "DPROVENANCEKIT-ATTESTATION-SIGNATURE-V1"

    static func digest(_ trace: AttestableTrace) -> SHA256.Digest {
        SHA256.hash(data: canonicalData(trace))
    }

    static func canonicalData(_ trace: AttestableTrace) -> Data {
        var writer = CanonicalBinaryWriter()
        writer.append(traceDomain)
        writer.append(Int64(AttestableTrace.schemaVersion))
        writer.append(trace.runID)
        writer.append(trace.contextID)
        writer.append(UInt64(trace.events.count))

        for (index, event) in trace.events.enumerated() {
            writer.append(UInt64(index))
            writer.append(event.id)
            writer.append(event.runID)
            writer.append(event.contextID)
            writer.append(event.engineName)
            writer.append(Int64(event.schemaVersion))
            writer.append(event.sequence)
            writer.append(event.spanID)
            writer.append(event.parentSpanID)
            writer.append(event.typeIdentifier)
            writer.append(Int64(event.priority))
            writer.append(event.payloadJSON)
            writer.append(event.timestampUnixMicroseconds)
        }

        let sortedEdges = trace.edges.sorted {
            let lhs = ($0.sourceID.uuidString, $0.targetID.uuidString, $0.type.rawValue)
            let rhs = ($1.sourceID.uuidString, $1.targetID.uuidString, $1.type.rawValue)
            return lhs < rhs
        }
        writer.append(UInt64(sortedEdges.count))
        for edge in sortedEdges {
            writer.append(edge.sourceID)
            writer.append(edge.targetID)
            writer.append(edge.type.rawValue)
        }
        return writer.data
    }

    static func signingPayload(_ attestation: TraceAttestation) -> Data {
        var writer = CanonicalBinaryWriter()
        writer.append(signatureDomain)
        writer.append(Int64(attestation.version))
        writer.append(attestation.algorithm.rawValue)
        writer.append(attestation.canonicalization.rawValue)
        writer.append(attestation.runID)
        writer.append(attestation.contextID)
        writer.append(UInt64(attestation.eventCount))
        writer.append(UInt64(attestation.edgeCount))
        writer.append(attestation.traceDigest)
        writer.append(attestation.issuedAtUnixMicroseconds)
        writer.append(attestation.keyID)
        writer.append(attestation.publicKeyBase64)
        return writer.data
    }

    static func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

private struct CanonicalBinaryWriter {
    private(set) var data = Data()

    mutating func append(_ value: UInt64) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    mutating func append(_ value: Int64) {
        append(UInt64(bitPattern: value))
    }

    mutating func append(_ value: UUID) {
        var uuid = value.uuid
        withUnsafeBytes(of: &uuid) { data.append(contentsOf: $0) }
    }

    mutating func append(_ value: String) {
        append(Data(value.utf8))
    }

    mutating func append(_ value: String?) {
        guard let value else {
            data.append(0)
            return
        }
        data.append(1)
        append(value)
    }

    mutating func append(_ value: Data) {
        append(UInt64(value.count))
        data.append(value)
    }
}

private extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = bytes
    }
}
