import CryptoKit
import Foundation

/// Values in the separately versioned DPK repository format. Floating-point values
/// are intentionally absent; producers must choose an explicit integer or string.
public indirect enum ReasoningRepositoryValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case integer(Int64)
    case string(String)
    case bytes(Data)
    case array([ReasoningRepositoryValue])
    case map(ReasoningRepositoryMap)

    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case (.bool(let a), .bool(let b)): return a == b
        case (.integer(let a), .integer(let b)): return a == b
        case (.string(let a), .string(let b)): return a.utf8.elementsEqual(b.utf8)
        case (.bytes(let a), .bytes(let b)): return a == b
        case (.array(let a), .array(let b)): return a == b
        case (.map(let a), .map(let b)): return a == b
        default: return false
        }
    }
}

/// Exact UTF-8 map keys. Swift's native String-keyed Dictionary normalizes key
/// equality; this container preserves distinct composed/decomposed spellings.
public struct ReasoningRepositoryMap: Sendable, Equatable {
    public struct Field: Sendable, Equatable {
        public let key: String
        public let value: ReasoningRepositoryValue

        public init(_ key: String, _ value: ReasoningRepositoryValue) {
            self.key = key
            self.value = value
        }

        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.key.utf8.elementsEqual(rhs.key.utf8) && lhs.value == rhs.value
        }
    }

    public let fields: [Field]

    public init(_ fields: [String: ReasoningRepositoryValue]) {
        self.fields = fields.map { Field($0.key, $0.value) }.sorted {
            $0.key.utf8.lexicographicallyPrecedes($1.key.utf8)
        }
    }

    public init(fields: [Field]) throws {
        let sorted = fields.sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }
        for index in sorted.indices.dropFirst() {
            guard !sorted[index - 1].key.utf8.elementsEqual(sorted[index].key.utf8) else {
                throw ReasoningRepositoryError.malformed("duplicate map key")
            }
        }
        self.fields = sorted
    }

    public subscript(_ key: String) -> ReasoningRepositoryValue? {
        fields.first { $0.key.utf8.elementsEqual(key.utf8) }?.value
    }
}

public enum ReasoningRepositoryObjectType: String, Sendable, CaseIterable, Hashable {
    case blob, workflow, run, commit, evaluation, signature
}

public enum ReasoningRepositoryError: Error, Equatable {
    case malformed(String)
    case limitExceeded(String)
    case unsupportedObjectType(String)
    case unsupportedVersion(UInt64)
    case digestMismatch(String)
    case missingObject(String)
}

/// Resource limits apply before allocating container contents or ZIP entries.
public struct ReasoningRepositoryLimits: Sendable {
    public var maxObjectBytes: Int
    public var maxBundleBytes: Int
    public var maxObjects: Int
    public var maxDepth: Int
    public var maxContainerItems: Int

    public init(maxObjectBytes: Int = 64 * 1_024 * 1_024,
                maxBundleBytes: Int = 256 * 1_024 * 1_024,
                maxObjects: Int = 10_000, maxDepth: Int = 64,
                maxContainerItems: Int = 1_000_000) {
        self.maxObjectBytes = maxObjectBytes
        self.maxBundleBytes = maxBundleBytes
        self.maxObjects = maxObjects
        self.maxDepth = maxDepth
        self.maxContainerItems = maxContainerItems
    }
}

/// An immutable portable object. Its ID is SHA-256 over its entire canonical
/// envelope, including domain, type, version and tagged payload. This is unrelated
/// to legacy structural fingerprints and DPK-BINARY-V1 attestation bytes.
public struct ReasoningRepositoryObject: Sendable, Equatable {
    public static let domain = "DPK-OBJECT-V1"
    public static let version: UInt64 = 1
    public let type: ReasoningRepositoryObjectType
    public let payload: ReasoningRepositoryValue

    public init(type: ReasoningRepositoryObjectType, payload: ReasoningRepositoryValue) {
        self.type = type
        self.payload = payload
    }

    public func canonicalData() -> Data {
        var writer = RepositoryObjectWriter()
        writer.string(Self.domain)
        writer.string(type.rawValue)
        writer.u64(Self.version)
        writer.value(payload)
        return Data(writer.bytes)
    }

    public var id: String { Self.digest(canonicalData()) }

    /// Bounds caller-constructed values before encoding. Use this at a write
    /// boundary when values came from an untrusted source; `canonicalData()` is
    /// the convenience path for already bounded in-memory values.
    public func checkedCanonicalData(limits: ReasoningRepositoryLimits = .init()) throws -> Data {
        var pending: [(ReasoningRepositoryValue, Int)] = [(payload, 0)]
        var count = 0
        var remaining = limits.maxObjectBytes
        func spend(_ amount: Int) throws {
            guard amount >= 0, amount <= remaining else {
                throw ReasoningRepositoryError.limitExceeded("object bytes")
            }
            remaining -= amount
        }
        try spend(37 + type.rawValue.utf8.count)
        while let (value, depth) = pending.popLast() {
            count += 1
            guard depth <= limits.maxDepth, count <= limits.maxContainerItems else {
                throw ReasoningRepositoryError.limitExceeded("value depth or items")
            }
            try spend(1)
            switch value {
            case .array(let values):
                try spend(8)
                guard pending.count <= limits.maxContainerItems - count,
                      values.count <= limits.maxContainerItems - count - pending.count else {
                    throw ReasoningRepositoryError.limitExceeded("array items")
                }
                pending.append(contentsOf: values.map { ($0, depth + 1) })
            case .map(let fields):
                try spend(8)
                guard pending.count <= limits.maxContainerItems - count,
                      fields.fields.count <= limits.maxContainerItems - count - pending.count else {
                    throw ReasoningRepositoryError.limitExceeded("map items")
                }
                for field in fields.fields { try spend(8); try spend(field.key.utf8.count) }
                pending.append(contentsOf: fields.fields.map { ($0.value, depth + 1) })
            case .string(let text):
                try spend(8)
                try spend(text.utf8.count)
            case .bytes(let bytes):
                try spend(8)
                try spend(bytes.count)
            case .integer: try spend(8)
            default: break
            }
        }
        let result = canonicalData()
        guard result.count <= limits.maxObjectBytes else {
            throw ReasoningRepositoryError.limitExceeded("object bytes")
        }
        return result
    }

    public static func decodeCanonical(_ data: Data,
                                       limits: ReasoningRepositoryLimits = .init()) throws -> Self {
        guard data.count <= limits.maxObjectBytes else {
            throw ReasoningRepositoryError.limitExceeded("object bytes")
        }
        var reader = RepositoryObjectReader(bytes: Array(data), limits: limits)
        guard try reader.string() == domain else {
            throw ReasoningRepositoryError.malformed("object domain")
        }
        let typeName = try reader.string()
        guard let type = ReasoningRepositoryObjectType(rawValue: typeName) else {
            throw ReasoningRepositoryError.unsupportedObjectType(typeName)
        }
        let version = try reader.u64()
        guard version == Self.version else {
            throw ReasoningRepositoryError.unsupportedVersion(version)
        }
        let payload = try reader.value(depth: 0)
        guard reader.offset == reader.bytes.count else {
            throw ReasoningRepositoryError.malformed("trailing object bytes")
        }
        return Self(type: type, payload: payload)
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func isObjectID(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

private struct RepositoryObjectWriter {
    var bytes: [UInt8] = []

    mutating func u64(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> shift))
        }
    }

    mutating func string(_ text: String) {
        let utf8 = Array(text.utf8)
        u64(UInt64(utf8.count))
        bytes.append(contentsOf: utf8)
    }

    mutating func value(_ value: ReasoningRepositoryValue) {
        switch value {
        case .null: bytes.append(0)
        case .bool(false): bytes.append(1)
        case .bool(true): bytes.append(2)
        case .integer(let number):
            bytes.append(3)
            u64(UInt64(bitPattern: number))
        case .string(let text):
            bytes.append(4)
            string(text)
        case .bytes(let data):
            bytes.append(5)
            u64(UInt64(data.count))
            bytes.append(contentsOf: data)
        case .array(let values):
            bytes.append(6)
            u64(UInt64(values.count))
            for item in values { self.value(item) }
        case .map(let fields):
            bytes.append(7)
            u64(UInt64(fields.fields.count))
            for field in fields.fields {
                string(field.key)
                self.value(field.value)
            }
        }
    }
}

private struct RepositoryObjectReader {
    let bytes: [UInt8]
    let limits: ReasoningRepositoryLimits
    var offset = 0
    var items = 0

    mutating func take(_ count: Int) throws -> [UInt8] {
        guard count >= 0, count <= bytes.count - offset else {
            throw ReasoningRepositoryError.malformed("truncated object")
        }
        let start = offset
        offset += count
        return Array(bytes[start..<offset])
    }

    mutating func u64() throws -> UInt64 {
        try take(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    mutating func count(maximum: Int, label: String) throws -> Int {
        let value = try u64()
        guard maximum >= 0, value <= UInt64(maximum) else {
            throw ReasoningRepositoryError.limitExceeded(label)
        }
        return Int(value)
    }

    mutating func string() throws -> String {
        let count = try count(maximum: limits.maxObjectBytes, label: "string bytes")
        guard let text = String(bytes: try take(count), encoding: .utf8) else {
            throw ReasoningRepositoryError.malformed("invalid UTF-8")
        }
        return text
    }

    mutating func value(depth: Int) throws -> ReasoningRepositoryValue {
        items += 1
        guard depth <= limits.maxDepth, items <= limits.maxContainerItems else {
            throw ReasoningRepositoryError.limitExceeded("value depth or items")
        }
        let tag = try take(1)[0]
        switch tag {
        case 0: return .null
        case 1: return .bool(false)
        case 2: return .bool(true)
        case 3: return .integer(Int64(bitPattern: try u64()))
        case 4: return .string(try string())
        case 5:
            let length = try count(maximum: limits.maxObjectBytes, label: "byte value")
            return .bytes(Data(try take(length)))
        case 6:
            let length = try count(maximum: limits.maxContainerItems, label: "array items")
            guard length <= bytes.count - offset else {
                throw ReasoningRepositoryError.malformed("truncated array")
            }
            var values: [ReasoningRepositoryValue] = []
            for _ in 0..<length { values.append(try value(depth: depth + 1)) }
            return .array(values)
        case 7:
            let length = try count(maximum: limits.maxContainerItems, label: "map items")
            guard length <= (bytes.count - offset) / 9 else {
                throw ReasoningRepositoryError.malformed("truncated map")
            }
            var fields: [ReasoningRepositoryMap.Field] = []
            var previous: String?
            for _ in 0..<length {
                let key = try string()
                if let previous, !previous.utf8.lexicographicallyPrecedes(key.utf8) {
                    throw ReasoningRepositoryError.malformed("map keys must be unique and UTF-8 sorted")
                }
                fields.append(.init(key, try value(depth: depth + 1)))
                previous = key
            }
            return .map(try ReasoningRepositoryMap(fields: fields))
        default:
            throw ReasoningRepositoryError.malformed("unknown value tag \(tag)")
        }
    }
}
