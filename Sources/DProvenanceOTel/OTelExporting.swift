import Foundation
import DProvenanceKit

/// What actually left the process — including what a collector admitted it
/// rejected. The receipt exists for honesty: a count that silently ignored
/// partial-success responses would report delivery that never happened.
public struct OTelExportReceipt: Sendable, Equatable {
    public let runsExported: Int
    /// Zero-event runs. The SQLite store returns one when every persisted event
    /// fails to decode as the payload type (`TraceRun.undecodedEventCount` carries
    /// the omission) — a nonzero count here is the export-side trace of that run.
    /// The in-memory store still cannot produce one.
    public let runsSkipped: Int
    /// Includes synthesized and GenAI-promoted spans.
    public let spanCount: Int
    public let spanEventCount: Int
    public let encodedBytes: Int
    public let traceIDsByRun: [UUID: String]
    /// From OTLP partialSuccess responses (0 / empty when none).
    public let rejectedSpans: Int64
    public let partialSuccessMessages: [String]

    init(runsExported: Int, runsSkipped: Int, spanCount: Int,
         spanEventCount: Int, encodedBytes: Int,
         traceIDsByRun: [UUID: String],
         rejectedSpans: Int64 = 0,
         partialSuccessMessages: [String] = []) {
        self.runsExported = runsExported
        self.runsSkipped = runsSkipped
        self.spanCount = spanCount
        self.spanEventCount = spanEventCount
        self.encodedBytes = encodedBytes
        self.traceIDsByRun = traceIDsByRun
        self.rejectedSpans = rejectedSpans
        self.partialSuccessMessages = partialSuccessMessages
    }
}

public enum OTelExportError: Error, Sendable, Equatable {
    case encodingFailed(description: String)
    case fileWriteFailed(path: String, description: String)
    case invalidEndpoint(String)
    /// `completed` = aggregate receipt of chunks already delivered before the
    /// failure (nil if none) — a mid-chunk failure must not throw away the
    /// fact that earlier chunks landed, or the caller re-sends them.
    case transport(description: String, completed: OTelExportReceipt?)
    case httpFailure(statusCode: Int, body: String?, completed: OTelExportReceipt?)
}

public protocol OTelTraceExporter<T>: Sendable {
    associatedtype T: TraceableEvent
    func export(_ runs: [TraceRun<T>]) async throws -> OTelExportReceipt

    /// Export with lineage edges surfaced on the target events' spans as
    /// `dpk.derived_from`. The default ignores edges, so existing conformers and the
    /// plain `export(_:)` path keep working with no lineage.
    func export(_ runs: [TraceRun<T>], lineageEdges: [TraceEdge]) async throws -> OTelExportReceipt
}

public extension OTelTraceExporter {
    func export(_ runs: [TraceRun<T>], lineageEdges: [TraceEdge]) async throws -> OTelExportReceipt {
        try await export(runs)
    }
}

/// Store-level convenience: query, order deterministically, export.
public enum DProvenanceOTelExport {
    /// Empty DSL matches every run (it compiles to `SELECT run_id FROM runs`;
    /// the in-memory `.and([])` evaluates true). Runs are sorted by
    /// (first-event timestamp, `runID.uuidString.lowercased()`) because
    /// `InMemoryTraceStore.queryRuns` returns unspecified order (it iterates
    /// a `Set`). `queryRuns` flushes internally for SQLite; no explicit flush
    /// is needed here.
    public static func export<Store: TraceStore, Exporter: OTelTraceExporter>(
        from store: Store,
        matching query: TraceQueryDSL<Store.T> = TraceQueryDSL(),
        using exporter: Exporter
    ) async throws -> OTelExportReceipt where Exporter.T == Store.T {
        var runs = try await store.queryRuns(query)
        runs.sort { a, b in
            let timeA = firstEventTimestamp(of: a)
            let timeB = firstEventTimestamp(of: b)
            if timeA != timeB { return timeA < timeB }
            return a.runID.uuidString.lowercased() < b.runID.uuidString.lowercased()
        }

        let lineageEdges = await directLineageEdges(from: store, runs: runs)
        return try await exporter.export(runs, lineageEdges: lineageEdges)
    }

    /// Direct lineage edges among the exported runs' events, canonically sorted.
    /// `lineageEdges(of:)` returns the full transitive closure, so we keep only edges
    /// whose TARGET is one of the exported events (direct parents). The per-event fetch
    /// is `try?` so a store that can't traverse (e.g. `CloudTraceStore` throws
    /// `notImplemented`) degrades to no lineage instead of failing the whole export.
    private static func directLineageEdges<Store: TraceStore>(
        from store: Store, runs: [TraceRun<Store.T>]
    ) async -> [TraceEdge] {
        let inBatchIDs = Set(runs.flatMap { $0.events.map(\.id) })
        guard !inBatchIDs.isEmpty else { return [] }

        var edges = Set<TraceEdge>()
        for id in inBatchIDs {
            guard let reachable = try? await store.lineageEdges(of: id) else { continue }
            for edge in reachable where inBatchIDs.contains(edge.targetID) {
                edges.insert(edge)
            }
        }
        return edges.sorted { a, b in
            if a.targetID != b.targetID {
                return a.targetID.uuidString.lowercased() < b.targetID.uuidString.lowercased()
            }
            if a.sourceID != b.sourceID {
                return a.sourceID.uuidString.lowercased() < b.sourceID.uuidString.lowercased()
            }
            return a.type.rawValue < b.type.rawValue
        }
    }

    /// "First event" by the causal clock, not array position — hand-assembled
    /// runs are not guaranteed to arrive sequence-sorted.
    private static func firstEventTimestamp<T>(of run: TraceRun<T>) -> Date {
        run.events.min { $0.sequence < $1.sequence }?.timestamp ?? .distantPast
    }
}
