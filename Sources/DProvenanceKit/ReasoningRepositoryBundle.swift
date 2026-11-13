import CryptoKit
import Foundation

/// A verified, non-executable import of a local reasoning-history bundle.
/// Reading never opens a path, follows a URL, runs an adapter, or modifies refs.
public struct ReasoningRepositoryBundle: Sendable {
    public static let format = "DPK-REPOSITORY-BUNDLE-V1"
    public let roots: [String]
    public let refs: ReasoningRepositoryMap
    public let objects: [String: ReasoningRepositoryObject]

    public static func verify(_ data: Data,
                              limits: ReasoningRepositoryLimits = .init()) throws -> Self {
        let entries = try RepositoryStoredZIP.read(data, limits: limits)
        guard let manifestData = entries["manifest.json"] else {
            throw ReasoningRepositoryError.malformed("missing manifest.json")
        }
        var json = RepositoryManifestJSONReader(bytes: Array(manifestData), limits: limits)
        let manifestValue = try json.value(depth: 0)
        json.skipWhitespace()
        let canonicalManifest = try ReasoningRepositorySchema.canonicalJSON(manifestValue)
        guard Data(canonicalManifest.utf8) == manifestData else {
            throw ReasoningRepositoryError.malformed("noncanonical bundle manifest JSON")
        }
        guard json.offset == json.bytes.count, case .map(let manifest) = manifestValue,
              Set(manifest.fields.map(\.key)) == Set(["format", "version", "roots", "objects", "refs"]),
              manifest["format"] == .string(format), manifest["version"] == .integer(1),
              let rootField = manifest["roots"], case .array(let rootValues) = rootField,
              let objectField = manifest["objects"], case .array(let objectValues) = objectField,
              let refField = manifest["refs"], case .map(let refValues) = refField else {
            throw ReasoningRepositoryError.malformed("bundle manifest schema")
        }
        func objectIDs(_ values: [ReasoningRepositoryValue]) throws -> [String] {
            let result = try values.map { value -> String in
                guard case .string(let id) = value, ReasoningRepositoryObject.isObjectID(id) else {
                    throw ReasoningRepositoryError.malformed("manifest object ID")
                }
                return id
            }
            guard result == result.sorted(), Set(result).count == result.count else {
                throw ReasoningRepositoryError.malformed("manifest IDs must be sorted and unique")
            }
            return result
        }
        let roots = try objectIDs(rootValues)
        let ids = try objectIDs(objectValues)
        guard !roots.isEmpty, ids.count <= limits.maxObjects,
              Set(roots).isSubset(of: Set(ids)), entries.count == ids.count + 1 else {
            throw ReasoningRepositoryError.malformed("bundle object inventory")
        }
        for field in refValues.fields {
            guard Self.validRefName(field.key), case .string(let id) = field.value,
                  ids.contains(id) else {
                throw ReasoningRepositoryError.malformed("manifest ref")
            }
        }
        var objects: [String: ReasoningRepositoryObject] = [:]
        for id in ids {
            guard let bytes = entries["objects/\(id).bin"] else {
                throw ReasoningRepositoryError.missingObject(id)
            }
            guard ReasoningRepositoryObject.digest(bytes) == id else {
                throw ReasoningRepositoryError.digestMismatch(id)
            }
            objects[id] = try ReasoningRepositoryObject.decodeCanonical(bytes, limits: limits)
        }
        try ReasoningRepositorySchema.validate(objects: objects, roots: roots, refs: refValues)
        return Self(roots: roots, refs: refValues, objects: objects)
    }

    private static func validRefName(_ name: String) -> Bool {
        let parts = name.components(separatedBy: "/")
        return name.unicodeScalars.count <= 255 && parts.count >= 3 && parts[0] == "refs"
            && ["heads", "tags", "baselines"].contains(parts[1])
            && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasSuffix(".lock") }
            && !name.contains("@{") && !name.unicodeScalars.contains {
                $0.value < 33 || "~^:?*[\\".unicodeScalars.contains($0)
            }
    }
}

private enum RepositoryStoredZIP {
    static func read(_ data: Data, limits: ReasoningRepositoryLimits) throws -> [String: Data] {
        guard data.count <= limits.maxBundleBytes, data.count >= 22 else {
            throw ReasoningRepositoryError.limitExceeded("bundle bytes")
        }
        let bytes = Array(data)
        func unsigned(_ offset: Int, _ width: Int) throws -> UInt32 {
            guard offset >= 0, offset <= bytes.count - width else {
                throw ReasoningRepositoryError.malformed("truncated ZIP")
            }
            var value: UInt32 = 0
            for index in 0..<width { value |= UInt32(bytes[offset + index]) << (index * 8) }
            return value
        }
        func u16(_ offset: Int) throws -> Int { Int(try unsigned(offset, 2)) }
        func u32(_ offset: Int) throws -> Int { Int(try unsigned(offset, 4)) }
        // Bundle v1 deliberately excludes comments, ZIP64, encryption, compression
        // and data descriptors. The EOCD must be the final 22 bytes.
        let end = bytes.count - 22
        guard try u32(end) == 0x06054b50, try u16(end + 4) == 0,
              try u16(end + 6) == 0, try u16(end + 20) == 0 else {
            throw ReasoningRepositoryError.malformed("unsupported ZIP end record")
        }
        let count = try u16(end + 10)
        let centralSize = try u32(end + 12)
        let centralStart = try u32(end + 16)
        guard count > 0, count - 1 <= limits.maxObjects, try u16(end + 8) == count,
              centralStart <= end, centralSize == end - centralStart else {
            throw ReasoningRepositoryError.malformed("ZIP central directory bounds")
        }
        var cursor = centralStart
        var entries: [String: Data] = [:]
        var intervals: [(Int, Int)] = []
        for _ in 0..<count {
            let flags = try u16(cursor + 8)
            guard cursor <= end - 46, try u32(cursor) == 0x02014b50,
                  try u16(cursor + 6) <= 20, (flags == 0 || flags == 0x800), try u16(cursor + 10) == 0,
                  try u16(cursor + 30) == 0, try u16(cursor + 32) == 0,
                  try u16(cursor + 34) == 0 else {
                throw ReasoningRepositoryError.malformed("unsupported ZIP central entry")
            }
            let crc = try unsigned(cursor + 16, 4)
            let size = try u32(cursor + 24)
            let nameCount = try u16(cursor + 28)
            let local = try u32(cursor + 42)
            guard try u32(cursor + 20) == size, size <= limits.maxObjectBytes,
                  nameCount > 0, nameCount <= end - cursor - 46,
                  let name = String(bytes: bytes[(cursor + 46)..<(cursor + 46 + nameCount)], encoding: .utf8),
                  validEntryName(name), entries[name] == nil,
                  local <= centralStart - 30, try u32(local) == 0x04034b50,
                  try u16(local + 4) <= 20, try u16(local + 6) == flags, try u16(local + 8) == 0,
                  try unsigned(local + 14, 4) == crc, try u32(local + 18) == size,
                  try u32(local + 22) == size, try u16(local + 26) == nameCount,
                  try u16(local + 28) == 0 else {
                throw ReasoningRepositoryError.malformed("ZIP entry mismatch or unsafe name")
            }
            let start = local + 30 + nameCount
            guard start <= centralStart, size <= centralStart - start,
                  bytes[(local + 30)..<start].elementsEqual(name.utf8) else {
                throw ReasoningRepositoryError.malformed("ZIP local entry bounds")
            }
            let content = Data(bytes[start..<(start + size)])
            guard crc32(content) == crc else {
                throw ReasoningRepositoryError.malformed("ZIP CRC mismatch")
            }
            entries[name] = content
            intervals.append((local, start + size))
            cursor += 46 + nameCount
        }
        guard cursor == end else {
            throw ReasoningRepositoryError.malformed("ZIP central directory trailing bytes")
        }
        var expected = 0
        for interval in intervals.sorted(by: { $0.0 < $1.0 }) {
            guard interval.0 == expected else {
                throw ReasoningRepositoryError.malformed("overlapping or hidden ZIP data")
            }
            expected = interval.1
        }
        guard expected == centralStart else {
            throw ReasoningRepositoryError.malformed("ZIP local directory gap")
        }
        return entries
    }

    private static func validEntryName(_ name: String) -> Bool {
        if name == "manifest.json" { return true }
        guard name.hasPrefix("objects/"), name.hasSuffix(".bin") else { return false }
        return ReasoningRepositoryObject.isObjectID(String(name.dropFirst(8).dropLast(4)))
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = (value >> 1) ^ ((value & 1) == 0 ? 0 : 0xedb88320) }
        return value
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data { crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt32(byte)) & 255)] }
        return crc ^ UInt32.max
    }
}

/// A bounded manifest parser that rejects duplicate keys; JSONSerialization alone
/// would silently accept duplicate JSON object members.
private struct RepositoryManifestJSONReader {
    let bytes: [UInt8]
    let limits: ReasoningRepositoryLimits
    var offset = 0

    mutating func skipWhitespace() {
        while offset < bytes.count, [UInt8(9), 10, 13, 32].contains(bytes[offset]) { offset += 1 }
    }

    mutating func consume(_ byte: UInt8) throws {
        skipWhitespace()
        guard offset < bytes.count, bytes[offset] == byte else {
            throw ReasoningRepositoryError.malformed("manifest JSON delimiter")
        }
        offset += 1
    }

    mutating func string() throws -> String {
        skipWhitespace()
        let start = offset
        try consume(34)
        var escaped = false
        while offset < bytes.count {
            let byte = bytes[offset]
            offset += 1
            if byte == 34 && !escaped {
                do { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<offset])) }
                catch { throw ReasoningRepositoryError.malformed("manifest JSON string") }
            }
            if byte == 92 { escaped.toggle() } else { escaped = false }
        }
        throw ReasoningRepositoryError.malformed("unterminated manifest string")
    }

    mutating func value(depth: Int) throws -> ReasoningRepositoryValue {
        skipWhitespace()
        guard depth <= limits.maxDepth, offset < bytes.count else {
            throw ReasoningRepositoryError.malformed("manifest depth or truncation")
        }
        switch bytes[offset] {
        case 34: return .string(try string())
        case 123:
            try consume(123)
            var fields: [ReasoningRepositoryMap.Field] = []
            skipWhitespace()
            if offset < bytes.count, bytes[offset] == 125 { offset += 1; return .map(ReasoningRepositoryMap([:])) }
            while true {
                guard fields.count < limits.maxContainerItems else {
                    throw ReasoningRepositoryError.limitExceeded("manifest fields")
                }
                let key = try string()
                try consume(58)
                fields.append(.init(key, try value(depth: depth + 1)))
                skipWhitespace()
                if offset < bytes.count, bytes[offset] == 125 { offset += 1; break }
                try consume(44)
            }
            return .map(try ReasoningRepositoryMap(fields: fields))
        case 91:
            try consume(91)
            var values: [ReasoningRepositoryValue] = []
            skipWhitespace()
            if offset < bytes.count, bytes[offset] == 93 { offset += 1; return .array([]) }
            while true {
                guard values.count < limits.maxContainerItems else {
                    throw ReasoningRepositoryError.limitExceeded("manifest array")
                }
                values.append(try value(depth: depth + 1))
                skipWhitespace()
                if offset < bytes.count, bytes[offset] == 93 { offset += 1; break }
                try consume(44)
            }
            return .array(values)
        default:
            let start = offset
            if bytes[offset] == 45 { offset += 1 }
            while offset < bytes.count, (48...57).contains(bytes[offset]) { offset += 1 }
            guard start < offset, let text = String(bytes: bytes[start..<offset], encoding: .utf8),
                  let number = Int64(text), text == String(number) else {
                throw ReasoningRepositoryError.malformed("manifest JSON value")
            }
            return .integer(number)
        }
    }
}
