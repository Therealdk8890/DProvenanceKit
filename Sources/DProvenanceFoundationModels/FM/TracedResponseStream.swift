#if canImport(FoundationModels)
import Foundation
import Synchronization
import FoundationModels
import DProvenanceKit

/// Yields Apple's Snapshot values untouched (cumulative partials).
/// Deliberately non-Sendable, mirroring ResponseStream; transferred once via
/// `sending`.
///
/// On natural completion or `collect()` the turn is reconciled from the
/// transcript delta (recording fm_response). On a thrown error an
/// fm_generation_error is recorded and the error rethrown unchanged.
/// Abandoned iteration records nothing (no deinit side effects) —
/// `session.recordProvenance()` backfills; that is the documented recovery.
/// fm_stream_snapshot telemetry follows `configuration.streamSnapshots`.
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
public struct TracedResponseStream<Content: Generable>: AsyncSequence {
    public typealias Element = LanguageModelSession.ResponseStream<Content>.Snapshot
    public typealias Failure = any Error

    let base: LanguageModelSession.ResponseStream<Content>
    let coordinator: FMStreamTurnCoordinator

    public struct AsyncIterator: AsyncIteratorProtocol {
        public typealias Element = LanguageModelSession.ResponseStream<Content>.Snapshot
        public typealias Failure = any Error

        var baseIterator: LanguageModelSession.ResponseStream<Content>.AsyncIterator
        let coordinator: FMStreamTurnCoordinator
        var snapshotOrdinal = 0

        /// Matches FM's iterator shape: `next(isolation:)` inherits the
        /// caller's isolation, avoiding strict-concurrency friction with the
        /// non-Sendable Element.
        public mutating func next(isolation: isolated (any Actor)?) async throws(any Error) -> Element? {
            do {
                guard let snapshot = try await baseIterator.next(isolation: isolation) else {
                    coordinator.finish()
                    return nil
                }
                coordinator.recordSnapshotTelemetry(
                    ordinal: snapshotOrdinal,
                    contentUTF8Count: snapshot.rawContent.jsonString.utf8.count
                )
                snapshotOrdinal += 1
                return snapshot
            } catch {
                coordinator.fail(error)
                throw error
            }
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(baseIterator: base.makeAsyncIterator(), coordinator: coordinator)
    }

    nonisolated(nonsending) public func collect() async throws -> sending LanguageModelSession.Response<Content> {
        do {
            let response = try await base.collect()
            coordinator.finish()
            return response
        } catch {
            coordinator.fail(error)
            throw error
        }
    }
}

/// Reconciles a streamed turn exactly once, whether it ends via iterator
/// exhaustion, `collect()`, or a thrown error. A class so the stream, its
/// copies, and every iterator share one claim flag.
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
final class FMStreamTurnCoordinator: Sendable {
    private let session: TracedLanguageModelSession
    private let turnIndex: Int
    private let turnSpanName: String
    private let transcriptStartIndex: Int
    private let reconciled = Mutex(false)

    init(session: TracedLanguageModelSession, turnIndex: Int, turnSpanName: String, transcriptStartIndex: Int) {
        self.session = session
        self.turnIndex = turnIndex
        self.turnSpanName = turnSpanName
        self.transcriptStartIndex = transcriptStartIndex
    }

    func finish() {
        guard claim() else { return }
        session.reconcileStreamTurn(transcriptStartIndex: transcriptStartIndex, turnIndex: turnIndex)
    }

    func fail(_ error: any Error) {
        guard claim() else { return }
        session.recordStreamFailure(
            error, turnIndex: turnIndex,
            turnSpanName: turnSpanName, transcriptStartIndex: transcriptStartIndex
        )
    }

    func recordSnapshotTelemetry(ordinal: Int, contentUTF8Count: Int) {
        switch session.configuration.streamSnapshots {
        case .off:
            return
        case .everySnapshot:
            break
        case .sampled(let everyNth):
            guard everyNth > 0, ordinal % everyNth == 0 else { return }
        }
        session.context.record(
            .streamSnapshot(FMStreamSnapshotPayload(
                snapshotIndex: ordinal, contentUTF8Count: contentUTF8Count, turnIndex: turnIndex
            )),
            spanPath: [turnSpanName]
        )
    }

    private func claim() -> Bool {
        reconciled.withLock { done in
            guard !done else { return false }
            done = true
            return true
        }
    }
}
#endif
