# DProvenanceUI — the trace inspector

Traces you can't see are traces you won't read. `DProvenanceUI` is a second library product in this package: a SwiftUI trace inspector for Apple platforms with a run list, a **replay timeline scrubber**, a live **diff mode**, and a span tree that renders reconstructed runs with quarantine warnings and change highlighting. Point it at any `Traces.sqlite` produced by `SQLiteTraceStore` — it reads traces generically, without knowing your payload type.

It is the visual front end for [trace replay](REPLAY.md) and [snapshot diffing](SNAPSHOTS.md).

```swift
.product(name: "DProvenanceUI", package: "DProvenanceKit")
```

## Minimal end-to-end example

A complete inspector app is one view and one environment object:

```swift
import SwiftUI
import DProvenanceUI

@main
struct TraceInspectorApp: App {
    @StateObject private var storeManager = StoreManager()

    var body: some Scene {
        WindowGroup {
            TraceViewer()
                .environmentObject(storeManager)
        }
    }
}
```

On macOS, `TraceViewer` shows an "Open Traces.sqlite" button (an `NSOpenPanel`) when no database is loaded. On iOS, host apps provide their own document picker or file URL and load programmatically:

```swift
storeManager.loadDatabase(at: URL(fileURLWithPath: "/path/to/Traces.sqlite"))
```

## What you get

`TraceViewer` is a `NavigationSplitView`:

- **Run list** — every run in the database, with context ID and event count. Selecting a run opens the detail pane.
- **Replay timeline** — a slider that moves `TraceReplayEngine.snapshot(at:)` through the run: drag it and the span tree re-renders the world state as of that sequence.
- **Diff mode** — a toggle adds a second slider; the two snapshots are diffed live with `SnapshotDiffEngine` and summarized in an overlay (events added/removed/modified, divergences, span changes).
- **Span tree** — the reconstructed `SpanNode` forest: nested spans with sequence ranges, per-event rows, quarantine warning badges, add/remove/modify highlighting, strikethrough for removals, and divergence flags in diff mode.

Under the hood, `StoreManager` opens the SQLite file with `RawTraceStore` and maps every row to `TraceEvent<AnyTraceableEvent>` — a type-erased payload carrying the raw JSON — which is why the viewer works against any event type without recompiling.

## Composing the pieces yourself

Every component the viewer is built from is public, so you can embed just the parts you want — with your own concrete event type instead of the type-erased one.

**Span tree from a snapshot.** `SpanViewModel` projects a `SpanNode` tree into renderable rows (stable render IDs, depth, collapse state); `flattenSpanTree` linearizes it for a lazy list:

```swift
import DProvenanceKit
import DProvenanceUI

let engine = TraceReplayEngine(committed: run.events)
let snapshot = engine.snapshot()

let hints = RenderHints(collapsedByDefault: ["setup"])
let roots = snapshot.roots.map { node in
    SpanViewModel(node: node, snapshotID: "full", localPathHash: "", depth: 0, hints: hints)
}
let rows = flattenSpanTree(roots: roots, dynamicCollapsed: [])

SpanTreeView(nodes: rows, diffResult: nil)
```

`snapshotID` namespaces render IDs so rows from different snapshots never collide in SwiftUI's identity system; `dynamicCollapsed` overrides the per-span collapse state at runtime (a span in the set is treated as collapsed regardless of hints).

**Scrubber + diff overlay.** `TraceTimelineView` drives sequence bindings; you rebuild snapshots from them:

```swift
struct ScrubberInspector: View {
    let engine: TraceReplayEngine<MyAIDecision>

    @State private var currentSequence: UInt64 = 0
    @State private var isComparisonMode = false
    @State private var comparisonSequence: UInt64 = 0

    var body: some View {
        VStack {
            TraceTimelineView(
                engine: engine,
                currentSequence: $currentSequence,
                isComparisonMode: $isComparisonMode,
                comparisonSequence: $comparisonSequence
            )

            let base = engine.snapshot(at: currentSequence)
            if isComparisonMode {
                let comparison = engine.snapshot(at: comparisonSequence)
                let diff = SnapshotDiffEngine<MyAIDecision>().diff(base: base, comparison: comparison)
                DiffOverlayView(diffResult: diff)
            }
        }
    }
}
```

**Type-erased bridging.** For tooling that reads arbitrary trace databases, `RawTraceEvent.toTraceEvent()` converts a raw row into a `TraceEvent<AnyTraceableEvent>` whose payload exposes `typeIdentifier`, the priority, and the raw JSON string.

## API reference

```swift
// Top-level viewer — requires .environmentObject(StoreManager)
public struct TraceViewer: View {
    public init()
}

@MainActor
public final class StoreManager: ObservableObject {
    @Published public var store: RawTraceStore?
    @Published public var runs: [TraceRun<AnyTraceableEvent>]
    @Published public var isLoading: Bool
    @Published public var errorMessage: String?
    public init()
    #if canImport(AppKit)
    public func openDatabase()            // NSOpenPanel
    #endif
    public func loadDatabase(at url: URL)
}

public struct RunListView: View {
    public init(selectedRunID: Binding<UUID?>)   // requires .environmentObject(StoreManager)
}

public struct TraceTimelineView<T: TraceableEvent>: View {
    public init(engine: TraceReplayEngine<T>,
                currentSequence: Binding<UInt64>,
                isComparisonMode: Binding<Bool>,
                comparisonSequence: Binding<UInt64>)
}

public struct SpanTreeView<T: TraceableEvent>: View {
    public init(nodes: [FlattenedSpanNode<T>], diffResult: SnapshotDiffResult<T>? = nil)
}

public struct DiffOverlayView<T: TraceableEvent>: View {
    public init(diffResult: SnapshotDiffResult<T>)
}

// View-model layer: SpanNode -> renderable rows
public struct SpanViewModel<T: TraceableEvent>: Identifiable, Sendable {
    public init(node: SpanNode<T>, snapshotID: String,
                localPathHash: String, depth: Int, hints: RenderHints)
}

public struct FlattenedSpanNode<T: TraceableEvent>: Identifiable, Sendable {
    public init(viewModel: SpanViewModel<T>, isVisible: Bool)
}

public func flattenSpanTree<T: TraceableEvent>(
    roots: [SpanViewModel<T>],
    dynamicCollapsed: Set<String>
) -> [FlattenedSpanNode<T>]

// Render hints (defined in DProvenanceKit)
public struct RenderHints: Sendable, Equatable {
    public init(collapsedByDefault: Set<String> = [],
                importantEventTypes: Set<String> = [],
                highlightQuarantine: Bool = true,
                diffMode: DiffPresentationMode = .none)
}

// Type-erased bridging (extension in DProvenanceUI)
extension RawTraceEvent {
    public func toTraceEvent() -> TraceEvent<AnyTraceableEvent>
}
```

The module also ships the alignment-debugging views (`AlignmentInvestigationView`, `AlignmentMatrixDebuggerView`, `AlignmentReplayView`, `BenchmarkExplorerView`) belonging to the alignment/benchmark feature set; they are outside the scope of this document.

## Constraints and limitations

- **Native file picker is macOS-only.** The UI target compiles for iOS, but `openDatabase()` is available only when AppKit is present. iOS apps should present their own document picker and call `StoreManager.loadDatabase(at:)`.
- **`RenderHints`: only `collapsedByDefault` does anything today.** `importantEventTypes`, `highlightQuarantine`, and `diffMode` are accepted but not yet consumed by any view — reserved for future rendering behavior. Don't build on them.
- **Collapse is static.** `RenderHints.collapsedByDefault` (via the view-model layer) and the `dynamicCollapsed` parameter control visibility, but `SpanTreeView` itself wires no click-to-collapse gesture — the chevrons are indicators. Interactive collapse means managing your own `Set<String>` and re-flattening.
- **`RunDetailView` is not a public entry point.** The type is public but has no public initializer; consume it through `TraceViewer`.
- <a name="performance"></a>**Sized for inspection, not for huge runs.** The detail pane rebuilds the replay engine and recomputes snapshots (and the full diff, in diff mode) on every render and slider tick, and `StoreManager.loadDatabase` eagerly loads every event of every run into memory. Responsive for typical debugging-sized traces; not engineered for multi-hundred-thousand-event archives.
- Event payload display falls back to Swift's default description unless the payload is `AnyTraceableEvent` (then the raw JSON is shown).

## A note on `WebVisualizer/`

The `WebVisualizer/` directory at the repository root is a browser-based diff explorer for [`WebDiffExport`](../WebVisualizer/SCHEMA.md) JSON. It opens with `mockDiffs.json` as sample data, then accepts real exports through **Load JSON**. Generate one with `swift run DProvenanceKitCLI web-export --out=run.json` or by running `swift run FoundationModelsRegressionDemo`, which writes `fm-regression.json`.

`DProvenanceUI` remains the supported native SwiftUI inspector for trace databases; `WebVisualizer` is the portable artifact viewer for already-diffed runs.
