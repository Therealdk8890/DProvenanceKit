import XCTest
@testable import DProvenanceKit
import Foundation

/// A payload whose `priority` is configurable and whose encoding always fails,
/// to exercise the store's encode-failure accounting deterministically.
private struct UnencodablePayload: TraceableEvent {
    let tierRaw: Int

    var typeIdentifier: String { "unencodable" }
    var priority: TracePriority { TracePriority(rawValue: tierRaw) ?? .telemetry }

    init(tier: TracePriority) { self.tierRaw = tier.rawValue }

    func encode(to encoder: Encoder) throws {
        throw EncodingError.invalidValue(
            tierRaw,
            EncodingError.Context(codingPath: [], debugDescription: "deliberately unencodable payload")
        )
    }

    init(from decoder: Decoder) throws { self.tierRaw = TracePriority.telemetry.rawValue }
}

/// Regression coverage for the fourth, previously-silent drop site: a payload that
/// fails to JSON-encode in `SQLiteTraceStore.record` used to `return` and vanish,
/// uncounted by `dropStats`. It is now tallied in the failed event's own tier, so an
/// encode failure on a structural/critical event breaks `preservedIntegrity` exactly
/// like a congestion drop does.
final class SQLiteEncodeDropTests: XCTestCase {
    var storeURL: URL!
    private var store: SQLiteTraceStore<UnencodablePayload>!

    override func setUp() async throws {
        storeURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        store = try SQLiteTraceStore(fileURL: storeURL)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: storeURL)
    }

    private func event(_ tier: TracePriority) -> TraceEvent<UnencodablePayload> {
        TraceEvent(
            runID: UUID(), contextID: "ctx", engineName: "engine",
            schemaVersion: 1, sequence: 0, spanID: nil, parentSpanID: nil,
            payload: UnencodablePayload(tier: tier)
        )
    }

    func testEncodeFailureIsCountedNotSilentlyDropped() {
        XCTAssertEqual(store.dropStats.total, 0)
        XCTAssertTrue(store.dropStats.preservedIntegrity)

        store.record(event(.structural))

        // The event cannot be persisted, but it must be visible as a drop in its tier.
        XCTAssertEqual(store.dropStats.structural, 1)
        XCTAssertEqual(store.dropStats.total, 1)
        XCTAssertFalse(
            store.dropStats.preservedIntegrity,
            "a structural event lost to an encode failure must break integrity"
        )
    }

    func testTelemetryEncodeFailureIsCountedButKeepsIntegrity() {
        store.record(event(.telemetry))
        store.record(event(.telemetry))

        XCTAssertEqual(store.dropStats.telemetry, 2)
        XCTAssertTrue(
            store.dropStats.preservedIntegrity,
            "shedding only telemetry — even to encode failures — leaves diffs trustworthy"
        )
    }

    func testEncodeDropsTallyPerTier() {
        store.record(event(.telemetry))
        store.record(event(.diagnostic))
        store.record(event(.critical))

        let stats = store.dropStats
        XCTAssertEqual(stats.telemetry, 1)
        XCTAssertEqual(stats.diagnostic, 1)
        XCTAssertEqual(stats.critical, 1)
        XCTAssertEqual(stats.total, 3)
        XCTAssertFalse(stats.preservedIntegrity, "a critical event was lost")
    }
}
