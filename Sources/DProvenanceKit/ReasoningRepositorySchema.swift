import CryptoKit
import Foundation

/// A valid signature authenticates bytes under a key; identity trust requires a
/// caller-supplied key-ID pin. It does not certify recorded reasoning as true.
public struct ReasoningRepositorySignatureVerification: Sendable, Equatable {
    public let signatureID: String
    public let subject: String
    public let keyID: String
    public let trustedKey: Bool
}

public extension ReasoningRepositoryBundle {
    func signatureVerifications(trustedKeyIDs: Set<String> = []) -> [ReasoningRepositorySignatureVerification] {
        objects.keys.sorted().compactMap { id in
            guard let object = objects[id], object.type == .signature,
                  case .map(let fields) = object.payload,
                  let subject = fields["subject"]?.stringValue,
                  let keyID = fields["key_id"]?.stringValue else { return nil }
            return ReasoningRepositorySignatureVerification(signatureID: id, subject: subject,
                keyID: keyID, trustedKey: trustedKeyIDs.contains(keyID))
        }
    }
}

private extension ReasoningRepositoryValue {
    var stringValue: String? { if case .string(let value) = self { return value }; return nil }
    var integerValue: Int64? { if case .integer(let value) = self { return value }; return nil }
    var mapValue: ReasoningRepositoryMap? { if case .map(let value) = self { return value }; return nil }
    var arrayValue: [ReasoningRepositoryValue]? { if case .array(let value) = self { return value }; return nil }
    var bytesValue: Data? { if case .bytes(let value) = self { return value }; return nil }
    var isStringOrNull: Bool {
        if case .null = self { return true }
        return stringValue != nil
    }
}

enum ReasoningRepositorySchema {
    private static let keys: [ReasoningRepositoryObjectType: Set<String>] = [
        .blob: ["data"],
        .workflow: ["assets", "config", "source", "capture_policy"],
        .run: ["run_id", "context_id", "workflow", "workflow_binding", "events", "edges", "capture_quality", "graph_health"],
        .commit: ["parents", "workflow", "run", "message", "author", "created_at_us"],
        .evaluation: ["base", "candidate", "policy", "policy_digest", "report"],
        .signature: ["subject", "algorithm", "key_id", "public_key", "signature"]
    ]

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ReasoningRepositoryError.malformed(message) }
    }

    private static func identifier(_ value: ReasoningRepositoryValue?) throws -> String {
        guard let id = value?.stringValue, ReasoningRepositoryObject.isObjectID(id) else {
            throw ReasoningRepositoryError.malformed("invalid object reference")
        }
        return id
    }

    static func validate(objects: [String: ReasoningRepositoryObject], roots: [String], refs: ReasoningRepositoryMap) throws {
        var references: [String: [(String, ReasoningRepositoryObjectType)]] = [:]
        for (id, object) in objects {
            guard case .map(let fields) = object.payload,
                  Set(fields.fields.map(\.key)) == keys[object.type]! else {
                throw ReasoningRepositoryError.malformed("unexpected or missing \(object.type.rawValue) fields")
            }
            references[id] = try shape(object.type, fields)
        }
        for (id, edges) in references {
            for (target, expected) in edges {
                guard let object = objects[target] else { throw ReasoningRepositoryError.missingObject(target) }
                try require(object.type == expected, "object reference type mismatch")
            }
            if objects[id]?.type == .commit, case .map(let fields) = objects[id]!.payload {
                let runID = try identifier(fields["run"])
                guard case .map(let run) = objects[runID]!.payload else {
                    throw ReasoningRepositoryError.malformed("commit run payload")
                }
                try require(run["workflow"] == fields["workflow"], "commit/run workflow mismatch")
            }
        }
        let refTargets = refs.fields.compactMap { $0.value.stringValue }
        for target in refTargets {
            try require(objects[target]?.type == .commit, "bundle ref must name a commit")
        }
        // Iterative DFS rejects reference cycles without consuming the Swift stack.
        var state: [String: Int] = [:]
        for start in objects.keys where state[start] == nil {
            var stack: [(String, Bool)] = [(start, false)]
            while let (node, exiting) = stack.popLast() {
                if exiting { state[node] = 2; continue }
                if state[node] == 1 { throw ReasoningRepositoryError.malformed("object reference cycle") }
                if state[node] == 2 { continue }
                state[node] = 1
                stack.append((node, true))
                for (target, _) in references[node] ?? [] { stack.append((target, false)) }
            }
        }
        var reachable = Set<String>()
        var pending = roots
        while let id = pending.popLast() {
            if !reachable.insert(id).inserted { continue }
            pending.append(contentsOf: (references[id] ?? []).map(\.0))
        }
        // Detached signatures may accompany a reachable subject without becoming
        // a parent/reference of that subject (which would change its identity).
        for (id, object) in objects where object.type == .signature {
            if let subject = references[id]?.first?.0, reachable.contains(subject) { reachable.insert(id) }
        }
        try require(reachable == Set(objects.keys), "unreachable bundle inventory")
        try require(Set(refTargets).isSubset(of: reachable), "unreachable bundle ref")
    }

    private static func shape(_ type: ReasoningRepositoryObjectType, _ fields: ReasoningRepositoryMap)
        throws -> [(String, ReasoningRepositoryObjectType)] {
        switch type {
        case .blob:
            try require(fields["data"]?.bytesValue != nil, "blob data must be bytes")
            return []
        case .workflow:
            for key in keys[.workflow]! { try require(fields[key]?.mapValue != nil, "workflow fields must be maps") }
            return try fields["assets"]!.mapValue!.fields.map {
                try require(!$0.key.isEmpty, "empty asset name")
                return (try identifier($0.value), .blob)
            }
        case .run:
            return try runShape(fields)
        case .commit:
            guard let parents = fields["parents"]?.arrayValue else {
                throw ReasoningRepositoryError.malformed("commit parents must be an array")
            }
            try require(parents.count <= 1, "v1 supports at most one commit parent")
            try require(fields["message"]?.stringValue != nil && fields["author"]?.stringValue != nil
                && fields["created_at_us"]?.integerValue != nil, "commit metadata")
            return try parents.map { (try identifier($0), .commit) }
                + [(try identifier(fields["workflow"]), .workflow), (try identifier(fields["run"]), .run)]
        case .evaluation:
            guard let policy = fields["policy"], policy.mapValue != nil, fields["report"]?.mapValue != nil else {
                throw ReasoningRepositoryError.malformed("evaluation policy/report")
            }
            let digest = ReasoningRepositoryObject.digest(Data(try canonicalJSON(policy).utf8))
            try require(fields["policy_digest"] == .string(digest), "policy digest mismatch")
            return [(try identifier(fields["base"]), .commit), (try identifier(fields["candidate"]), .commit)]
        case .signature:
            let subject = try identifier(fields["subject"])
            guard fields["algorithm"] == .string("P256-SHA256"),
                  let publicBytes = fields["public_key"]?.bytesValue,
                  let signatureBytes = fields["signature"]?.bytesValue else {
                throw ReasoningRepositoryError.malformed("signature metadata")
            }
            try require(fields["key_id"] == .string(ReasoningRepositoryObject.digest(publicBytes)),
                        "signature key ID mismatch")
            var message = Data("DPK-REPOSITORY-SIGNATURE-V1\0".utf8)
            var hex = subject.startIndex
            while hex < subject.endIndex {
                let end = subject.index(hex, offsetBy: 2)
                message.append(UInt8(subject[hex..<end], radix: 16)!)
                hex = end
            }
            do {
                let key = try P256.Signing.PublicKey(x963Representation: publicBytes)
                let signature = try P256.Signing.ECDSASignature(derRepresentation: signatureBytes)
                try require(key.isValidSignature(signature, for: message), "invalid repository signature")
            } catch {
                throw ReasoningRepositoryError.malformed("invalid repository signature")
            }
            return [(subject, .commit)]
        }
    }

    private static func runShape(_ fields: ReasoningRepositoryMap) throws -> [(String, ReasoningRepositoryObjectType)] {
        guard let runID = fields["run_id"]?.stringValue, !runID.isEmpty,
              fields["context_id"]?.stringValue != nil,
              let binding = fields["workflow_binding"]?.stringValue, ["prebound", "post_hoc"].contains(binding),
              let eventValues = fields["events"]?.arrayValue, let edgeValues = fields["edges"]?.arrayValue,
              let quality = fields["capture_quality"]?.mapValue else {
            throw ReasoningRepositoryError.malformed("run identity, arrays or quality")
        }
        var references: [(String, ReasoningRepositoryObjectType)] = [(try identifier(fields["workflow"]), .workflow)]
        let eventKeys: Set<String> = ["id", "run_id", "context_id", "engine", "schema_version", "sequence",
            "span_id", "parent_span_id", "type", "priority", "payload", "timestamp_us", "schema_provenance"]
        var events: [ReasoningRepositoryMap] = []
        for value in eventValues {
            guard let event = value.mapValue, Set(event.fields.map(\.key)) == eventKeys else {
                throw ReasoningRepositoryError.malformed("run event fields")
            }
            for key in ["id", "run_id", "context_id", "engine", "type"] {
                try require(event[key]?.stringValue != nil, "event string metadata")
            }
            try require(!event["id"]!.stringValue!.isEmpty && !event["type"]!.stringValue!.isEmpty, "event identity")
            guard let schema = event["schema_version"]?.integerValue, schema >= 1,
                  let sequence = event["sequence"]?.integerValue, sequence >= 0,
                  let priority = event["priority"]?.integerValue, (0...3).contains(priority),
                  event["timestamp_us"]?.integerValue != nil,
                  event["span_id"]?.isStringOrNull == true, event["parent_span_id"]?.isStringOrNull == true,
                  let provenance = event["schema_provenance"]?.stringValue,
                  ["recorded", "legacy_assumed_v1"].contains(provenance) else {
                throw ReasoningRepositoryError.malformed("event numeric/span/provenance metadata")
            }
            references.append((try identifier(event["payload"]), .blob))
            events.append(event)
        }
        var edges: [ReasoningRepositoryMap] = []
        for value in edgeValues {
            guard let edge = value.mapValue, Set(edge.fields.map(\.key)) == Set(["source_id", "target_id", "type"]),
                  edge["source_id"]?.stringValue != nil, edge["target_id"]?.stringValue != nil,
                  let type = edge["type"]?.stringValue, TraceEdgeType(rawValue: type) != nil else {
                throw ReasoningRepositoryError.malformed("run edge fields")
            }
            edges.append(edge)
        }
        try require(fields["graph_health"] == graphHealth(events: events, edges: edges, runID: runID),
                    "graph health assertion mismatch")
        guard let lifecycle = quality["lifecycle"]?.stringValue,
              ["completed", "failed", "interrupted", "legacy_unknown"].contains(lifecycle),
              let sealed = quality["sealed"], case .bool = sealed,
              let provenance = quality["schema_provenance"]?.stringValue,
              ["recorded", "legacy_assumed_v1"].contains(provenance) else {
            throw ReasoningRepositoryError.malformed("capture lifecycle/seal/provenance")
        }
        for key in ["attempted_events", "attempted_edges"] {
            if let value = quality[key], value != .null {
                try require((value.integerValue ?? -1) >= 0, "capture attempted count")
            }
        }
        for key in ["dropped_events", "dropped_edges", "undecoded_events"] {
            try require((quality[key]?.integerValue ?? -1) >= 0, "capture loss count")
        }
        if binding == "prebound" {
            try require(quality["workflow_id"] == fields["workflow"], "prebound capture workflow mismatch")
        }
        return references
    }

    private struct SpanParent { let value: Data? }
    private struct EdgeKey: Hashable { let source: Data; let target: Data; let type: String }

    private static func graphHealth(events: [ReasoningRepositoryMap], edges: [ReasoningRepositoryMap],
                                    runID: String) -> ReasoningRepositoryValue {
        var reasons = Set<String>()
        let ids = events.map { Data($0["id"]!.stringValue!.utf8) }
        let idSet = Set(ids)
        if ids.count != idSet.count { reasons.insert("DUPLICATE_EVENT_ID") }
        for (index, event) in events.enumerated() {
            if event["sequence"] != .integer(Int64(index)) { reasons.insert("SEQUENCE_GAP_OR_DUPLICATE") }
            if !event["run_id"]!.stringValue!.utf8.elementsEqual(runID.utf8) { reasons.insert("MIXED_RUN_EVENTS") }
        }
        var parents: [Data: SpanParent] = [:]
        for event in events {
            let parent = event["parent_span_id"]!.stringValue.map { Data($0.utf8) }
            if let span = event["span_id"]!.stringValue.map({ Data($0.utf8) }) {
                if let previous = parents[span], previous.value != parent { reasons.insert("INCONSISTENT_SPAN_PARENT") }
                parents[span] = SpanParent(value: parent)
            } else if parent != nil { reasons.insert("PARENT_WITHOUT_SPAN") }
        }
        var completed = Set<Data>()
        for start in parents.keys where !completed.contains(start) {
            var current: Data? = start
            var path = Set<Data>()
            while let node = current, !completed.contains(node) {
                if !path.insert(node).inserted { reasons.insert("SPAN_CYCLE"); break }
                guard let parent = parents[node] else { reasons.insert("MISSING_PARENT_SPAN"); break }
                current = parent.value
            }
            completed.formUnion(path)
        }
        var adjacency: [Data: [Data]] = [:]
        var seen = Set<EdgeKey>()
        for edge in edges {
            let source = Data(edge["source_id"]!.stringValue!.utf8)
            let target = Data(edge["target_id"]!.stringValue!.utf8)
            let key = EdgeKey(source: source, target: target, type: edge["type"]!.stringValue!)
            if !seen.insert(key).inserted { reasons.insert("DUPLICATE_EDGE") }
            if !idSet.contains(source) || !idSet.contains(target) { reasons.insert("EXTERNAL_OR_MISSING_EDGE_ENDPOINT") }
            if source == target { reasons.insert("SELF_EDGE") }
            adjacency[source, default: []].append(target)
        }
        var visited = Set<Data>()
        var active = Set<Data>()
        for start in idSet where !visited.contains(start) {
            var stack: [(Data, Bool)] = [(start, false)]
            while let (node, exiting) = stack.popLast() {
                if exiting { active.remove(node); visited.insert(node) }
                else if active.contains(node) { reasons.insert("PROVENANCE_CYCLE") }
                else if !visited.contains(node) {
                    active.insert(node)
                    stack.append((node, true))
                    stack.append(contentsOf: (adjacency[node] ?? []).map { ($0, false) })
                }
            }
        }
        return .map(ReasoningRepositoryMap([
            "valid": .bool(reasons.isEmpty), "reasons": .array(reasons.sorted().map { .string($0) }),
            "event_count": .integer(Int64(events.count)), "edge_count": .integer(Int64(edges.count))
        ]))
    }

    private static func quoteJSON(_ text: String) -> String {
        var output = "\""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 34: output += "\\\""
            case 92: output += "\\\\"
            case 8: output += "\\b"
            case 12: output += "\\f"
            case 10: output += "\\n"
            case 13: output += "\\r"
            case 9: output += "\\t"
            case 0...31: output += String(format: "\\u%04x", scalar.value)
            default: output.unicodeScalars.append(scalar)
            }
        }
        return output + "\""
    }

    static func canonicalJSON(_ value: ReasoningRepositoryValue) throws -> String {
        switch value {
        case .null: return "null"
        case .bool(let boolean): return boolean ? "true" : "false"
        case .integer(let number): return String(number)
        case .string(let text): return quoteJSON(text)
        case .array(let values): return "[" + (try values.map(canonicalJSON)).joined(separator: ",") + "]"
        case .map(let fields):
            return "{" + (try fields.fields.map { quoteJSON($0.key) + ":" + (try canonicalJSON($0.value)) })
                .joined(separator: ",") + "}"
        case .bytes: throw ReasoningRepositoryError.malformed("policy must be JSON compatible")
        }
    }
}
