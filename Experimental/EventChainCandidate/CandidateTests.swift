import Foundation

struct FixtureFile: Decodable {
    let positiveCases: [FixtureCase]
    let unsignedClosureCases: [ClosureFixture]
}

struct FixtureCase: Decodable {
    let name: String
    let runID: String
    let genesisPreimageHex: String
    let genesisHash: String
    let entries: [FixtureEntry]
    let head: String
    let entryCount: UInt64
}

struct FixtureEntry: Decodable {
    let chainIndex: UInt64
    let event: ChainEvent
    let previousHash: String
    let preimageHex: String
    let entryHash: String
}

struct ClosureFixture: Decodable {
    let name: String
    let runID: String
    let chainVersion: Int64
    let finalChainIndex: UInt64?
    let finalChainHead: String
    let eventCount: UInt64
    let traceDigest: String
    let keyID: String
    let issuedAtUnixMicroseconds: Int64
    let preimageHex: String
    let preimageSHA256: String

    func commitment() throws -> RunClose {
        try RunClose(runID: runID, chainVersion: chainVersion,
                     finalChainIndex: finalChainIndex, finalChainHead: decodeHex(finalChainHead),
                     eventCount: eventCount, traceDigest: decodeHex(traceDigest),
                     keyID: decodeHex(keyID), issuedAtUnixMicroseconds: issuedAtUnixMicroseconds)
    }
}

func decodeHex(_ value: String) throws -> Data {
    let bytes = Array(value.utf8)
    guard bytes.count == 64 else { throw ChainFailure.invalidHash }
    var result = Data()
    for index in stride(from: 0, to: bytes.count, by: 2) {
        guard let byte = UInt8(String(decoding: bytes[index...index + 1], as: UTF8.self), radix: 16),
              bytes[index...index + 1].allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { throw ChainFailure.invalidHash }
        result.append(byte)
    }
    return result
}

enum TestFailure: Error {
    case assertion(String)
}

func check(_ condition: Bool, _ message: String) throws {
    guard condition else { throw TestFailure.assertion(message) }
}

func hex(_ bytes: Data) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

func rejects(_ expected: ChainFailure, _ operation: () throws -> Void) throws {
    do {
        try operation()
    } catch let error as ChainFailure {
        try check(error == expected, "expected \(expected), got \(error)")
        return
    }
    throw TestFailure.assertion("accepted invalid input: \(expected)")
}

@main
struct CandidateTests {
    static func main() throws {
        try check(CommandLine.arguments.count == 2, "pass fixture path")
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let fixtures = try JSONDecoder().decode(FixtureFile.self, from: Data(contentsOf: url))
        try check(fixtures.positiveCases.count == 6, "fixture count")
        var checkedEntries = 0
        for fixture in fixtures.positiveCases {
            var writer = try ChainBuilder(runID: fixture.runID)
            try check(hex(try ChainCodec.genesisPreimage(fixture.runID)) == fixture.genesisPreimageHex, fixture.name)
            try check(hex(writer.head) == fixture.genesisHash, fixture.name)
            for expected in fixture.entries {
                let entry = try writer.append(expected.event)
                try check(entry.chainIndex == expected.chainIndex, fixture.name)
                try check(hex(entry.previousHash) == expected.previousHash, fixture.name)
                let preimage = try ChainCodec.entryPreimage(entry.chainIndex, entry.previousHash, entry.event)
                try check(hex(preimage) == expected.preimageHex, fixture.name)
                try check(hex(entry.entryHash) == expected.entryHash, fixture.name)
                checkedEntries += 1
            }
            let chain = writer.snapshot()
            try check(hex(chain.head) == fixture.head, fixture.name)
            try check(UInt64(chain.entries.count) == fixture.entryCount, fixture.name)
            try ChainCodec.verify(chain, expectedRunID: fixture.runID, expectedCount: fixture.entryCount)
            let resumed = try ChainBuilder(chain: chain, expectedRunID: fixture.runID, expectedHead: chain.head)
            try check(resumed.head == chain.head, fixture.name)
        }
        guard let fixture = fixtures.positiveCases.first(where: { $0.entries.count >= 2 }) else {
            throw TestFailure.assertion("missing multievent fixture")
        }
        var writer = try ChainBuilder(runID: fixture.runID)
        let empty = writer.snapshot()
        try rejects(.empty) { try ChainCodec.verify(empty, expectedRunID: fixture.runID, requireEvidence: true) }
        for item in fixture.entries { try writer.append(item.event) }
        let chain = writer.snapshot()
        let first = fixture.entries[0].event
        try rejects(.duplicateEvent) { try writer.append(first) }
        var invalid = first
        invalid.eventID = "ffffffff-ffff-4fff-8fff-ffffffffffff"
        try rejects(.nonmonotonic) { try writer.append(invalid) }
        invalid.runID = "ffffffff-ffff-4fff-8fff-ffffffffffff"
        try rejects(.runMismatch) { try writer.append(invalid) }
        try check(writer.snapshot().head == chain.head, "rejected append mutated head")
        try check(writer.snapshot().entries.count == chain.entries.count, "rejected append mutated count")
        var changed = chain
        changed.entries[0].event.payloadJSON = "{}"
        if chain.entries[0].event.payloadJSON == "{}" { changed.entries[0].event.payloadJSON = "{\"changed\":1}" }
        try rejects(.entryMismatch) { try ChainCodec.verify(changed, expectedRunID: fixture.runID) }
        changed = chain
        changed.entries.swapAt(0, 1)
        try rejects(.indexMismatch) { try ChainCodec.verify(changed, expectedRunID: fixture.runID) }
        changed = chain
        changed.entries[0].previousHash = Data(repeating: 0, count: 32)
        try rejects(.previousMismatch) { try ChainCodec.verify(changed, expectedRunID: fixture.runID) }
        changed = chain
        changed.head = Data(repeating: 0, count: 32)
        try rejects(.headMismatch) { try ChainCodec.verify(changed, expectedRunID: fixture.runID) }
        changed = chain
        changed.version = 2
        try rejects(.unsupportedVersion) { try ChainCodec.verify(changed, expectedRunID: fixture.runID) }
        changed = chain
        changed.entries.removeLast()
        guard let last = changed.entries.last else { throw TestFailure.assertion("missing entry") }
        changed.head = last.entryHash
        try rejects(.closureMismatch) {
            try ChainCodec.verify(changed, expectedRunID: fixture.runID, expectedHead: chain.head)
        }
        try rejects(.invalidIdentifier) { _ = try ChainCodec.genesis("invalid") }
        try rejects(.identifierTooLong) { _ = try ChainCodec.genesis(String(repeating: "a", count: 129)) }
        try rejects(.invalidHash) { _ = try ChainCodec.entryPreimage(0, Data(), first) }
        for bad in ["[]", "{\"a\":1,\"a\":2}", "{\"a\":NaN}", "{\"a\":01}", "{\"a\":1,}",
                    "{\"a\":1,\"\\u0061\":2}", "{\"😀\":1,\"\\uD83D\\uDE00\":2}", "{\"a\":1}x"] {
            var scanner = PayloadScanner(bad)
            try rejects(.invalidPayload) { try scanner.validate() }
        }
        for good in ["{}", "{\"é\":1,\"e\\u0301\":2}", "{\"x\":[true,null,-1.2e+5]}",
                     "{\"x\":1e999999}", "{\"\\uD800\":0}"] {
            var scanner = PayloadScanner(good)
            try scanner.validate()
        }
        for extra in [256, 257] {
            let payload = "{\"x\":" + String(repeating: "[", count: extra) + "0" +
                String(repeating: "]", count: extra) + "}"
            var scanner = PayloadScanner(payload)
            if extra == 256 { try scanner.validate() }
            else { try rejects(.invalidPayload) { try scanner.validate() } }
        }
        for extra in [0, 1] {
            let payload = "{\"x\":\"" + String(repeating: "é", count: (1_048_576 - 8) / 2) +
                String(repeating: "a", count: extra) + "\"}"
            try check(payload.utf8.count == 1_048_576 + extra, "payload boundary")
            var scanner = PayloadScanner(payload)
            if extra == 0 { try scanner.validate() }
            else { try rejects(.invalidPayload) { try scanner.validate() } }
        }
        try check(fixtures.unsignedClosureCases.count == 2, "closure fixture count")
        for item in fixtures.unsignedClosureCases {
            let close = try item.commitment()
            let raw = try ChainCodec.closePreimage(close)
            try check(hex(raw) == item.preimageHex, "closure preimage")
            try check(hex(ChainCodec.digest(raw)) == item.preimageSHA256, "closure digest")
            guard let source = fixtures.positiveCases.first(where: { $0.name == item.name }) else {
                throw TestFailure.assertion("missing closure chain")
            }
            var builder = try ChainBuilder(runID: item.runID)
            for entry in source.entries { try builder.append(entry.event) }
            try ChainCodec.verifyCloseBinding(builder.snapshot(), close, expectedRunID: item.runID)
            var bad = close
            bad.finalChainIndex = close.eventCount
            let wrongIndex = bad
            try rejects(.closureMismatch) { _ = try ChainCodec.closePreimage(wrongIndex) }
            bad = close
            bad.keyID = Data()
            let wrongKey = bad
            try rejects(.invalidHash) { _ = try ChainCodec.closePreimage(wrongKey) }
            if !source.entries.isEmpty {
                var shortened = try ChainBuilder(runID: item.runID)
                for entry in source.entries.dropLast() { try shortened.append(entry.event) }
                try rejects(.closureMismatch) {
                    try ChainCodec.verifyCloseBinding(shortened.snapshot(), close, expectedRunID: item.runID)
                }
                var replacement = try ChainBuilder(runID: item.runID)
                for (index, entry) in source.entries.enumerated() {
                    var event = entry.event
                    if index == 0 { event.payloadJSON = event.payloadJSON == "{}" ? "{\"changed\":1}" : "{}" }
                    try replacement.append(event)
                }
                try rejects(.closureMismatch) {
                    try ChainCodec.verifyCloseBinding(replacement.snapshot(), close, expectedRunID: item.runID)
                }
            }
        }
        try testAuthentication(url.deletingLastPathComponent())
        print("PASS: 2 unsigned closure preimages and binding checks; payload boundaries")
        print("PASS: \(fixtures.positiveCases.count) shared chains, \(checkedEntries) exact entry preimages, adversarial checks")
    }
}
