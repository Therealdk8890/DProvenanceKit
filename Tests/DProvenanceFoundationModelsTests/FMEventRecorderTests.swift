import XCTest
import DProvenanceKit
@testable import DProvenanceFoundationModels

/// An unrelated host vocabulary, to pin that automatic routing records
/// nothing into runs it does not understand.
private enum UnrelatedEvent: String, TraceableEvent {
    case something
    var typeIdentifier: String { rawValue }
    var priority: TracePriority { .critical }
}

/// A host vocabulary that embeds FM events as its own payloads.
private struct HostEvent: FoundationModelEventEmbedding {
    let foundationModelEvent: FoundationModelTraceEvent
    init(foundationModelEvent: FoundationModelTraceEvent) {
        self.foundationModelEvent = foundationModelEvent
    }
    var typeIdentifier: String { "host_\(foundationModelEvent.typeIdentifier)" }
    var priority: TracePriority { foundationModelEvent.priority }
}

final class FMEventRecorderTests: XCTestCase {
    private let sample = FoundationModelTraceEvent.response(
        FMResponsePayload(content: FMRedactedText("Sunny.", redaction: .full), turnIndex: 0)
    )

    func testDirectRecordsTypedWithDefaultEngine() async throws {
        let events = try await TestSupport.recordedFMEvents {
            FMEventRecorder.direct.record(sample)
        }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].payload, sample)
        XCTAssertEqual(events[0].engineName, "FoundationModels")
    }

    func testCallerEstablishedEngineIsRespected() async throws {
        let events = try await TestSupport.recordedFMEvents {
            DProvenanceKit<FoundationModelTraceEvent>.withEngineSync(name: "CallerEngine") {
                FMEventRecorder.direct.record(sample)
            }
        }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].engineName, "CallerEngine")
    }

    func testTypeErasedRecordsWithDeterministicRawJSON() async throws {
        let store = InMemoryTraceStore<AnyTraceableEvent>()
        DProvenanceKit<AnyTraceableEvent>.runSync(contextID: "erased", store: store) {
            FMEventRecorder.typeErased.record(sample)
            FMEventRecorder.typeErased.record(sample)
        }
        let events = try await TestSupport.events(in: store, contextID: "erased")
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].payload.typeIdentifier, "fm_response")
        XCTAssertEqual(events[0].payload.priorityValue, TracePriority.critical.rawValue)
        XCTAssertEqual(events[0].payload.rawJSON, events[1].payload.rawJSON)
        let decoded = try JSONDecoder().decode(
            FoundationModelTraceEvent.self, from: Data(events[0].payload.rawJSON.utf8)
        )
        XCTAssertEqual(decoded, sample)
    }

    /// Pins core's recordAny guarded-cast contract: automatic fires both
    /// routes but exactly one lands per run type. Fails loudly if core changes.
    func testAutomaticRecordsExactlyOneCopyInTypedRun() async throws {
        let events = try await TestSupport.recordedFMEvents {
            FMEventRecorder.automatic.record(sample)
        }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].payload, sample)
    }

    func testAutomaticRecordsExactlyOneCopyInErasedRun() async throws {
        let store = InMemoryTraceStore<AnyTraceableEvent>()
        DProvenanceKit<AnyTraceableEvent>.runSync(contextID: "erased-auto", store: store) {
            FMEventRecorder.automatic.record(sample)
        }
        let events = try await TestSupport.events(in: store, contextID: "erased-auto")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].payload.typeIdentifier, "fm_response")
    }

    func testAutomaticRecordsNothingInUnrelatedRun() async throws {
        let store = InMemoryTraceStore<UnrelatedEvent>()
        DProvenanceKit<UnrelatedEvent>.runSync(contextID: "unrelated", store: store) {
            FMEventRecorder.automatic.record(sample)
        }
        let events = try await TestSupport.events(in: store, contextID: "unrelated")
        XCTAssertTrue(events.isEmpty)
    }

    func testEmbeddingLandsAsWrappedCase() async throws {
        let store = InMemoryTraceStore<HostEvent>()
        DProvenanceKit<HostEvent>.runSync(contextID: "host", store: store) {
            FMEventRecorder.embedding(HostEvent.self).record(sample)
        }
        let events = try await TestSupport.events(in: store, contextID: "host")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].payload.typeIdentifier, "host_fm_response")
        XCTAssertEqual(events[0].payload.foundationModelEvent, sample)
    }

    func testBuiltInRoutesNoOpOutsideARun() {
        FMEventRecorder.direct.record(sample)
        FMEventRecorder.typeErased.record(sample)
        FMEventRecorder.automatic.record(sample)
        FMEventRecorder.embedding(HostEvent.self).record(sample)
    }

    /// Custom routes are caller-owned: the closure fires even outside a run
    /// (only core recording no-ops), so custom sinks decide for themselves.
    func testCustomRouteStillFiresOutsideARun() {
        nonisolated(unsafe) var fired = false
        FMEventRecorder { _ in fired = true }.record(sample)
        XCTAssertTrue(fired)
    }
}
