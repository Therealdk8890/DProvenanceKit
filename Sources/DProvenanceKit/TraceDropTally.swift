import Foundation

/// A thread-safe, by-tier tally of events lost *outside* the write buffer.
///
/// The buffer counts its own congestion shedding (see `TraceWriteBuffer.dropStats`).
/// This counts the other two store-level loss sites so neither vanishes silently while
/// `preservedIntegrity` still claims everything was retained:
///   - a payload that fails to JSON-encode in `SQLiteTraceStore.record`, and
///   - a batch the background `SQLiteWriter` fails to persist (the transaction rolls
///     back, so the drained rows are gone).
///
/// A single instance is shared by reference between the store (encode path) and its
/// writer (failed-batch path); both record into it, and the store folds its snapshot
/// into `dropStats`. Counting is per `TracePriority` tier because only a `structural`
/// or `critical` loss can make two genuinely-different runs look identical.
public final class TraceDropTally: @unchecked Sendable {
    private let lock = NSLock()
    private var byTier: [UInt64] = [0, 0, 0, 0]

    public init() {}

    /// Records `count` lost events in the given priority tier. Out-of-range tiers are
    /// ignored rather than trapping — a tally must never be the thing that crashes.
    public func record(priority: Int, count: UInt64 = 1) {
        lock.withLock {
            guard byTier.indices.contains(priority) else { return }
            byTier[priority] &+= count
        }
    }

    /// A point-in-time snapshot of everything tallied so far.
    public var snapshot: TraceDropStats {
        lock.withLock {
            TraceDropStats(
                telemetry: byTier[TracePriority.telemetry.rawValue],
                diagnostic: byTier[TracePriority.diagnostic.rawValue],
                structural: byTier[TracePriority.structural.rawValue],
                critical: byTier[TracePriority.critical.rawValue]
            )
        }
    }
}
