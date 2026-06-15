import Foundation

public protocol AnyActiveTraceRun: Sendable {
    func recordAny(_ payload: Any, engineName: String?)
    func flush() async throws
}

public enum TraceContext {
    @TaskLocal public static var currentRun: AnyActiveTraceRun?
    @TaskLocal public static var engineStack: [String] = []
    @TaskLocal public static var currentSpanID: String?
    @TaskLocal public static var parentSpanID: String?
}

public enum DProvenanceKit<T: TraceableEvent> {
    public final class ActiveTraceRun: @unchecked Sendable, AnyActiveTraceRun {
        public let runID: UUID
        public let contextID: String
        private let store: any TraceStore<T>
        private let schemaVersion: Int
        private let sequenceLock = NSLock()
        private var sequenceCounter: UInt64 = 0

        public init(contextID: String, store: any TraceStore<T>, schemaVersion: Int = 1) {
            self.runID = UUID()
            self.contextID = contextID
            self.store = store
            self.schemaVersion = schemaVersion
        }

        public func record(_ payload: T, engineName: String?) {
            sequenceLock.lock()
            let seq = sequenceCounter
            sequenceCounter += 1
            sequenceLock.unlock()
            
            let traceEvent = TraceEvent(
                runID: runID,
                contextID: contextID,
                engineName: engineName ?? "Unknown",
                schemaVersion: schemaVersion,
                sequence: seq,
                spanID: TraceContext.currentSpanID,
                parentSpanID: TraceContext.parentSpanID,
                payload: payload,
                timestamp: Date()
            )
            store.record(traceEvent)
        }
        
        public func recordAny(_ payload: Any, engineName: String?) {
            guard let typedPayload = payload as? T else { return }
            self.record(typedPayload, engineName: engineName)
        }
        
        public func flush() async throws {
            try await store.flush()
        }
    }

    public static func run<R>(
        contextID: String,
        store: any TraceStore<T>,
        schemaVersion: Int = 1,
        _ block: () async throws -> R
    ) async rethrows -> R {
        let run = ActiveTraceRun(contextID: contextID, store: store, schemaVersion: schemaVersion)
        return try await TraceContext.$currentRun.withValue(run) {
            try await block()
        }
    }

    public static func runSync<R>(
        contextID: String,
        store: any TraceStore<T>,
        schemaVersion: Int = 1,
        _ block: () throws -> R
    ) rethrows -> R {
        let run = ActiveTraceRun(contextID: contextID, store: store, schemaVersion: schemaVersion)
        return try TraceContext.$currentRun.withValue(run) {
            try block()
        }
    }

    public static func withEngine<R>(
        name: String,
        _ block: () async throws -> R
    ) async rethrows -> R {
        let newStack = TraceContext.engineStack + [name]
        return try await TraceContext.$engineStack.withValue(newStack) {
            try await block()
        }
    }

    public static func withEngineSync<R>(
        name: String,
        _ block: () throws -> R
    ) rethrows -> R {
        let newStack = TraceContext.engineStack + [name]
        return try TraceContext.$engineStack.withValue(newStack) {
            try block()
        }
    }

    public static func withSpan<R>(
        _ block: () async throws -> R
    ) async rethrows -> R {
        let newSpanID = UUID().uuidString
        let parent = TraceContext.currentSpanID
        return try await TraceContext.$currentSpanID.withValue(newSpanID) {
            try await TraceContext.$parentSpanID.withValue(parent) {
                try await block()
            }
        }
    }

    public static func withSpanSync<R>(
        _ block: () throws -> R
    ) rethrows -> R {
        let newSpanID = UUID().uuidString
        let parent = TraceContext.currentSpanID
        return try TraceContext.$currentSpanID.withValue(newSpanID) {
            try TraceContext.$parentSpanID.withValue(parent) {
                try block()
            }
        }
    }

    public static func record(_ payload: T) {
        guard let run = TraceContext.currentRun else {
            // Soft failure for executions outside of DProvenanceKit.run.
            return
        }
        run.recordAny(payload, engineName: TraceContext.engineStack.last)
    }
    
    public static func flush() async throws {
        guard let run = TraceContext.currentRun else { return }
        try await run.flush()
    }
}
