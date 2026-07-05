import Foundation
import CryptoKit

/// How a content field is materialized into a trace payload.
public enum FMContentRedaction: String, Codable, Sendable, Equatable {
    /// Text, hash, and byte count are all recorded.
    case full
    /// Only the hash and byte count are recorded; the text never leaves the process.
    case hashed
    /// Nothing content-derived is recorded.
    case omitted
}

/// A content field under a redaction policy.
///
/// `sha256` is the lowercase hex of SHA-256 over the EXACT UTF-8 bytes of the
/// original text — no normalization — so it is stable across processes and OS
/// releases.
///
/// Identity is (sha256, utf8Count) ONLY: a `.full` trace and a `.hashed` trace
/// of the same content compare exactly equal, so cross-policy diffing works
/// even on the exact-equality path. `.omitted` equals only `.omitted`.
/// `Hashable` hashes the same fields as `==`. `redaction` and `text` are
/// Codable but excluded from identity.
public struct FMRedactedText: Codable, Sendable, Equatable, Hashable {
    public let redaction: FMContentRedaction
    public let text: String?
    public let sha256: String?
    public let utf8Count: Int?

    public init(_ text: String, redaction: FMContentRedaction) {
        self.redaction = redaction
        switch redaction {
        case .full:
            self.text = text
            self.sha256 = Self.sha256Hex(of: text)
            self.utf8Count = text.utf8.count
        case .hashed:
            self.text = nil
            self.sha256 = Self.sha256Hex(of: text)
            self.utf8Count = text.utf8.count
        case .omitted:
            self.text = nil
            self.sha256 = nil
            self.utf8Count = nil
        }
    }

    public static let omitted = FMRedactedText("", redaction: .omitted)

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sha256 == rhs.sha256 && lhs.utf8Count == rhs.utf8Count
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(sha256)
        hasher.combine(utf8Count)
    }

    private static func sha256Hex(of text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Per-field redaction, applied at capture time. The default is `.full`
/// everywhere: on-device capture is the point. Prefer `.hashed` whenever
/// traces are written to stores that leave the device (SQLite exports, Cloud).
public struct FMRedactionPolicy: Sendable, Equatable {
    public var promptContent: FMContentRedaction
    public var responseContent: FMContentRedaction
    public var instructionsContent: FMContentRedaction
    public var toolArguments: FMContentRedaction
    public var toolOutput: FMContentRedaction
    public var errorMessages: FMContentRedaction

    public init(
        promptContent: FMContentRedaction = .full,
        responseContent: FMContentRedaction = .full,
        instructionsContent: FMContentRedaction = .full,
        toolArguments: FMContentRedaction = .full,
        toolOutput: FMContentRedaction = .full,
        errorMessages: FMContentRedaction = .full
    ) {
        self.promptContent = promptContent
        self.responseContent = responseContent
        self.instructionsContent = instructionsContent
        self.toolArguments = toolArguments
        self.toolOutput = toolOutput
        self.errorMessages = errorMessages
    }

    public static let full = FMRedactionPolicy()

    public static let hashed = FMRedactionPolicy(
        promptContent: .hashed,
        responseContent: .hashed,
        instructionsContent: .hashed,
        toolArguments: .hashed,
        toolOutput: .hashed,
        errorMessages: .hashed
    )

    public static let omitted = FMRedactionPolicy(
        promptContent: .omitted,
        responseContent: .omitted,
        instructionsContent: .omitted,
        toolArguments: .omitted,
        toolOutput: .omitted,
        errorMessages: .omitted
    )
}
