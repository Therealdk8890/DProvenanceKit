import XCTest
@testable import DProvenanceKit
import Foundation

final class TraceWriteBufferTests: XCTestCase {

    private func makeRow(runID: String, seq: Int64, priority: TracePriority) -> TraceEventRow {
        TraceEventRow(
            id: UUID().uuidString,
            runID: runID,
            contextID: runID,
            priority: priority.rawValue,
            sequence: seq,
            engine: "E",
            spanID: nil,
            parentSpanID: nil,
            type: priority == .critical ? "critical" : "telemetry",
            payload: Data(),
            timestamp: seq
        )
    }

    /// Drained events come back in global insertion order regardless of priority tier,
    /// so the writer's streaming fingerprint stays computed in record order.
    func testDrainPreservesGlobalInsertionOrder() {
        let buffer = TraceWriteBuffer(maxGlobalBuffer: 10_000, maxPerRunBuffer: 10_000)
        let priorities: [TracePriority] = [.telemetry, .critical, .structural, .diagnostic]
        for i in 0..<200 {
            buffer.enqueue(makeRow(runID: "r", seq: Int64(i), priority: priorities[i % priorities.count]))
        }

        let drained = buffer.flushAll()
        XCTAssertEqual(drained.count, 200)
        XCTAssertEqual(drained.map { $0.sequence }, Array(0..<200).map(Int64.init),
                       "Events must drain in insertion order across all priority tiers")
        XCTAssertEqual(buffer.currentDepth, 0)
    }

    /// Sustained over-capacity ingestion must stay fast (O(1) per event, not O(n)) and
    /// must never drop a critical event while telemetry is available to shed.
    /// Under the old O(n) scan-and-shift eviction, 200k enqueues at a 20k-deep buffer
    /// would be ~hundreds of millions to billions of ops; here it is linear.
    func testHeavyBurstShedsTelemetryButKeepsCritical() {
        let cap = 20_000
        let buffer = TraceWriteBuffer(maxGlobalBuffer: cap, maxPerRunBuffer: Int.max)

        let total = 200_000
        let criticalEvery = 1_000
        var criticalsEnqueued = 0
        for i in 0..<total {
            let isCritical = (i % criticalEvery == 0)
            if isCritical { criticalsEnqueued += 1 }
            buffer.enqueue(makeRow(runID: "rogue", seq: Int64(i),
                                   priority: isCritical ? .critical : .telemetry))
        }

        // Buffer never exceeds its global cap.
        XCTAssertLessThanOrEqual(buffer.currentDepth, cap)

        let drained = buffer.flushAll()
        XCTAssertLessThanOrEqual(drained.count, cap)

        // Every critical event survives — they are only ever displaced when nothing
        // cheaper exists, and here telemetry is always available to shed.
        let survivingCriticals = drained.filter { $0.type == "critical" }.count
        XCTAssertEqual(survivingCriticals, criticalsEnqueued,
                       "Critical events must never be dropped while telemetry can be shed")
    }

    /// The per-run soft cap sheds verbose events for a bursting run while still
    /// admitting its critical events.
    func testPerRunSoftCapKeepsCriticalEvents() {
        let buffer = TraceWriteBuffer(maxGlobalBuffer: 100_000, maxPerRunBuffer: 50)

        buffer.enqueue(makeRow(runID: "run", seq: 0, priority: .critical))
        for i in 1...500 {
            buffer.enqueue(makeRow(runID: "run", seq: Int64(i), priority: .telemetry))
        }
        buffer.enqueue(makeRow(runID: "run", seq: 501, priority: .critical))

        let drained = buffer.flushAll()
        let criticals = drained.filter { $0.type == "critical" }.count
        XCTAssertEqual(criticals, 2, "Both critical events bypass the per-run telemetry cap")
        XCTAssertLessThan(drained.count, 502, "Telemetry beyond the per-run cap is shed")
    }
}
