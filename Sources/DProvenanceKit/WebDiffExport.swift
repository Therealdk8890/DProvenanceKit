import Foundation

/// A serializable, viewer-ready projection of a run comparison — the exact JSON shape the
/// bundled WebVisualizer (`WebVisualizer/mockDiffs.json`, see `WebVisualizer/SCHEMA.md`)
/// consumes. It folds a `TraceAlignmentResult` into summary/metric/timeline context plus a
/// single color-coded reasoning tree.
///
/// The alignment is a superset of the structural diff — its per-event `state` already encodes
/// `added` / `removed` (structural) *and* `changed` / `unchanged` (semantic), so this export is
/// built from the alignment alone. Node kinds map as:
///
/// | `AlignmentState`                         | node `type` |
/// |------------------------------------------|-------------|
/// | `.exactMatch`                            | `unchanged` |
/// | `.semanticMatch` / `.reordered` / `.ambiguous` | `changed` |
/// | `.added`                                 | `added`     |
/// | `.removed`                               | `removed`   |
///
/// The v1 tree is flat (`root → one node per aligned event`, in alignment order), which is the
/// honest shape of what the engines compute — they operate on filtered event *sequences*, not a
/// span hierarchy. Nesting by `TraceEvent.spanID`/`parentSpanID` is a documented follow-up.
///
/// Output is deterministic: node ids are positional, dates format in a fixed time zone, and
/// `jsonData()` encodes with sorted keys — so the same comparison always yields identical bytes.
public struct WebDiffExport: Codable, Sendable, Equatable {

    public struct Summary: Codable, Sendable, Equatable {
        /// Display-formatted count of runs behind this comparison (e.g. `"2"` or `"2,847"`).
        public let runs: String
        /// Capitalized `RegressionRisk.Level` — `"None"` | `"Low"` | `"Medium"` | `"High"`.
        public let regressionRisk: String
        /// Root→leaf paths touched by a change (flat tree: added + removed + changed leaves).
        public let changedLogicPaths: Int
        /// Short, deterministic hash of the comparison run's structural signature.
        public let structuralFingerprint: String
    }

    public struct Metrics: Codable, Sendable, Equatable {
        /// 0–100; `0` = identical. `round(100 * (added+removed+changed) / total)`.
        public let driftScore: Int
        public let addedNodes: Int
        public let removedNodes: Int
        public let changedPaths: Int
        /// Fallback for `Summary.regressionRisk` (same value).
        public let risk: String
    }

    public struct Timeline: Codable, Sendable, Equatable {
        public struct Run: Codable, Sendable, Equatable {
            public let label: String
            public let date: String
        }
        public let runA: Run
        public let runB: Run
    }

    /// One reasoning step. `details` is present only for `changed` nodes; `children` is omitted
    /// for leaves. (A struct recurses fine through `[Node]?` — no `indirect` needed.)
    public struct Node: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable, Equatable {
            case added, removed, changed, unchanged
        }
        public struct Details: Codable, Sendable, Equatable {
            public let runA: String
            public let runB: String
        }
        public let id: String
        public let label: String
        public let type: Kind
        public let details: Details?
        public let children: [Node]?

        public init(id: String, label: String, type: Kind, details: Details? = nil, children: [Node]? = nil) {
            self.id = id
            self.label = label
            self.type = type
            self.details = details
            self.children = children
        }
    }

    public let summary: Summary
    public let metrics: Metrics
    public let timeline: Timeline
    public let tree: Node

    public init(summary: Summary, metrics: Metrics, timeline: Timeline, tree: Node) {
        self.summary = summary
        self.metrics = metrics
        self.timeline = timeline
        self.tree = tree
    }

    /// Deterministic JSON (sorted keys). Feed the bytes straight to the WebVisualizer uploader.
    public func jsonData(prettyPrinted: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        // `.withoutEscapingSlashes` pins slash handling: Apple's JSONEncoder escapes `/` as `\/`
        // while swift-corelibs-foundation (Linux) emits a bare `/`. Without it, a label/detail
        // containing `/` would encode to different bytes per platform, breaking byte-identity.
        let base: JSONEncoder.OutputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.outputFormatting = prettyPrinted ? base.union(.prettyPrinted) : base
        return try encoder.encode(self)
    }
}

public extension WebDiffExport {

    /// Build the export from an existing alignment result.
    ///
    /// - Parameters:
    ///   - baseLabel/comparisonLabel: timeline labels (default `"Run A"` / `"Run B"`).
    ///   - corpusRuns: display count for `summary.runs`; `nil` → `2` (this base + comparison).
    ///   - timeZone: time zone for the formatted timeline dates (default UTC, for determinism).
    ///   - rootLabel: label for the synthetic tree root; `nil` → the comparison run's contextID.
    static func make<T: TraceableEvent>(
        base: TraceRun<T>,
        comparison: TraceRun<T>,
        alignment: TraceAlignmentResult<T>,
        baseLabel: String = "Run A",
        comparisonLabel: String = "Run B",
        corpusRuns: Int? = nil,
        timeZone: TimeZone = TimeZone(identifier: "UTC") ?? .current,
        rootLabel: String? = nil
    ) -> WebDiffExport {

        // Fold each alignment into a node. Ids are positional so output stays deterministic.
        var children: [Node] = []
        var added = 0, removed = 0, changed = 0, unchanged = 0
        for (i, a) in alignment.alignments.enumerated() {
            guard let node = node(from: a, index: i) else { continue }
            switch node.type {
            case .added: added += 1
            case .removed: removed += 1
            case .changed: changed += 1
            case .unchanged: unchanged += 1
            }
            children.append(node)
        }

        let total = added + removed + changed + unchanged
        let touched = added + removed + changed
        let drift = total == 0 ? 0 : Int((Double(touched) / Double(total) * 100).rounded())
        let riskText = alignment.regressionRisk.level.rawValue.capitalized

        let root = Node(
            id: "root",
            label: (rootLabel ?? comparison.contextID).isEmpty ? "Reasoning Engine" : (rootLabel ?? comparison.contextID),
            type: touched == 0 ? .unchanged : .changed,
            details: nil,
            children: children
        )

        return WebDiffExport(
            summary: Summary(
                runs: grouped(corpusRuns ?? 2),
                regressionRisk: riskText,
                changedLogicPaths: touched,
                structuralFingerprint: fingerprint(of: comparison)
            ),
            metrics: Metrics(
                driftScore: drift,
                addedNodes: added,
                removedNodes: removed,
                changedPaths: touched,
                risk: riskText
            ),
            timeline: Timeline(
                runA: Timeline.Run(label: baseLabel, date: formattedDate(of: base, timeZone: timeZone)),
                runB: Timeline.Run(label: comparisonLabel, date: formattedDate(of: comparison, timeZone: timeZone))
            ),
            tree: root
        )
    }

    /// Convenience: run the alignment engine, then build the export.
    static func make<T: TraceableEvent>(
        base: TraceRun<T>,
        comparison: TraceRun<T>,
        configuration: AlignmentConfiguration<T>,
        minimumPriority: TracePriority = .structural,
        baseLabel: String = "Run A",
        comparisonLabel: String = "Run B",
        corpusRuns: Int? = nil,
        timeZone: TimeZone = TimeZone(identifier: "UTC") ?? .current,
        rootLabel: String? = nil
    ) -> WebDiffExport {
        let alignment = TraceAlignmentEngine(configuration: configuration)
            .align(base: base, comparison: comparison, minimumPriority: minimumPriority)
        return make(
            base: base, comparison: comparison, alignment: alignment,
            baseLabel: baseLabel, comparisonLabel: comparisonLabel,
            corpusRuns: corpusRuns, timeZone: timeZone, rootLabel: rootLabel
        )
    }
}

// MARK: - Mapping helpers

private extension WebDiffExport {

    static func node<T: TraceableEvent>(from a: EventAlignment<T>, index: Int) -> Node? {
        let id = "node-\(index + 1)"
        let baseType = a.baseEvent?.payload.typeIdentifier
        let compType = a.comparisonEvent?.payload.typeIdentifier
        // Prefer the comparison ("current") label; fall back to the base for removals.
        let label = compType ?? baseType ?? "—"

        switch a.state {
        case .exactMatch:
            return Node(id: id, label: label, type: .unchanged)

        case .added:
            return Node(id: id, label: label, type: .added)

        case .removed:
            return Node(id: id, label: baseType ?? "—", type: .removed)

        case .semanticMatch:
            // A genuine label change carries a before→after; a same-type semantic drift does not.
            let details: Node.Details?
            if let baseType, let compType, baseType != compType {
                details = Node.Details(runA: baseType, runB: compType)
            } else {
                details = nil
            }
            return Node(id: id, label: label, type: .changed, details: details)

        case let .reordered(originalSequence, newSequence):
            return Node(
                id: id, label: label, type: .changed,
                details: Node.Details(runA: "step \(originalSequence)", runB: "step \(newSequence)")
            )

        case let .ambiguous(optionsCount):
            return Node(
                id: id, label: label, type: .changed,
                details: Node.Details(runA: baseType ?? "—", runB: "\(optionsCount) candidates")
            )
        }
    }

    /// The earliest event timestamp of a run, formatted in a fixed style; `""` if the run is empty.
    static func formattedDate<T: TraceableEvent>(of run: TraceRun<T>, timeZone: TimeZone) -> String {
        guard let earliest = run.events.map(\.timestamp).min() else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "MMM d, HH:mm"
        return f.string(from: earliest)
    }

    /// Deterministic, dependency-free 64-bit FNV-1a over the comparison's structural signature,
    /// rendered as `XXXX...XXXX`.
    static func fingerprint<T: TraceableEvent>(of run: TraceRun<T>) -> String {
        let signature = run.events
            .map { "\($0.payload.typeIdentifier)::\($0.engineName)" }
            .joined(separator: "|")
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in signature.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        // Zero-padded 16-char uppercase hex. Built without `String(format:)` — the C `%X`
        // specifier is 32-bit `unsigned int`, so it would misread a UInt64.
        let raw = String(hash, radix: 16, uppercase: true)
        let hex = String(repeating: "0", count: 16 - raw.count) + raw
        return "\(hex.prefix(4))...\(hex.suffix(4))"
    }

    /// Thousands-separated decimal, locale-independent (e.g. `2847` → `"2,847"`).
    static func grouped(_ n: Int) -> String {
        // `n.magnitude` (UInt) is total for every Int; `abs(Int.min)` would trap.
        let digits = String(n.magnitude)
        var out = "", count = 0
        for ch in digits.reversed() {
            if count != 0 && count % 3 == 0 { out.append(",") }
            out.append(ch)
            count += 1
        }
        return (n < 0 ? "-" : "") + String(out.reversed())
    }
}
