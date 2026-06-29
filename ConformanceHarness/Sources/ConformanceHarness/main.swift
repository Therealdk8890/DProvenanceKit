// Trace Specification v1 — Swift conformance harness.
//
// Loads the committed golden vectors (vendored under ../../vectors, the Python oracle's
// output) and checks that the Swift DProvenanceKit SDK reproduces each one, driving the
// real SDK APIs. Prints PASS/FAIL per case; exits non-zero if any vector is not reproduced.
//
//   swift run --package-path ConformanceHarness
//
// The vectors here are a vendored copy of conformance/vectors/*.json from the Python repo
// (the canonical source). Re-copy them when the spec is regenerated.

import Foundation
import CryptoKit
import SQLite3
import DProvenanceKit

// Resolve the vendored vectors relative to this source file (works regardless of cwd).
let VECTORS = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()      // .../Sources/ConformanceHarness
    .deletingLastPathComponent()      // .../Sources
    .deletingLastPathComponent()      // .../ConformanceHarness
    .appendingPathComponent("vectors").path

// MARK: - Heterogeneous attribute value (mirrors the Python ConformanceEvent attributes)

enum AttrValue: Codable, Hashable, Sendable {
    case bool(Bool), int(Int), double(Double), string(String)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        self = .string(try c.decode(String.self))
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        }
    }
    static func from(_ any: Any) -> AttrValue {
        if let n = any as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            if CFNumberIsFloatType(n) { return .double(n.doubleValue) }
            return .int(n.intValue)
        }
        if let s = any as? String { return .string(s) }
        return .string("\(any)")
    }
}

// MARK: - A self-describing conformance event flattening to {type, priority, ...attributes}

struct DynKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
    init(_ s: String) { self.stringValue = s }
}

struct ConformanceEvent: TraceableEvent {
    let typeName: String
    let priorityValue: Int
    let attributes: [String: AttrValue]

    init(typeName: String, priorityValue: Int = 3, attributes: [String: AttrValue] = [:]) {
        self.typeName = typeName
        self.priorityValue = priorityValue
        self.attributes = attributes
    }

    var typeIdentifier: String { typeName }
    var priority: TracePriority { TracePriority(rawValue: priorityValue) ?? .telemetry }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynKey.self)
        try c.encode(typeName, forKey: DynKey("type"))
        try c.encode(priorityValue, forKey: DynKey("priority"))
        for (k, v) in attributes { try c.encode(v, forKey: DynKey(k)) }
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynKey.self)
        var type = ""
        var prio = 3
        var attrs: [String: AttrValue] = [:]
        for key in c.allKeys {
            switch key.stringValue {
            case "type": type = try c.decode(String.self, forKey: key)
            case "priority": prio = try c.decode(Int.self, forKey: key)
            default: attrs[key.stringValue] = try c.decode(AttrValue.self, forKey: key)
            }
        }
        self.typeName = type
        self.priorityValue = prio
        self.attributes = attrs
    }
}

// MARK: - Vector loading + reporting

func loadVector(_ name: String) -> [String: Any] {
    let data = try! Data(contentsOf: URL(fileURLWithPath: VECTORS + "/" + name))
    return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
}

var failures: [String] = []
func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok {
        print("  PASS  \(label)")
    } else {
        let d = detail()
        print("  FAIL  \(label)\(d.isEmpty ? "" : "  — \(d)")")
        failures.append(label)
    }
}

func eventFromSpec(_ spec: [String: Any]) -> ConformanceEvent {
    let type = spec["type"] as! String
    let prio = (spec["priority"] as? NSNumber)?.intValue ?? 3
    var attrs: [String: AttrValue] = [:]
    if let a = spec["attributes"] as? [String: Any] {
        for (k, v) in a { attrs[k] = AttrValue.from(v) }
    }
    return ConformanceEvent(typeName: type, priorityValue: prio, attributes: attrs)
}

// MARK: - 1. Payload encoding (§2)

func matches(of pattern: String, in s: String) -> [String] {
    let re = try! NSRegularExpression(pattern: pattern)
    let ns = s as NSString
    return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map {
        ns.substring(with: $0.range(at: 1))
    }
}

func checkPayloadEncoding() {
    print("\n[1] payload encoding")
    let doc = loadVector("payload_encoding.json")
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    for (i, raw) in (doc["cases"] as! [[String: Any]]).enumerated() {
        let event = eventFromSpec(raw["event"] as! [String: Any])
        let swiftBytes = try! enc.encode(event)
        let swiftStr = String(data: swiftBytes, encoding: .utf8)!
        let pyStr = raw["canonical_json"] as! String

        let swiftObj = try! JSONSerialization.jsonObject(with: swiftBytes) as! NSDictionary
        let pyObj = try! JSONSerialization.jsonObject(with: pyStr.data(using: .utf8)!) as! NSDictionary
        let semantic = swiftObj.isEqual(to: pyObj as! [AnyHashable: Any])
        let keys = matches(of: "\"([^\"]+)\":", in: swiftStr)
        let sorted = keys == keys.sorted()
        let decoded = try! JSONDecoder().decode(ConformanceEvent.self, from: swiftBytes)
        let roundTrips = decoded == event

        check("case \(i): \(event.typeIdentifier)", semantic && sorted && roundTrips,
              "semantic=\(semantic) sorted=\(sorted) roundTrip=\(roundTrips) swift=\(swiftStr)")
    }
}

// MARK: - 2. Run fingerprint (§5) — driven through the real SQLite store

func readFingerprint(_ path: String) -> String? {
    var db: OpaquePointer?
    guard sqlite3_open(path, &db) == SQLITE_OK else { return nil }
    defer { sqlite3_close(db) }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, "SELECT fingerprint FROM runs LIMIT 1", -1, &stmt, nil) == SQLITE_OK else { return nil }
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { return nil }
    return String(cString: c)
}

func checkRunFingerprint() async {
    print("\n[2] run fingerprint")
    let doc = loadVector("run_fingerprint.json")
    for (i, raw) in (doc["cases"] as! [[String: Any]]).enumerated() {
        let events = raw["events"] as! [[String: Any]]
        let expected = raw["fingerprint"] as! String
        let path = NSTemporaryDirectory() + "fp_\(i)_\(UUID().uuidString).sqlite"
        do {
            let store = try SQLiteTraceStore<ConformanceEvent>(fileURL: URL(fileURLWithPath: path))
            DProvenanceKit<ConformanceEvent>.runSync(contextID: "fingerprint", store: store) {
                for ev in events {
                    let engine = ev["engine"] as? String ?? "Unknown"
                    DProvenanceKit<ConformanceEvent>.withEngineSync(name: engine) {
                        _ = DProvenanceKit<ConformanceEvent>.record(ConformanceEvent(typeName: ev["type"] as! String))
                    }
                }
            }
            try await store.flush()
            let got = readFingerprint(path) ?? "<none>"
            check("case \(i)", got == expected, "expected \(expected) got \(got)")
        } catch {
            check("case \(i)", false, "error \(error)")
        }
    }
}

// MARK: - 3. Query semantics (§6)

func node(fromWire obj: [String: Any]) -> TraceQueryNode<ConformanceEvent> {
    let t = obj["type"] as! String
    switch t {
    case "and": return .and((obj["nodes"] as! [[String: Any]]).map(node(fromWire:)))
    case "or": return .or((obj["nodes"] as! [[String: Any]]).map(node(fromWire:)))
    case "not": return .not(node(fromWire: obj["node"] as! [String: Any]))
    case "contextIDEquals": return .contextIDEquals(obj["id"] as! String)
    case "engineNameEquals": return .engineNameEquals(obj["name"] as! String)
    case "containsStep": return .containsStep(obj["step"] as! String)
    case "missingStep": return .missingStep(obj["step"] as! String)
    case "sequence": return .sequence(obj["steps"] as! [String])
    case "after": return .after(step: obj["step"] as! String, followedBy: obj["followedBy"] as! String)
    case "before": return .before(step: obj["step"] as! String, precededBy: obj["precededBy"] as! String)
    default: fatalError("unknown wire node \(t)")
    }
}

func checkQuerySemantics() {
    print("\n[3] query semantics")
    let doc = loadVector("query_semantics.json")
    var corpus: [TraceRun<ConformanceEvent>] = []
    for spec in doc["corpus"] as! [[String: Any]] {
        let runID = UUID()
        let ctx = spec["context_id"] as! String
        let engine = spec["engine"] as! String
        let events = (spec["events"] as! [[String: Any]]).enumerated().map { (i, ev) in
            TraceEvent(runID: runID, contextID: ctx, engineName: engine, schemaVersion: 1,
                       sequence: UInt64(i), spanID: nil, parentSpanID: nil,
                       payload: ConformanceEvent(typeName: ev["type"] as! String),
                       timestamp: Date(timeIntervalSince1970: Double(i)))
        }
        corpus.append(TraceRun(runID: runID, contextID: ctx, events: events))
    }
    for (i, raw) in (doc["cases"] as! [[String: Any]]).enumerated() {
        let n = node(fromWire: raw["dsl"] as! [String: Any])
        let matched = corpus.filter { n.evaluate(run: $0) }.map { $0.contextID }.sorted()
        let expected = (raw["expected_context_ids"] as! [String]).sorted()
        check("case \(i)", matched == expected, "expected \(expected) got \(matched)")
    }
}

// MARK: - 4. Profile hash (§10.1)

func dbl(_ any: Any) -> Double { (any as! NSNumber).doubleValue }
func intf(_ any: Any) -> Int { (any as! NSNumber).intValue }

func profile(fromWire p: [String: Any]) -> AlignmentProfile {
    AlignmentProfile(
        strategy: AlignmentProfile.Strategy(rawValue: p["strategy"] as! String)!,
        version: intf(p["version"]!),
        typeWeight: dbl(p["type_weight"]!),
        payloadWeight: dbl(p["payload_weight"]!),
        structuralWeight: dbl(p["structural_weight"]!),
        temporalWeight: dbl(p["temporal_weight"]!),
        semanticThreshold: dbl(p["semantic_threshold"]!),
        maxAmbiguousCandidates: intf(p["max_ambiguous_candidates"]!),
        ambiguityDeltaThreshold: dbl(p["ambiguity_delta_threshold"]!),
        alignmentMode: AlignmentMode(rawValue: p["alignment_mode"] as! String)!
    )
}

func checkProfileHash() {
    print("\n[4] profile hash")
    let doc = loadVector("profile_hash.json")
    for (i, raw) in (doc["cases"] as! [[String: Any]]).enumerated() {
        let prof = profile(fromWire: raw["profile"] as! [String: Any])
        let got = AlignmentExecutionContract.computeProfileHash(
            profile: prof,
            evaluatorIdentifier: raw["evaluator_identifier"] as! String,
            engineVersion: raw["engine_version"] as! String)
        check("case \(i): \(raw["description"] as? String ?? "")", got == (raw["profile_hash"] as! String),
              "expected \(raw["profile_hash"] as! String) got \(got)")
    }
}

// MARK: - 5. Alignment verdict (§10.2)

func stateKind(_ s: AlignmentState) -> String {
    switch s {
    case .exactMatch: return "exactMatch"
    case .semanticMatch: return "semanticMatch"
    case .reordered: return "reordered"
    case .ambiguous: return "ambiguous"
    case .added: return "added"
    case .removed: return "removed"
    }
}

func buildRun(_ specs: [[String: Any]], contextID: String, runIndex: Int) -> TraceRun<ConformanceEvent> {
    let runID = UUID()
    let events = specs.enumerated().map { (i, ev) in
        // The vector pins an explicit `id`; the canonical alignment sort tiebreaks on it.
        let id = (ev["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
        return TraceEvent(id: id, runID: runID, contextID: contextID, engineName: "E", schemaVersion: 1,
                          sequence: UInt64(i), spanID: nil, parentSpanID: nil,
                          payload: eventFromSpec(ev), timestamp: Date(timeIntervalSince1970: Double(i)))
    }
    return TraceRun(runID: runID, contextID: contextID, events: events)
}

func checkAlignmentVerdict() {
    print("\n[5] alignment verdict")
    let doc = loadVector("alignment_verdict.json")
    let evaluator = AnyEquivalenceEvaluator<ConformanceEvent>(
        identifier: "ExactEquality_v1",
        evaluator: { a, b in a == b ? 1.0 : 0.0 })
    for (i, raw) in (doc["cases"] as! [[String: Any]]).enumerated() {
        let profileName = raw["profile"] as! String
        let prof: AlignmentProfile = (profileName == "developer_debug_v1") ? .developerDebugV1 : .strictAuditV1
        let config = AlignmentConfiguration(profile: prof, equivalenceEvaluator: evaluator)
        let engine = TraceAlignmentEngine(configuration: config)
        let base = buildRun(raw["base"] as! [[String: Any]], contextID: "base", runIndex: 0)
        let comparison = buildRun(raw["comparison"] as! [[String: Any]], contextID: "comparison", runIndex: 1)
        let result = engine.align(base: base, comparison: comparison, minimumPriority: .structural)

        let expected = raw["expected"] as! [String: Any]
        let level = result.regressionRisk.level.rawValue
        let strength = result.regressionRisk.strength
        let kinds = AlignmentExecutionContract.canonicalSort(alignments: result.alignments).map { stateKind($0.state) }
        let ok = level == (expected["regression_level"] as! String)
            && abs(strength - (expected["regression_strength"] as! NSNumber).doubleValue) < 1e-6
            && kinds == (expected["alignment_state_kinds"] as! [String])
        check("case \(i): \(raw["description"] as? String ?? "")", ok,
              "level \(level) strength \(strength) kinds \(kinds)")
    }
}

// MARK: - Run all

print("Trace Specification v1 — Swift conformance")
print("vectors: \(VECTORS)")
checkPayloadEncoding()
await checkRunFingerprint()
checkQuerySemantics()
checkProfileHash()
checkAlignmentVerdict()

print("\n" + String(repeating: "=", count: 60))
if failures.isEmpty {
    print("ALL VECTORS REPRODUCED ✓  — Swift conforms to Trace Specification v1")
    exit(0)
} else {
    print("FAILURES (\(failures.count)): \(failures.joined(separator: ", "))")
    exit(1)
}
