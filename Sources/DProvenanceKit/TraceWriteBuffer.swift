import Foundation

/// An actor that queues trace events in memory to provide a zero-blocking write path.
public actor TraceWriteBuffer {
    private var queue: [TraceEventRow] = []
    private let maxBufferSize: Int
    
    public init(maxBufferSize: Int = 10_000) {
        self.maxBufferSize = maxBufferSize
    }
    
    /// Enqueues an event. If the buffer is at capacity, the oldest event is dropped.
    public func enqueue(_ event: TraceEventRow) {
        if queue.count >= maxBufferSize {
            // Backpressure Policy: Drop oldest event.
            // Alternatively, could filter by severity if events had priority.
            print("🚨 [DProvenanceKit] Warning: TraceWriteBuffer capacity reached (\(maxBufferSize)). Dropping oldest event.")
            queue.removeFirst()
        }
        queue.append(event)
    }
    
    /// Drains up to `max` events from the buffer.
    public func drain(max: Int = 1000) -> [TraceEventRow] {
        let batchSize = Swift.min(queue.count, max)
        guard batchSize > 0 else { return [] }
        let batch = Array(queue.prefix(batchSize))
        queue.removeFirst(batchSize)
        return batch
    }
    
    /// Drains all remaining events in the buffer.
    public func flushAll() -> [TraceEventRow] {
        let all = queue
        queue.removeAll()
        return all
    }
}
