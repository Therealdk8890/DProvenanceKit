import Foundation
import CryptoKit

/// Deterministic ID derivation (mapping rule M2).
///
/// Ids are pure functions of DPK identifiers so any DPK tool can compute the
/// OTel traceId from a runID offline, and re-exports of the same run land on
/// the same trace. EVERY preimage uses `runID.uuidString.lowercased()` — UUID
/// casing must never influence the digest (Foundation renders `uuidString`
/// uppercase; a raw interpolation would silently fork the scheme). `dpkSpanID`
/// and `sequence` are byte-exact as recorded: span names are case-sensitive
/// user data, and the fixed-length UUID segment keeps every preimage
/// unambiguous without a separator-escaping scheme.
///
/// The preimage prefix carries `OTelBridge.idSchemeVersion`; the derivations
/// below are frozen for "v1" by known-answer tests.
public enum OTelTraceIdentity {
    /// SHA256("dpk-otel:v1:trace:" + runLower)[0..<16], lowercase hex.
    public static func traceID(forRun runID: UUID) -> String {
        derive("dpk-otel:v1:trace:" + runID.uuidString.lowercased(), byteCount: 16)
    }

    /// SHA256("dpk-otel:v1:root:" + runLower)[0..<8].
    public static func rootSpanID(forRun runID: UUID) -> String {
        derive("dpk-otel:v1:root:" + runID.uuidString.lowercased(), byteCount: 8)
    }

    /// SHA256("dpk-otel:v1:span:" + runLower + ":" + dpkSpanID)[0..<8].
    /// Used for real AND synthesized spans, so if a span that was synthesized
    /// (no member events) gains events in a later export, the ids agree.
    public static func spanID(forRun runID: UUID, dpkSpanID: String) -> String {
        derive("dpk-otel:v1:span:" + runID.uuidString.lowercased() + ":" + dpkSpanID, byteCount: 8)
    }

    /// SHA256("dpk-otel:v1:event:" + runLower + ":" + String(sequence))[0..<8].
    /// For GenAI-promoted event spans; `sequence` is unique per run, so this
    /// is collision-free and re-export-stable.
    public static func eventSpanID(forRun runID: UUID, sequence: UInt64) -> String {
        derive("dpk-otel:v1:event:" + runID.uuidString.lowercased() + ":" + String(sequence), byteCount: 8)
    }

    /// OTLP reserves the all-zero id as "invalid"; a digest prefix that lands
    /// on it (2^-64 / 2^-128, but cheap to guard) is nudged to `…01`.
    private static func derive(_ preimage: String, byteCount: Int) -> String {
        let digest = SHA256.hash(data: Data(preimage.utf8))
        var bytes = [UInt8](digest.prefix(byteCount))
        if bytes.allSatisfy({ $0 == 0 }) {
            bytes[byteCount - 1] = 0x01
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
