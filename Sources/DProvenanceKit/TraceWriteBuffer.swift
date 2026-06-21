import Foundation

/// A minimal amortized-O(1) FIFO backed by an array with a moving head cursor.
/// Appending is O(1); `popFirst` advances the head and only pays an O(n) compaction
/// once the dead prefix dominates, so a long run of pops stays amortized O(1).
private struct FIFOQueue<Element> {
    private var storage: [Element] = []
    private var head: Int = 0

    var count: Int { storage.count - head }
    var first: Element? { head < storage.count ? storage[head] : nil }

    mutating func append(_ element: Element) {
        storage.append(element)
    }

    mutating func popFirst() -> Element? {
        guard head < storage.count else { return nil }
        let element = storage[head]
        head += 1
        // Reclaim the dead prefix once it dominates, amortizing to O(1) per pop.
        if head > 1024 && head * 2 >= storage.count {
            storage.removeFirst(head)
            head = 0
        }
        return element
    }
}

/// A buffer that queues trace events in memory to provide a zero-blocking write path.
///
/// Backed by a lock rather than actor isolation so that `enqueue` is *synchronous*:
/// an event is in the buffer the instant `record` returns. This gives callers a real
/// happens-before guarantee against `flush` (it becomes a true barrier) and preserves
/// record order under concurrency.
///
/// Congestion control is priority-bucketed: events are held in one FIFO per priority
/// tier, so both ingestion and load-shedding stay O(1) even at the exact moment a
/// burst pins the buffer at capacity — there is no per-event scan of the backlog.
/// Draining performs a k-way merge across the tiers so events are still handed to the
/// writer in global insertion order.
public final class TraceWriteBuffer: @unchecked Sendable {
    private struct Buffered {
        let stamp: UInt64
        let row: TraceEventRow
    }

    private let lock = NSLock()

    /// One FIFO per `TracePriority` tier, indexed by `rawValue` (0...3).
    private var tiers: [FIFOQueue<Buffered>]
    private var totalCount: Int = 0
    private var enqueueCounter: UInt64 = 0

    /// Lifetime count of events shed under congestion, indexed by `TracePriority`
    /// rawValue. Covers both incoming events refused at the door and buffered events
    /// later evicted to admit something more important — every silent loss lands here.
    private var droppedByTier: [UInt64] = [0, 0, 0, 0]

    // Tracking for per-run degradation
    private var queueDepthByRun: [String: Int] = [:]

    private let maxGlobalBuffer: Int
    private let maxPerRunBuffer: Int

    public init(maxGlobalBuffer: Int = 50_000, maxPerRunBuffer: Int = 5_000) {
        self.maxGlobalBuffer = maxGlobalBuffer
        self.maxPerRunBuffer = maxPerRunBuffer
        self.tiers = Array(repeating: FIFOQueue<Buffered>(), count: 4)
    }

    public var currentDepth: Int {
        lock.withLock { totalCount }
    }

    /// A by-tier tally of every event shed since this buffer was created.
    ///
    /// Exposed so a consumer can answer "can I trust this run's diff?" without
    /// guessing: `dropStats.preservedIntegrity` is `true` exactly when no structural
    /// or critical event was lost.
    public var dropStats: TraceDropStats {
        lock.withLock {
            TraceDropStats(
                telemetry: droppedByTier[TracePriority.telemetry.rawValue],
                diagnostic: droppedByTier[TracePriority.diagnostic.rawValue],
                structural: droppedByTier[TracePriority.structural.rawValue],
                critical: droppedByTier[TracePriority.critical.rawValue]
            )
        }
    }

    /// Enqueues an event using intelligent congestion control.
    ///
    /// Synchronous and ordered: the event is appended (or deliberately dropped under
    /// congestion) before this call returns. Both the happy path and the eviction
    /// path are O(1).
    public func enqueue(_ event: TraceEventRow) {
        lock.withLock {
            let priority = TracePriority(rawValue: event.priority) ?? .telemetry
            let runDepth = queueDepthByRun[event.runID, default: 0]

            // 1. Soft per-run limit: shed verbose/diagnostic for a bursting run, but
            //    keep its structural and critical events even while it bursts.
            if runDepth >= maxPerRunBuffer, priority <= .diagnostic {
                droppedByTier[priority.rawValue] &+= 1
                return
            }

            // 2. Global capacity: evict the lowest-priority, oldest victim to make room.
            if totalCount >= maxGlobalBuffer, !evictOneLocked(incoming: priority) {
                // Backlog is entirely higher-or-equal priority and the incoming event
                // is not important enough to displace it — drop the incoming event.
                droppedByTier[priority.rawValue] &+= 1
                return
            }

            let stamp = enqueueCounter
            enqueueCounter &+= 1
            tiers[priority.rawValue].append(Buffered(stamp: stamp, row: event))
            totalCount += 1
            queueDepthByRun[event.runID, default: 0] += 1
        }
    }

    /// Frees one slot under global pressure. Returns `false` only when the incoming
    /// event should itself be dropped (the backlog holds nothing cheaper to discard).
    /// Callers must hold `lock`.
    private func evictOneLocked(incoming: TracePriority) -> Bool {
        // Prefer discarding the oldest of the lowest-priority tier.
        if popVictimLocked(tier: .telemetry) { return true }
        if popVictimLocked(tier: .diagnostic) { return true }

        // Only structural/critical remain. Preserve that backlog unless the incoming
        // event is critical, in which case it may displace the oldest structural —
        // or, in the worst case, the oldest critical.
        if incoming <= .structural { return false }
        if popVictimLocked(tier: .structural) { return true }
        if popVictimLocked(tier: .critical) { return true }
        return false
    }

    /// Pops and permanently discards the oldest event of `tier` to free a slot.
    /// This is a real loss, so it is counted. Callers must hold `lock`.
    /// (The drain path pops tiers directly and is NOT a drop — only eviction is.)
    private func popVictimLocked(tier: TracePriority) -> Bool {
        guard let victim = tiers[tier.rawValue].popFirst() else { return false }
        totalCount -= 1
        droppedByTier[tier.rawValue] &+= 1
        decrementRunDepth(victim.row.runID)
        return true
    }

    /// Decrements the per-run depth counter. Callers must hold `lock`.
    private func decrementRunDepth(_ runID: String) {
        queueDepthByRun[runID, default: 1] -= 1
        if queueDepthByRun[runID] == 0 {
            queueDepthByRun.removeValue(forKey: runID)
        }
    }

    /// Drains up to `max` events, in global insertion order, for batched persistence.
    public func drain(max: Int = 1000) -> [TraceEventRow] {
        lock.withLock { drainLocked(max: max) }
    }

    /// Drains all remaining events, in global insertion order.
    public func flushAll() -> [TraceEventRow] {
        lock.withLock { drainLocked(max: Int.max) }
    }

    /// k-way merge across the priority tiers by insertion stamp. Callers must hold `lock`.
    private func drainLocked(max: Int) -> [TraceEventRow] {
        guard max > 0, totalCount > 0 else { return [] }

        var result: [TraceEventRow] = []
        result.reserveCapacity(Swift.min(max, totalCount))

        while result.count < max {
            var bestTier = -1
            var bestStamp = UInt64.max
            for t in 0..<tiers.count {
                if let front = tiers[t].first, front.stamp < bestStamp {
                    bestStamp = front.stamp
                    bestTier = t
                }
            }
            guard bestTier >= 0 else { break } // all tiers empty

            let buffered = tiers[bestTier].popFirst()!
            result.append(buffered.row)
            totalCount -= 1
            decrementRunDepth(buffered.row.runID)
        }

        return result
    }
}
