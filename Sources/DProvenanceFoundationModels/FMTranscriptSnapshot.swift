import Foundation

/// The neutral transcript IR: a Codable, SDK-free mirror of
/// FoundationModels' `Transcript` shape. Every design decision — mapping,
/// redaction, span paths, invocation pairing — operates on this type, which
/// is why the whole decision layer compiles and tests on the package floor
/// (macOS 13 / iOS 16) with no FoundationModels SDK present.
///
/// Entries align 1:1 with transcript entries (unknown kinds included), so
/// entry indices in this snapshot ARE transcript indices.
public struct FMTranscriptSnapshot: Codable, Sendable, Equatable {
    public struct Call: Codable, Sendable, Equatable {
        public var toolName: String
        /// `GeneratedContent.jsonString` (verified: preserves key order).
        public var argumentsJSON: String

        public init(toolName: String, argumentsJSON: String) {
            self.toolName = toolName
            self.argumentsJSON = argumentsJSON
        }
    }

    public enum Entry: Codable, Sendable, Equatable {
        case instructions(text: String, toolNames: [String], toolDescriptions: [String: String])
        case prompt(text: String, options: FMGenerationOptionsSnapshot?, responseFormatName: String?)
        case toolCalls([Call])
        case toolOutput(toolName: String, text: String)
        case response(text: String, assetIDCount: Int)
        case unknown(description: String)
    }

    public var entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }
}
