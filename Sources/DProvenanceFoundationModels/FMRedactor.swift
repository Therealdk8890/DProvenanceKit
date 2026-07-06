import Foundation

/// Content-aware redaction: regex rules that mask sensitive substrings *inside* a field
/// while leaving the rest readable — e.g. strip an SSN or email from a prompt but keep
/// the surrounding text. Applied before the field's `FMContentRedaction` mode.
///
/// Masking is deterministic (same input → same output), so live and post-hoc capture of
/// the same content still produce byte-identical payloads, and two runs redacted with the
/// same rules still diff equal. A masked field's identity is derived from the *masked*
/// text, so it is (correctly) a distinct identity from an unmasked (`.full`/`.hashed`)
/// capture of the same original — they recorded different content.
public struct FMRedactor: Codable, Sendable, Equatable {

    public struct Rule: Codable, Sendable, Equatable {
        /// An `NSRegularExpression` pattern. An invalid pattern is skipped, never fatal.
        public let pattern: String
        /// Replacement template (supports `$1` etc.). Use a fixed tag like `[SSN]` to drop content.
        public let replacement: String

        public init(pattern: String, replacement: String) {
            self.pattern = pattern
            self.replacement = replacement
        }
    }

    public let rules: [Rule]

    public init(rules: [Rule]) {
        self.rules = rules
    }

    /// Applies each rule in order. A rule whose pattern fails to compile is skipped so a
    /// bad regex can never crash capture (observability must not break the observed).
    public func mask(_ text: String) -> String {
        var result = text
        for rule in rules {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern) else { continue }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range,
                                                    withTemplate: rule.replacement)
        }
        return result
    }

    /// Batteries-included rules for the most common PII: email, US SSN, and long digit
    /// runs (card/account numbers). Tune or replace for your data — this is a starting point.
    public static let commonPII = FMRedactor(rules: [
        Rule(pattern: #"[\w.+-]+@[\w-]+\.[\w.-]+"#, replacement: "[EMAIL]"),
        Rule(pattern: #"\b\d{3}-\d{2}-\d{4}\b"#, replacement: "[SSN]"),
        Rule(pattern: #"\b(?:\d[ -]*?){13,19}\b"#, replacement: "[NUMBER]"),
    ])
}
