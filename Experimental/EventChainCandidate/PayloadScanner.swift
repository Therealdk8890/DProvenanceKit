import Foundation

// Validate a JSON object without reserialization, numeric coercion or Swift String key equality.
// Escaped surrogate pairs combine; isolated escaped surrogates match Python's candidate parser.
// Candidate-only resource cap: depth 256. Cross-SDK limits remain a specification review gate.
struct PayloadScanner {
    private let tokens: [UInt32]
    private var offset = 0

    init(_ text: String) {
        tokens = text.unicodeScalars.map(\.value)
    }

    private var peek: UInt32? { offset < tokens.count ? tokens[offset] : nil }

    private mutating func take(_ value: UInt32) -> Bool {
        guard peek == value else { return false }
        offset += 1
        return true
    }

    private mutating func require(_ value: UInt32) throws {
        guard take(value) else { throw ChainFailure.invalidPayload }
    }

    private mutating func whitespace() {
        while let value = peek, [9, 10, 13, 32].contains(value) { offset += 1 }
    }

    mutating func validate() throws {
        whitespace()
        try object(depth: 0)
        whitespace()
        guard peek == nil else { throw ChainFailure.invalidPayload }
    }

    private mutating func object(depth: Int) throws {
        guard depth <= 256 else { throw ChainFailure.invalidPayload }
        try require(123)
        whitespace()
        if take(125) { return }
        var keys = Set<[UInt32]>()
        while true {
            whitespace()
            let key = try stringToken()
            guard keys.insert(key).inserted else { throw ChainFailure.invalidPayload }
            whitespace()
            try require(58)
            try value(depth: depth + 1)
            whitespace()
            if take(125) { return }
            try require(44)
        }
    }

    private mutating func array(depth: Int) throws {
        guard depth <= 256 else { throw ChainFailure.invalidPayload }
        try require(91)
        whitespace()
        if take(93) { return }
        while true {
            try value(depth: depth + 1)
            whitespace()
            if take(93) { return }
            try require(44)
        }
    }

    private mutating func value(depth: Int) throws {
        whitespace()
        switch peek {
        case 123: try object(depth: depth)
        case 91: try array(depth: depth)
        case 34: _ = try stringToken()
        case 116: try literal("true")
        case 102: try literal("false")
        case 110: try literal("null")
        default: try number()
        }
    }

    private mutating func literal(_ text: String) throws {
        for scalar in text.unicodeScalars { try require(scalar.value) }
    }

    private mutating func digits() -> Bool {
        let start = offset
        while let value = peek, (48...57).contains(value) { offset += 1 }
        return offset != start
    }

    private mutating func number() throws {
        _ = take(45)
        if !take(48) {
            guard let first = peek, (49...57).contains(first), digits() else {
                throw ChainFailure.invalidPayload
            }
        }
        if take(46), !digits() { throw ChainFailure.invalidPayload }
        if take(101) || take(69) {
            if !take(43) { _ = take(45) }
            guard digits() else { throw ChainFailure.invalidPayload }
        }
    }

    private mutating func hexQuad() throws -> UInt32 {
        var result: UInt32 = 0
        for _ in 0..<4 {
            guard let value = peek else { throw ChainFailure.invalidPayload }
            let digit: UInt32
            switch value {
            case 48...57: digit = value - 48
            case 65...70: digit = value - 55
            case 97...102: digit = value - 87
            default: throw ChainFailure.invalidPayload
            }
            offset += 1
            result = result * 16 + digit
        }
        return result
    }

    private mutating func unicodeEscape() throws -> UInt32 {
        let first = try hexQuad()
        guard (0xD800...0xDBFF).contains(first) else { return first }
        let saved = offset
        if take(92), take(117) {
            let second = try hexQuad()
            if (0xDC00...0xDFFF).contains(second) {
                return 0x10000 + (first - 0xD800) * 1024 + second - 0xDC00
            }
        }
        offset = saved
        return first
    }

    private mutating func stringToken() throws -> [UInt32] {
        try require(34)
        var result: [UInt32] = []
        while let value = peek {
            offset += 1
            if value == 34 { return result }
            if value == 92 {
                guard let escape = peek else { throw ChainFailure.invalidPayload }
                offset += 1
                switch escape {
                case 34, 47, 92: result.append(escape)
                case 98: result.append(8)
                case 102: result.append(12)
                case 110: result.append(10)
                case 114: result.append(13)
                case 116: result.append(9)
                case 117: result.append(try unicodeEscape())
                default: throw ChainFailure.invalidPayload
                }
            } else {
                guard value >= 32 else { throw ChainFailure.invalidPayload }
                result.append(value)
            }
        }
        throw ChainFailure.invalidPayload
    }
}
