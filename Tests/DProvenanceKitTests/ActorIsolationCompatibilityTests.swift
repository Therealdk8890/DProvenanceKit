import XCTest
@testable import DProvenanceKit

/// Swift 6.2+ infers `@main` and UI-facing code onto the main actor. These
/// compile-time calls guard the public recording scopes against regressing to
/// a cross-executor API that forces consumers to add `@Sendable` manually.
final class ActorIsolationCompatibilityTests: XCTestCase {
    @MainActor
    func testAsyncScopesAcceptMainActorIsolatedClosures() async throws {
        let store = InMemoryTraceStore<TestEvent>()
        var checkpoints: [String] = []

        let (_, runID) = await DProvenanceKit<TestEvent>.runReturningID(
            contextID: "main-actor",
            store: store
        ) { _ in
            checkpoints.append("run")
            DProvenanceKit<TestEvent>.record(.processStarted)

            await DProvenanceKit<TestEvent>.withEngine(name: "MainActorEngine") {
                checkpoints.append("engine")
                await DProvenanceKit<TestEvent>.withSpan {
                    checkpoints.append("anonymous-span")
                    await DProvenanceKit<TestEvent>.withSpan(named: "MainActorSpan") {
                        checkpoints.append("named-span")
                        DProvenanceKit<TestEvent>.record(.processFinished)
                    }
                }
            }
        }

        await DProvenanceKit<TestEvent>.run(contextID: "plain-run", store: store) {
            checkpoints.append("plain-run")
        }

        XCTAssertEqual(checkpoints, ["run", "engine", "anonymous-span", "named-span", "plain-run"])
        let fetched = try await store.getRun(id: runID)
        let run = try XCTUnwrap(fetched)
        XCTAssertEqual(run.events.map(\.payload.typeIdentifier), ["processStarted", "processFinished"])
        XCTAssertEqual(run.events.last?.engineName, "MainActorEngine")
        XCTAssertEqual(run.events.last?.spanID, "MainActorSpan")
    }
}
