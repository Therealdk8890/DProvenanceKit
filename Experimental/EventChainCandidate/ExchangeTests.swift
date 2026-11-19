import CryptoKit
import Foundation

// Review fixture transport only; not a production wire decoder or trust store.
private struct ExchangeEntry: Codable {
    let chainIndex: UInt64
    let event: ChainEvent
    let previousHash: Data
    let entryHash: Data

    init(_ entry: ChainEntry) {
        chainIndex = entry.chainIndex
        event = entry.event
        previousHash = entry.previousHash
        entryHash = entry.entryHash
    }

    var value: ChainEntry {
        ChainEntry(chainIndex: chainIndex, event: event, previousHash: previousHash, entryHash: entryHash)
    }
}

private struct ExchangeChain: Codable {
    let runID: String
    let version: Int64
    let head: Data
    let entries: [ExchangeEntry]

    init(_ chain: EventChain) {
        runID = chain.runID
        version = chain.version
        head = chain.head
        entries = chain.entries.map(ExchangeEntry.init)
    }

    var value: EventChain {
        EventChain(runID: runID, head: head, entries: entries.map { $0.value }, version: version)
    }
}

private struct ExchangeEdge: Codable {
    let sourceID: String
    let targetID: String
    let type: String

    init(_ edge: TraceEdge) {
        sourceID = edge.sourceID
        targetID = edge.targetID
        type = edge.type
    }

    var value: TraceEdge {
        TraceEdge(sourceID: sourceID, targetID: targetID, type: type)
    }
}

private struct ExchangeTrace: Codable {
    let runID: String
    let contextID: String
    let events: [ChainEvent]
    let edges: [ExchangeEdge]

    init(_ trace: CoveredTrace) {
        runID = trace.runID
        contextID = trace.contextID
        events = trace.events
        edges = trace.edges.map(ExchangeEdge.init)
    }

    var value: CoveredTrace {
        CoveredTrace(runID: runID, contextID: contextID, events: events, edges: edges.map { $0.value })
    }
}

private struct ExchangeClose: Codable {
    let runID: String
    let chainVersion: Int64
    let finalChainIndex: UInt64?
    let finalChainHead: Data
    let eventCount: UInt64
    let traceDigest: Data
    let keyID: Data
    let issuedAtUnixMicroseconds: Int64

    init(_ close: RunClose) {
        runID = close.runID
        chainVersion = close.chainVersion
        finalChainIndex = close.finalChainIndex
        finalChainHead = close.finalChainHead
        eventCount = close.eventCount
        traceDigest = close.traceDigest
        keyID = close.keyID
        issuedAtUnixMicroseconds = close.issuedAtUnixMicroseconds
    }

    var value: RunClose {
        RunClose(runID: runID, chainVersion: chainVersion, finalChainIndex: finalChainIndex,
                 finalChainHead: finalChainHead, eventCount: eventCount, traceDigest: traceDigest,
                 keyID: keyID, issuedAtUnixMicroseconds: issuedAtUnixMicroseconds)
    }
}

private struct ExchangeSigned: Codable {
    let close: ExchangeClose
    let publicKeyX963: Data
    let signatureDER: Data

    init(_ signed: SignedClose) {
        close = ExchangeClose(signed.close)
        publicKeyX963 = signed.publicKeyX963
        signatureDER = signed.signatureDER
    }

    var value: SignedClose {
        SignedClose(close: close.value, publicKeyX963: publicKeyX963, signatureDER: signatureDER)
    }
}

private struct ExchangeArtifact: Codable {
    let format: String
    let chain: ExchangeChain
    let trace: ExchangeTrace
    let signed: ExchangeSigned

    init(chain: EventChain, trace: CoveredTrace, signed: SignedClose) {
        format = "DPK-CANDIDATE-EXCHANGE-TEST-V1"
        self.chain = ExchangeChain(chain)
        self.trace = ExchangeTrace(trace)
        self.signed = ExchangeSigned(signed)
    }
}

private func exchangeReject(_ code: String, _ operation: () throws -> Void) throws {
    do {
        try operation()
    } catch {
        let actual = (error as? AuthenticationFailure)?.rawValue ?? (error as? ChainFailure)?.rawValue
        try check(actual == code, "expected \(code), got \(error)")
        return
    }
    throw TestFailure.assertion("accepted invalid \(code)")
}

private func emitExchange(_ fixtures: URL, _ name: String, _ output: URL) throws {
    let file = try JSONDecoder().decode(FixtureFile.self, from: Data(contentsOf: fixtures))
    guard let item = file.positiveCases.first(where: { $0.name == name }) else {
        throw TestFailure.assertion("unknown fixture case")
    }
    let events = item.entries.map { $0.event }
    var builder = try ChainBuilder(runID: item.runID)
    for event in events { try builder.append(event) }
    let chain = builder.snapshot()
    let edges = events.count >= 3 ? [
        TraceEdge(sourceID: events[1].eventID, targetID: events[2].eventID, type: "informed"),
        TraceEdge(sourceID: events[0].eventID, targetID: events[1].eventID, type: "derivedFrom")
    ] : []
    let trace = CoveredTrace(runID: item.runID, contextID: events.first?.contextID ?? "empty",
                             events: events, edges: edges)
    // Public test scalar 2. Never use as a real evidence-signing key.
    let key = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0, count: 31) + Data([2]))
    let signed = try ClosureAuthentication.sign(
        chain, trace, expectedRunID: item.runID, issuedAt: 123,
        publicKeyX963: key.publicKey.x963Representation
    ) { try key.signature(for: $0).derRepresentation }
    let artifact = ExchangeArtifact(chain: chain, trace: trace, signed: signed)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(artifact).write(to: output, options: .atomic)
}

private func verifyExchange(_ input: URL, _ run: String, _ pin: Data, _ other: Data) throws {
    let data = try Data(contentsOf: input)
    try check(data.count <= 4_194_304, "test artifact too large")
    let artifact = try JSONDecoder().decode(ExchangeArtifact.self, from: data)
    try check(artifact.format == "DPK-CANDIDATE-EXCHANGE-TEST-V1", "wrong test envelope")
    let chain = artifact.chain.value
    let trace = artifact.trace.value
    let signed = artifact.signed.value
    try ClosureAuthentication.verify(chain, trace, signed, expectedRunID: run, trustedKeyID: pin)
    try exchangeReject("UNTRUSTED_KEY") {
        try ClosureAuthentication.verify(chain, trace, signed, expectedRunID: run, trustedKeyID: other)
    }
    var changed = signed
    changed.signatureDER = Data([1, 2, 3])
    try exchangeReject("INVALID_SIGNATURE") {
        try ClosureAuthentication.verify(chain, trace, changed, expectedRunID: run, trustedKeyID: pin)
    }
    changed = signed
    changed.close.issuedAtUnixMicroseconds += 1
    try exchangeReject("INVALID_SIGNATURE") {
        try ClosureAuthentication.verify(chain, trace, changed, expectedRunID: run, trustedKeyID: pin)
    }
    if chain.entries.isEmpty {
        try exchangeReject("EMPTY_CHAIN") {
            try ClosureAuthentication.verify(chain, trace, signed, expectedRunID: run,
                                             trustedKeyID: pin, requireEvidence: true)
        }
    } else {
        let missingEdges = CoveredTrace(runID: trace.runID, contextID: trace.contextID,
                                        events: trace.events, edges: [])
        try exchangeReject("TRACE_MISMATCH") {
            try ClosureAuthentication.verify(chain, missingEdges, signed, expectedRunID: run, trustedKeyID: pin)
        }
        var truncated = try ChainBuilder(runID: run)
        for event in trace.events.dropLast() { try truncated.append(event) }
        try exchangeReject("CLOSURE_MISMATCH") {
            try ClosureAuthentication.verify(truncated.snapshot(), trace, signed, expectedRunID: run,
                                             trustedKeyID: pin)
        }
        var replacement = try ChainBuilder(runID: run)
        for (index, event) in trace.events.enumerated() {
            var altered = event
            if index == 0 { altered.payloadJSON = "{}" }
            try replacement.append(altered)
        }
        try exchangeReject("CLOSURE_MISMATCH") {
            try ClosureAuthentication.verify(replacement.snapshot(), trace, signed, expectedRunID: run,
                                             trustedKeyID: pin)
        }
    }
    print("PASS: Python -> Swift \(chain.entries.isEmpty ? "empty" : "sequence_gap_and_unicode")")
}

func runExchangeCommand(_ arguments: [String]) throws {
    switch arguments.first {
    case "exchange-sign":
        try check(arguments.count == 4, "exchange-sign FIXTURES CASE OUTPUT")
        try emitExchange(URL(fileURLWithPath: arguments[1]), arguments[2],
                         URL(fileURLWithPath: arguments[3]))
    case "exchange-verify":
        try check(arguments.count == 5, "exchange-verify INPUT RUN PIN OTHER_PIN")
        try verifyExchange(URL(fileURLWithPath: arguments[1]), arguments[2],
                           decodeHex(arguments[3]), decodeHex(arguments[4]))
    default:
        throw TestFailure.assertion("unknown exchange command")
    }
}
