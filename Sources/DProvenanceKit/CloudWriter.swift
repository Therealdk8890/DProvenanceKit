import Foundation

public actor CloudWriter {
    private let endpoint: URL
    private let apiKey: String
    private let buffer: TraceWriteBuffer
    private let session: URLSession
    
    private var writeTask: Task<Void, Never>?
    private var isShuttingDown = false
    private var isSending = false
    
    private var inflightBatch: [TraceEventRow]? = nil
    private var attemptCount = 0
    private var quarantineQueue: [[TraceEventRow]] = []
    
    private let circuitBreaker = CircuitBreaker()
    
    public init(endpoint: URL, apiKey: String, buffer: TraceWriteBuffer, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.buffer = buffer
        self.session = session
    }
    
    public func start() {
        guard writeTask == nil else { return }
        writeTask = Task.detached { [weak self] in
            while true {
                guard let self = self else { break }
                let isShuttingDown = await self.isShuttingDown
                if isShuttingDown { break }
                
                await self.tick()
            }
        }
    }
    
    public func flush() async throws {
        while buffer.currentDepth > 0 || inflightBatch != nil {
            if isSending {
                try await Task.sleep(nanoseconds: 10_000_000)
                continue
            }
            await processNextBatch(drainAll: true)
        }
    }
    
    public func shutdown() async {
        isShuttingDown = true
        await writeTask?.value
        try? await flush()
    }
    
    public func getQuarantinedEvents() -> [TraceEventRow] {
        return quarantineQueue.flatMap { $0 }
    }
    
    private func tick() async {
        let sleepMs: UInt64 = 500
        await processNextBatch(maxBatch: 1000)
        try? await Task.sleep(nanoseconds: sleepMs * 1_000_000)
    }
    
    private func processNextBatch(drainAll: Bool = false, maxBatch: Int = 1000) async {
        guard !isSending else { return }
        isSending = true
        defer { isSending = false }
        
        let waitTime = await circuitBreaker.timeUntilAllowed()
        if waitTime > 0 {
            try? await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))
        }
        
        guard await circuitBreaker.allowRequest() else { return }
        
        let batch: [TraceEventRow]
        if let inflight = inflightBatch {
            batch = inflight
        } else {
            let drained = drainAll ? buffer.flushAll() : buffer.drain(max: maxBatch)
            guard !drained.isEmpty else { return }
            batch = drained
            inflightBatch = batch
            attemptCount = 0
        }
        
        let maxAttempts = 10
        let baseBackoff: Double = 1.0
        let maxBackoff: Double = 60.0
        
        while attemptCount < maxAttempts {
            do {
                let statusCode = try await sendBatch(batch)
                
                if statusCode == 400 {
                    print("🚨 [DProvenanceKit] Poison batch detected (400 Bad Request). Quarantining.")
                    quarantineQueue.append(batch)
                    inflightBatch = nil
                    attemptCount = 0
                    await circuitBreaker.recordSuccess()
                    return
                }
                
                inflightBatch = nil
                attemptCount = 0
                await circuitBreaker.recordSuccess()
                return
            } catch {
                attemptCount += 1
                await circuitBreaker.recordFailure()
                
                if attemptCount >= maxAttempts {
                    print("🚨 [DProvenanceKit] Batch failed \(maxAttempts) times. Quarantining.")
                    quarantineQueue.append(batch)
                    inflightBatch = nil
                    attemptCount = 0
                    return
                }
                
                guard await circuitBreaker.allowRequest() else {
                    return
                }
                
                if attemptCount == 1 {
                    let stagger = Double.random(in: 0.1...1.0)
                    try? await Task.sleep(nanoseconds: UInt64(stagger * 1_000_000_000))
                } else {
                    let cap = min(maxBackoff, baseBackoff * pow(2.0, Double(attemptCount)))
                    let sleepTime = Double.random(in: 0...cap)
                    try? await Task.sleep(nanoseconds: UInt64(sleepTime * 1_000_000_000))
                }
            }
        }
    }
    
    private func sendBatch(_ events: [TraceEventRow]) async throws -> Int {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let payload = events.map { event in
            [
                "id": event.id,
                "run_id": event.runID,
                "context_id": event.contextID,
                "priority": event.priority,
                "sequence": event.sequence,
                "engine": event.engine ?? NSNull(),
                "span_id": event.spanID ?? NSNull(),
                "parent_span_id": event.parentSpanID ?? NSNull(),
                "type": event.type,
                "payload": (try? JSONSerialization.jsonObject(with: event.payload)) ?? event.payload.base64EncodedString(),
                "timestamp": event.timestamp
            ] as [String : Any]
        }
        
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        
        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        
        if !(200...299).contains(httpResponse.statusCode) && httpResponse.statusCode != 400 {
            throw URLError(.badServerResponse)
        }
        
        return httpResponse.statusCode
    }
}
