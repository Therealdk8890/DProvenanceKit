import Foundation

/// An actor that queues trace events in memory to provide a zero-blocking write path.
/// Employs a priority-based congestion control mechanism to gracefully degrade under extreme burst load.
public actor TraceWriteBuffer {
    // Ingestion Queue
    private var queue: [TraceEventRow] = []
    
    // Tracking for per-run degradation
    private var queueDepthByRun: [String: Int] = [:]
    
    private let maxGlobalBuffer: Int
    private let maxPerRunBuffer: Int
    
    public init(maxGlobalBuffer: Int = 50_000, maxPerRunBuffer: Int = 5_000) {
        self.maxGlobalBuffer = maxGlobalBuffer
        self.maxPerRunBuffer = maxPerRunBuffer
    }
    
    public var currentDepth: Int { queue.count }
    
    /// Enqueues an event using intelligent congestion control.
    public func enqueue(_ event: TraceEventRow) {
        let runDepth = queueDepthByRun[event.runID, default: 0]
        let priority = TracePriority(rawValue: event.priority) ?? .telemetry
        
        // 1. Soft per-run limits
        if runDepth >= maxPerRunBuffer {
            if priority <= .diagnostic {
                // Degrade run: drop verbose and diagnostic events for this specific run
                return 
            }
            // We preserve structural and critical events even if the run is bursting
        }
        
        // 2. Global capacity limits
        if queue.count >= maxGlobalBuffer {
            // Find a victim to drop from the global buffer
            if let victimIdx = queue.firstIndex(where: { $0.priority == TracePriority.telemetry.rawValue }) {
                let victim = queue.remove(at: victimIdx)
                decrementRunDepth(victim.runID)
            } else if let victimIdx = queue.firstIndex(where: { $0.priority == TracePriority.diagnostic.rawValue }) {
                let victim = queue.remove(at: victimIdx)
                decrementRunDepth(victim.runID)
            } else {
                // If the entire buffer is filled with structural/critical events,
                // drop the incoming event unless it's critical, in which case drop the oldest structural
                if priority <= .structural {
                    return 
                } else if let victimIdx = queue.firstIndex(where: { $0.priority == TracePriority.structural.rawValue }) {
                    let victim = queue.remove(at: victimIdx)
                    decrementRunDepth(victim.runID)
                } else {
                    // Absolute worst case: buffer filled 100% with critical events
                    let victim = queue.removeFirst()
                    decrementRunDepth(victim.runID)
                }
            }
        }
        
        queue.append(event)
        queueDepthByRun[event.runID, default: 0] += 1
    }
    
    private func decrementRunDepth(_ runID: String) {
        queueDepthByRun[runID, default: 1] -= 1
        if queueDepthByRun[runID] == 0 {
            queueDepthByRun.removeValue(forKey: runID)
        }
    }
    
    /// Drains up to `max` events from the buffer into the writer queue phase.
    public func drain(max: Int = 1000) -> [TraceEventRow] {
        let batchSize = Swift.min(queue.count, max)
        guard batchSize > 0 else { return [] }
        let batch = Array(queue.prefix(batchSize))
        queue.removeFirst(batchSize)
        
        // Update per-run depth
        for event in batch {
            decrementRunDepth(event.runID)
        }
        
        return batch
    }
    
    /// Drains all remaining events in the buffer.
    public func flushAll() -> [TraceEventRow] {
        let all = queue
        queue.removeAll()
        queueDepthByRun.removeAll()
        return all
    }
}
