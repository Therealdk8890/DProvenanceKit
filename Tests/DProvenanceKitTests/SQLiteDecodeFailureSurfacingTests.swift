import XCTest
@testable import DProvenanceKit
import Foundation

/// The payload schema as originally shipped: both variants encode and decode.
private struct WidePayload: TraceableEvent {
    let kind: String

    var typeIdentifier: String { "drift" }
    var priority: TracePriority { .structural }
}

/// The payload schema after drift: rows persisted as `legacy` no longer decode.
/// Reading a `WidePayload` store through this type models a consumer that renamed
/// or removed a case between releases — the classic trigger for undecodable rows.
private struct StrictPayload: TraceableEvent {
    let kind: String

    var typeIdentifier: String { "drift" }
    var priority: TracePriority { .structural }

    init(kind: String) { self.kind = kind }

    private enum CodingKeys: String, CodingKey { case kind }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        guard kind == "stable" else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container,
                debugDescription: "legacy variant no longer supported"
            )
        }
        self.kind = kind
    }
}

/// Regression coverage for the read-side silent-drop site: a persisted row whose
/// payload no longer decodes as `T` used to be skipped without a trace, and a run
/// whose rows ALL failed to decode vanished from `getRun`/`queryRuns` entirely —
/// while its rows sat intact on disk. The miss is now surfaced per run as
/// `TraceRun.undecodedEventCount`, and a fully-undecodable run stays visible.
final class SQLiteDecodeFailureSurfacingTests: XCTestCase {
    var storeURL: URL!

    override func setUp() async throws {
        storeURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: storeURL)
    }

    private func record(_ kinds: [String], runID: UUID) async throws {
        let store = try SQLiteTraceStore<WidePayload>(fileURL: storeURL)
        for (index, kind) in kinds.enumerated() {
            store.record(TraceEvent(
                runID: runID, contextID: "ctx", engineName: "engine",
                schemaVersion: 1, sequence: UInt64(index + 1), spanID: nil, parentSpanID: nil,
                payload: WidePayload(kind: kind)
            ))
        }
        await store.close()
    }

    func testPartialDecodeFailureIsCountedOnTheRun() async throws {
        let runID = UUID()
        try await record(["stable", "legacy", "stable"], runID: runID)

        let strict = try SQLiteTraceStore<StrictPayload>(fileURL: storeURL)
        let run = try await strict.getRun(id: runID)

        let unwrapped = try XCTUnwrap(run, "a partially-decodable run must be returned")
        XCTAssertEqual(unwrapped.events.count, 2, "the decodable events must survive")
        XCTAssertEqual(
            unwrapped.undecodedEventCount, 1,
            "the undecodable row must be counted, not silently omitted"
        )
        XCTAssertTrue(unwrapped.events.allSatisfy { $0.payload.kind == "stable" })
        await strict.close()
    }

    func testFullyUndecodableRunStaysVisibleWithHonestCount() async throws {
        let runID = UUID()
        try await record(["legacy", "legacy"], runID: runID)

        let strict = try SQLiteTraceStore<StrictPayload>(fileURL: storeURL)

        // getRun: the run used to return nil here — indistinguishable from "never
        // recorded" — while both rows sat on disk.
        let run = try await strict.getRun(id: runID)
        let unwrapped = try XCTUnwrap(
            run,
            "a run whose events all fail to decode must stay visible, not vanish"
        )
        XCTAssertTrue(unwrapped.events.isEmpty)
        XCTAssertEqual(unwrapped.undecodedEventCount, 2)

        // queryRuns: structural predicates run in SQL over the persisted rows, so the
        // run must surface there too, carrying the same honest count.
        let matches = try await strict.queryRuns(
            TraceQueryDSL<StrictPayload>().requiring(step: "drift")
        )
        XCTAssertEqual(matches.count, 1, "the run must not vanish from queryRuns")
        XCTAssertEqual(matches.first?.undecodedEventCount, 2)

        // A run that genuinely doesn't exist still reads as nil — visibility of
        // undecodable runs must not blur the "never recorded" signal.
        let missing = try await strict.getRun(id: UUID())
        XCTAssertNil(missing)
        await strict.close()
    }

    func testCleanRunReadsBackWithZeroUndecodedCount() async throws {
        let runID = UUID()
        try await record(["stable", "stable"], runID: runID)

        let wide = try SQLiteTraceStore<WidePayload>(fileURL: storeURL)
        let run = try await wide.getRun(id: runID)

        let unwrapped = try XCTUnwrap(run)
        XCTAssertEqual(unwrapped.events.count, 2)
        XCTAssertEqual(unwrapped.undecodedEventCount, 0)
        await wide.close()
    }

    func testNegatedPayloadQueryDoesNotClearAnUninspectableRun() async throws {
        // A run whose payloads can't be read must not positively match "runs with NO
        // low-score event" — evaluating the negation over zero decodable events would
        // assert cleanliness that was never inspected. Structural queries still surface
        // the run (previous test); payload queries must exclude it in both polarities.
        let runID = UUID()
        try await record(["legacy", "legacy"], runID: runID)

        let strict = try SQLiteTraceStore<StrictPayload>(fileURL: storeURL)

        let lowScore = TraceQueryDSL<StrictPayload>().matching { $0.kind == "poison" }
        let clean = try await strict.queryRuns(TraceQueryDSL<StrictPayload>().excluding(lowScore))
        XCTAssertTrue(
            clean.isEmpty,
            "an uninspectable run must not be asserted clean by a negated payload query"
        )

        let matching = try await strict.queryRuns(lowScore)
        XCTAssertTrue(matching.isEmpty, "nor can it positively match a payload query")
        await strict.close()
    }

    func testUndecodedRunCannotBeAttested() async throws {
        // Signing a run whose events are a subset of what was recorded would mint a
        // cryptographically valid attestation over that subset. The signing boundary
        // must refuse while undecodedEventCount > 0.
        let runID = UUID()
        try await record(["stable", "legacy"], runID: runID)

        let strict = try SQLiteTraceStore<StrictPayload>(fileURL: storeURL)
        let fetched = try await strict.getRun(id: runID)
        let run = try XCTUnwrap(fetched)
        XCTAssertEqual(run.undecodedEventCount, 1, "precondition: one event is unreadable")

        XCTAssertThrowsError(try AttestableTrace(run: run)) { error in
            XCTAssertEqual(
                error as? TraceAttestationError,
                .undecodedEvents(count: 1),
                "attestation must name the omission, not shed it"
            )
        }

        // A fully-decodable run still attests.
        let cleanRunID = UUID()
        try await record(["stable"], runID: cleanRunID)
        let reopened = try SQLiteTraceStore<StrictPayload>(fileURL: storeURL)
        let cleanFetched = try await reopened.getRun(id: cleanRunID)
        let cleanRun = try XCTUnwrap(cleanFetched)
        XCTAssertNoThrow(try AttestableTrace(run: cleanRun))
        await strict.close()
        await reopened.close()
    }

    func testGetEventsOmitsUndecodableRowsWithoutFabricating() async throws {
        let runID = UUID()
        // Recover the persisted event ids through the raw store, which is schema-blind.
        try await record(["stable", "legacy"], runID: runID)
        let raw = try RawTraceStore(fileURL: storeURL)
        let rawRun = try await raw.fetchAllRuns().first { $0.runID == runID }
        let ids = Set(try XCTUnwrap(rawRun).events.map(\.id))
        XCTAssertEqual(ids.count, 2, "precondition: both rows persisted")

        let strict = try SQLiteTraceStore<StrictPayload>(fileURL: storeURL)
        let fetched = try await strict.getEvents(ids: ids)

        XCTAssertEqual(fetched.count, 1, "only the decodable event can be returned as StrictPayload")
        XCTAssertEqual(fetched.values.first?.payload.kind, "stable")
        await strict.close()
    }
}
