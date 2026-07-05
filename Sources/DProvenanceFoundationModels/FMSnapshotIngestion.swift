import Foundation
import DProvenanceKit

public struct FMIngestionSummary: Sendable, Equatable {
    public let eventCount: Int
    public let turnCount: Int
    public let toolCallCount: Int
    public let skippedSegmentCount: Int
    /// Resume cursor: pass as `startingAt` on the next ingestion of the same
    /// (grown) transcript to record only the delta.
    public let nextEntryIndex: Int
}

/// The ungated recording front door: maps a snapshot and records into the
/// ambient run, replaying each event's spanPath via nested
/// `withSpanSync(named:)` so spanID/parentSpanID reproduce the frozen grammar.
public enum FMSnapshotIngestion {
    /// Safe no-op outside a run: counts of what would have been recorded are
    /// 0 and `nextEntryIndex` is still accurate.
    @discardableResult
    public static func record(
        _ snapshot: FMTranscriptSnapshot,
        configuration: FMTracingConfiguration = .default,
        startingAt entryIndex: Int = 0
    ) -> FMIngestionSummary {
        record(snapshot, configuration: configuration, startingAt: entryIndex, skippedSegmentCount: 0)
    }

    @discardableResult
    static func record(
        _ snapshot: FMTranscriptSnapshot,
        configuration: FMTracingConfiguration,
        startingAt entryIndex: Int,
        skippedSegmentCount: Int
    ) -> FMIngestionSummary {
        let nextEntryIndex = snapshot.entries.count
        guard TraceContext.currentRun != nil else {
            return FMIngestionSummary(
                eventCount: 0, turnCount: 0, toolCallCount: 0,
                skippedSegmentCount: 0, nextEntryIndex: nextEntryIndex
            )
        }

        let start = min(max(entryIndex, 0), snapshot.entries.count)
        let startingTurnIndex = snapshot.entries[..<start].reduce(into: 0) {
            if case .prompt = $1 { $0 += 1 }
        }
        let mapper = FMSnapshotMapper(configuration: configuration)
        let mapped = mapper.map(snapshot, in: start..<snapshot.entries.count, startingTurnIndex: startingTurnIndex)

        var turnCount = 0
        var toolCallCount = 0
        configuration.withDefaultEngine {
            for item in mapped {
                switch item.payload {
                case .prompt: turnCount += 1
                case .toolCall: toolCallCount += 1
                default: break
                }
                replaySpans(item.spanPath[...]) {
                    configuration.recorder.record(item.payload)
                }
            }
        }

        return FMIngestionSummary(
            eventCount: mapped.count,
            turnCount: turnCount,
            toolCallCount: toolCallCount,
            skippedSegmentCount: skippedSegmentCount,
            nextEntryIndex: nextEntryIndex
        )
    }

    /// Re-enters span names outermost-first: identical strings produce
    /// identical spanID/parentSpanID pairs, which is the parity linchpin
    /// between this path and the live wrapper's capture context.
    static func replaySpans<R>(_ names: ArraySlice<String>, _ body: () -> R) -> R {
        guard let first = names.first else { return body() }
        return DProvenanceKit<FoundationModelTraceEvent>.withSpanSync(named: first) {
            replaySpans(names.dropFirst(), body)
        }
    }
}
