import Foundation

/// The cloud store's full honesty surface: what was lost (`dropped`) AND what is
/// retained in memory but undelivered (`quarantined`), with the one combined bit a
/// caller needs before trusting that a run reached the server.
///
/// `dropStats` alone cannot answer "did everything I recorded get delivered?": a
/// poison batch (HTTP 400) or a batch that exhausts its retries is quarantined —
/// retrievable via `queryQuarantinedEvents`, so it is deliberately NOT counted as a
/// drop — yet it is also not on the server, and quarantine does not survive process
/// exit. A caller reading only `dropStats.preservedIntegrity` would see `true` while
/// critical events sit undelivered in RAM. This report makes that state visible.
public struct CloudRetentionStats: Sendable, Equatable {
    /// Events lost outright: buffer shedding plus payloads that failed to encode.
    /// Identical to `CloudTraceStore.dropStats`.
    public let dropped: TraceDropStats
    /// Events (and lineage edges, counted as `structural`) sitting in the in-memory
    /// quarantine: rejected by the server (400) or out of retries. Retrievable via
    /// `queryQuarantinedEvents` while the process lives; gone when it exits.
    public let quarantined: TraceDropStats

    public init(dropped: TraceDropStats, quarantined: TraceDropStats) {
        self.dropped = dropped
        self.quarantined = quarantined
    }

    /// `true` only when nothing diff-relevant was lost AND nothing diff-relevant is
    /// stuck in quarantine — i.e. every recorded structural/critical event is either
    /// delivered or still honestly in flight. This is the bit to check before
    /// trusting server-side data for a run; `dropStats.preservedIntegrity` alone
    /// answers the narrower "was anything destroyed on this device?".
    public var preservedIntegrity: Bool {
        dropped.preservedIntegrity && quarantined.preservedIntegrity
    }
}
