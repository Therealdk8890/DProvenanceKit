import Foundation

public enum OTLPJSON {
    /// `.withoutEscapingSlashes` always; `.sortedKeys` when deterministic.
    /// NOTE: `.sortedKeys` covers object keys only — array ordering is the
    /// mapper's contract (mapping rule M7). Byte-stability additionally
    /// assumes the same OS/Foundation version, because `doubleValue`
    /// formatting is stable per Foundation release, not across them.
    public static func encode(_ document: OTLPTraceDocument,
                              deterministic: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = deterministic
            ? [.sortedKeys, .withoutEscapingSlashes]
            : [.withoutEscapingSlashes]
        // Proto3 JSON defines "NaN"/"Infinity"/"-Infinity" strings for
        // non-finite doubles; without this a single NaN attribute (e.g. a
        // computed temperature) would fail the whole export as encodingFailed.
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN"
        )
        return try encoder.encode(document)
    }
}

/// Nanosecond timestamp conversion (mapping rule M5).
///
/// Truncation, never rounding — this deliberately matches `SQLiteTraceStore`'s
/// `Int64(t * 1_000_000)` write path so InMemory- and SQLite-backed exports of
/// the same event agree. Switching to `.rounded()` would desync the two by 1µs.
enum OTLPTimestamp {
    /// The negative guard must run BEFORE conversion: `UInt64(negativeDouble)`
    /// traps. Far-future dates (beyond what fits in uint64 nanos, ~year 2554)
    /// saturate rather than trap on the `* 1_000` step.
    static func unixNano(_ date: Date) -> String {
        let seconds = date.timeIntervalSince1970
        guard seconds >= 0 else { return "0" }
        let micros = seconds * 1_000_000
        guard micros < Double(UInt64.max / 1_000) else {
            return String((UInt64.max / 1_000) * 1_000)
        }
        return String(UInt64(micros) * 1_000)
    }
}
