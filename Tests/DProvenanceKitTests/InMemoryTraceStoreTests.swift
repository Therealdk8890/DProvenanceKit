import XCTest
@testable import DProvenanceKit
import Foundation

/// Thread-safe collector for live-engine match callbacks (which arrive off the
/// recording thread). `@unchecked Sendable` is justified: all state is lock-guarded.
private final class MatchBox: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [UUID] = []

    func add(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        ids.append(id)
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return ids.count
    }
}

/// A live subscription that records which runs matched, for test assertions.
private struct CapturingSubscription: TraceQuerySubscription {
    typealias T = TestEvent
    let queryID = UUID()
    let query: TraceQueryDSL<TestEvent>
    let box: MatchBox

    func onMatch(run: TraceRun<TestEvent>) { box.add(run.runID) }
    func onUpdate(run: TraceRun<TestEvent>) {}
}

final class InMemoryTraceStoreTests: XCTestCase {

    /// `record` commits synchronously, so an immediate query (no flush needed)
    /// must see every event in record order. With the previous `Task`-deferred
    /// append this was a scheduling race; now it is a structural guarantee.
    func testRecordIsImmediatelyQueryableInOrder() async throws {
        let store = InMemoryTraceStore<TestEvent>()
        let n = 500

        await DProvenanceKit<TestEvent>.run(contextID: "mem", store: store) {
            DProvenanceKit<TestEvent>.record(.processStarted)
            for j in 0..<(n - 2) {
                DProvenanceKit<TestEvent>.record(.stepCompleted(j))
            }
            DProvenanceKit<TestEvent>.record(.processFinished)
        }

        let runs = try await store.queryRuns(
            TraceQueryDSL<TestEvent>().filter(contextID: "mem")
        )
        XCTAssertEqual(runs.count, 1)

        let events = runs.first!.events
        XCTAssertEqual(events.count, n, "Every recorded event must be immediately queryable")

        let sequences = events.map { $0.sequence }
        XCTAssertEqual(sequences, Array(0..<UInt64(n)), "Events must be contiguous and in record order")
    }

    /// Concurrent runs must not interleave or lose events; each run stays intact.
    func testConcurrentRunsRemainConsistent() async throws {
        let store = InMemoryTraceStore<TestEvent>()

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask {
                    await DProvenanceKit<TestEvent>.run(contextID: "run_\(i)", store: store) {
                        DProvenanceKit<TestEvent>.record(.processStarted)
                        for j in 0..<8 {
                            DProvenanceKit<TestEvent>.record(.stepCompleted(j))
                        }
                        DProvenanceKit<TestEvent>.record(.processFinished)
                    }
                }
            }
        }

        let runs = try await store.queryRuns(
            TraceQueryDSL<TestEvent>().requiring(step: "processFinished")
        )
        XCTAssertEqual(runs.count, 50)
        let total = runs.reduce(0) { $0 + $1.events.count }
        XCTAssertEqual(total, 50 * 10, "No events should be lost or cross-attributed across runs")
        for run in runs {
            XCTAssertEqual(run.events.map { $0.sequence }, Array(0..<10), "Each run preserves its own order")
        }
    }

    /// The live engine receives events in order over the AsyncStream, so a query
    /// requiring the terminal event fires exactly one match per run.
    func testLiveEngineReceivesOrderedDelivery() async throws {
        let engine = LiveTraceQueryEngine<TestEvent>()
        let store = InMemoryTraceStore<TestEvent>(liveEngine: engine)
        let box = MatchBox()
        let sub = CapturingSubscription(
            query: TraceQueryDSL<TestEvent>().requiring(step: "processFinished"),
            box: box
        )
        await engine.register(sub)

        await DProvenanceKit<TestEvent>.run(contextID: "live", store: store) {
            DProvenanceKit<TestEvent>.record(.processStarted)
            DProvenanceKit<TestEvent>.record(.processFinished)
        }

        // Live delivery is asynchronous (ordered, but off-thread). Poll briefly.
        try await pollUntil(timeout: 2.0) { box.count == 1 }
        XCTAssertEqual(box.count, 1, "Terminal event should produce exactly one live match")
    }

    private func pollUntil(timeout: TimeInterval, _ condition: @Sendable () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000) // 5ms
        }
    }
}
