import Foundation

/// A by-tier tally of trace events that were intentionally shed under congestion.
///
/// A diff or query is only as honest as the data behind it. Silent shedding is the
/// difference between "impressive" and "trustworthy": if the buffer quietly dropped
/// events and never said so, a consumer could compare two runs, see no difference,
/// and conclude they are identical when in fact the distinguishing event was never
/// recorded.
///
/// The breakdown is by priority because not all drops are equal. Telemetry and
/// diagnostic events are defined never to affect a structural diff (see
/// `TracePriority`), so shedding them under load is *safe by construction*. A drop in
/// the `structural` or `critical` tiers is categorically different — it means the
/// buffer was saturated past the point where integrity can be guaranteed, and any
/// diff over that run should be read with that caveat. `preservedIntegrity` collapses
/// that distinction into the one bit a caller usually wants.
public struct TraceDropStats: Sendable, Equatable {
    public var telemetry: UInt64
    public var diagnostic: UInt64
    public var structural: UInt64
    public var critical: UInt64

    public init(
        telemetry: UInt64 = 0,
        diagnostic: UInt64 = 0,
        structural: UInt64 = 0,
        critical: UInt64 = 0
    ) {
        self.telemetry = telemetry
        self.diagnostic = diagnostic
        self.structural = structural
        self.critical = critical
    }

    /// No events shed.
    public static let zero = TraceDropStats()

    /// Total events shed across every tier.
    public var total: UInt64 { telemetry &+ diagnostic &+ structural &+ critical }

    /// `true` when nothing that can change a structural diff was dropped.
    ///
    /// Telemetry and diagnostic events never participate in a structural diff, so
    /// shedding them leaves diff/query integrity intact. Only a `structural` or
    /// `critical` drop can make two genuinely-different runs look identical.
    public var preservedIntegrity: Bool { structural == 0 && critical == 0 }

    /// The count shed in a given tier.
    public subscript(_ priority: TracePriority) -> UInt64 {
        switch priority {
        case .telemetry: return telemetry
        case .diagnostic: return diagnostic
        case .structural: return structural
        case .critical: return critical
        }
    }
}
