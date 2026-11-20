import CryptoKit
import Foundation

// Review-only implementation. No public SDK, persistence or signing integration.
enum ChainFailure: String, Error {
    case identifierTooLong = "IDENTIFIER_TOO_LONG"
    case invalidIdentifier = "INVALID_IDENTIFIER"
    case invalidHash = "INVALID_HASH"
    case invalidPayload = "INVALID_PAYLOAD_JSON"
    case runMismatch = "RUN_ID_MISMATCH"
    case duplicateEvent = "DUPLICATE_EVENT_ID"
    case nonmonotonic = "SEQUENCE_NONMONOTONIC"
    case unsupportedVersion = "UNSUPPORTED_VERSION"
    case indexMismatch = "CHAIN_INDEX_MISMATCH"
    case previousMismatch = "PREVIOUS_HASH_MISMATCH"
    case entryMismatch = "ENTRY_HASH_MISMATCH"
    case headMismatch = "HEAD_MISMATCH"
    case closureMismatch = "CLOSURE_MISMATCH"
    case empty = "EMPTY_CHAIN"
}

struct ChainEvent: Codable, Sendable {
    var eventID: String
    var runID: String
    var contextID: String
    var engineName: String
    var schemaVersion: Int64
    var eventSequence: UInt64
    var spanID: String?
    var parentSpanID: String?
    var typeIdentifier: String
    var priority: Int64
    var payloadJSON: String
    var timestampUnixMicroseconds: Int64
}

struct ChainEntry: Sendable {
    var chainIndex: UInt64
    var event: ChainEvent
    var previousHash: Data
    var entryHash: Data
}

struct EventChain: Sendable {
    var runID: String
    var head: Data
    var entries: [ChainEntry]
    var version: Int64 = 1
}

enum ChainCodec {
    static let genesisDomain = Data("DPROVENANCEKIT-EVENT-CHAIN-GENESIS-V1".utf8)
    static let entryDomain = Data("DPROVENANCEKIT-EVENT-CHAIN-ENTRY-V1".utf8)

    static func uuid(_ input: String) throws -> UUID {
        let bytes = Array(input.utf8)
        guard bytes.count <= 128 else { throw ChainFailure.identifierTooLong }
        guard bytes.count == 36 else { throw ChainFailure.invalidIdentifier }
        for (index, byte) in bytes.enumerated() {
            if [8, 13, 18, 23].contains(index) {
                guard byte == 45 else { throw ChainFailure.invalidIdentifier }
            } else {
                guard (48...57).contains(byte) || (65...70).contains(byte) ||
                        (97...102).contains(byte) else { throw ChainFailure.invalidIdentifier }
            }
        }
        guard let value = UUID(uuidString: input) else { throw ChainFailure.invalidIdentifier }
        return value
    }

    static func uuidBytes(_ input: String) throws -> Data {
        var tuple = try uuid(input).uuid
        return withUnsafeBytes(of: &tuple) { Data($0) }
    }

    static func u64(_ value: UInt64) -> Data {
        var big = value.bigEndian
        return withUnsafeBytes(of: &big) { Data($0) }
    }

    static func i64(_ value: Int64) -> Data {
        u64(UInt64(bitPattern: value))
    }

    static func string(_ value: String) -> Data {
        let bytes = Data(value.utf8)
        return u64(UInt64(bytes.count)) + bytes
    }

    static func optional(_ value: String?) -> Data {
        guard let value else { return Data([0]) }
        return Data([1]) + string(value)
    }

    static func hash(_ value: Data) throws -> Data {
        guard value.count == 32 else { throw ChainFailure.invalidHash }
        return value
    }

    static func digest(_ value: Data) -> Data {
        Data(SHA256.hash(data: value))
    }

    static func genesisPreimage(_ runID: String) throws -> Data {
        try genesisDomain + uuidBytes(runID)
    }

    static func genesis(_ runID: String) throws -> Data {
        try digest(genesisPreimage(runID))
    }

    static func eventBytes(_ event: ChainEvent) throws -> Data {
        var parser = PayloadScanner(event.payloadJSON)
        try parser.validate()
        var result = try uuidBytes(event.eventID)
        result += try uuidBytes(event.runID)
        result += string(event.contextID)
        result += string(event.engineName)
        result += i64(event.schemaVersion)
        result += u64(event.eventSequence)
        result += optional(event.spanID)
        result += optional(event.parentSpanID)
        result += string(event.typeIdentifier)
        result += i64(event.priority)
        result += string(event.payloadJSON)
        result += i64(event.timestampUnixMicroseconds)
        return result
    }

    static func entryPreimage(_ index: UInt64, _ previous: Data, _ event: ChainEvent) throws -> Data {
        var result = entryDomain + i64(1) + u64(index)
        result += try hash(previous)
        result += try eventBytes(event)
        return result
    }

    static func validateEvent(
        _ event: ChainEvent, expected: UUID, seen: Set<UUID>, last: UInt64?
    ) throws -> UUID {
        let identity = try uuid(event.eventID)
        guard try uuid(event.runID) == expected else { throw ChainFailure.runMismatch }
        guard !seen.contains(identity) else { throw ChainFailure.duplicateEvent }
        if let last, event.eventSequence <= last { throw ChainFailure.nonmonotonic }
        return identity
    }

    static func verify(
        _ chain: EventChain, expectedRunID: String, expectedCount: UInt64? = nil,
        expectedHead: Data? = nil, requireEvidence: Bool = false
    ) throws {
        guard chain.version == 1 else { throw ChainFailure.unsupportedVersion }
        let expected = try uuid(expectedRunID)
        guard try uuid(chain.runID) == expected else { throw ChainFailure.runMismatch }
        var previous = try genesis(expectedRunID)
        var seen = Set<UUID>()
        var last: UInt64?
        for (index, entry) in chain.entries.enumerated() {
            guard entry.chainIndex == UInt64(index) else { throw ChainFailure.indexMismatch }
            let identity = try validateEvent(entry.event, expected: expected, seen: seen, last: last)
            guard try hash(entry.previousHash) == previous else { throw ChainFailure.previousMismatch }
            let computed = try digest(entryPreimage(UInt64(index), previous, entry.event))
            guard try hash(entry.entryHash) == computed else { throw ChainFailure.entryMismatch }
            previous = computed
            seen.insert(identity)
            last = entry.event.eventSequence
        }
        guard try hash(chain.head) == previous else { throw ChainFailure.headMismatch }
        if let expectedCount, expectedCount != UInt64(chain.entries.count) {
            throw ChainFailure.closureMismatch
        }
        if let expectedHead, try hash(expectedHead) != previous { throw ChainFailure.closureMismatch }
        if requireEvidence && chain.entries.isEmpty { throw ChainFailure.empty }
    }
}

// Value-type, single-owner incremental writer. No concurrency or storage guarantee.
struct ChainBuilder {
    private let runID: String
    private let expected: UUID
    private var entries: [ChainEntry] = []
    private var seen: Set<UUID> = []
    private var last: UInt64?
    private(set) var head: Data

    init(runID: String) throws {
        self.runID = runID
        expected = try ChainCodec.uuid(runID)
        head = try ChainCodec.genesis(runID)
    }

    init(chain: EventChain, expectedRunID: String, expectedHead: Data? = nil) throws {
        try ChainCodec.verify(chain, expectedRunID: expectedRunID, expectedHead: expectedHead)
        try self.init(runID: chain.runID)
        entries = chain.entries
        seen = try Set(entries.map { try ChainCodec.uuid($0.event.eventID) })
        last = entries.last?.event.eventSequence
        head = chain.head
    }

    @discardableResult
    mutating func append(_ event: ChainEvent) throws -> ChainEntry {
        let identity = try ChainCodec.validateEvent(event, expected: expected, seen: seen, last: last)
        let index = UInt64(entries.count)
        let digest = try ChainCodec.digest(ChainCodec.entryPreimage(index, head, event))
        let entry = ChainEntry(chainIndex: index, event: event, previousHash: head, entryHash: digest)
        entries.append(entry)
        seen.insert(identity)
        last = event.eventSequence
        head = digest
        return entry
    }

    func snapshot() -> EventChain {
        EventChain(runID: runID, head: head, entries: entries)
    }
}


// Unsigned closure only: no signature, trust, full trace binding or completeness claim.
struct RunClose: Sendable {
    var runID: String
    var chainVersion: Int64
    var finalChainIndex: UInt64?
    var finalChainHead: Data
    var eventCount: UInt64
    var traceDigest: Data
    var keyID: Data
    var issuedAtUnixMicroseconds: Int64
}

extension ChainCodec {
    static func closePreimage(_ close: RunClose) throws -> Data {
        guard close.chainVersion == 1 else { throw ChainFailure.unsupportedVersion }
        var result = Data("DPROVENANCEKIT-RUN-CLOSE-V1".utf8)
        result += try uuidBytes(close.runID)
        result += i64(1)
        let head = try hash(close.finalChainHead)
        if close.eventCount == 0 {
            guard close.finalChainIndex == nil, try genesis(close.runID) == head else {
                throw ChainFailure.closureMismatch
            }
        } else {
            guard close.finalChainIndex == close.eventCount - 1 else {
                throw ChainFailure.closureMismatch
            }
        }
        if let index = close.finalChainIndex {
            result += Data([1]) + u64(index)
        } else {
            result += Data([0])
        }
        result += head + u64(close.eventCount)
        result += try hash(close.traceDigest)
        result += try hash(close.keyID)
        result += i64(close.issuedAtUnixMicroseconds)
        return result
    }

    // This checks an unsigned chain binding; it is not an authentication API.
    static func verifyCloseBinding(
        _ chain: EventChain, _ close: RunClose, expectedRunID: String
    ) throws {
        _ = try closePreimage(close)
        guard try uuid(close.runID) == uuid(expectedRunID) else {
            throw ChainFailure.runMismatch
        }
        try verify(chain, expectedRunID: expectedRunID, expectedCount: close.eventCount,
                   expectedHead: close.finalChainHead)
    }
}
