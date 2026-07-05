# Snapshot Diffing

Replay answers *"what did the run look like at sequence N?"* Snapshot diffing answers *"what changed between two of those states?"* `SnapshotDiffEngine` compares two [replay snapshots](REPLAY.md) — two points in time of the **same** run, or full reconstructions of two **different** runs — and reports structural change at the span level, semantic change at the event level, and the exact **divergence point**: the first index where two event streams stop agreeing.

This is not the same tool as `TraceDiffEngine` or `TraceAlignmentEngine` (the run-level diffing documented in the README). Those compare runs as flat step sequences; this one compares *reconstructed replay states*, span tree and all. It's what powers diff mode in the [trace inspector UI](UI.md).

## Minimal end-to-end example

Using the `MyAIDecision` event type from the [README's *Getting started* section](../README.md#getting-started):

```swift
import DProvenanceKit

let engine = TraceReplayEngine(committed: run.events)
let before = engine.snapshot(at: 10)
let after = engine.snapshot(at: 50)

let diff = SnapshotDiffEngine<MyAIDecision>().diff(base: before, comparison: after)
guard !diff.isIdentical else { return }

let summary = diff.summary
print("+\(summary.addedEvents) events, -\(summary.removedEvents) events, ~\(summary.modifiedEvents) modified")

for divergence in diff.divergences {
    print("span \(divergence.spanID ?? "root") diverges at sequence \(divergence.divergenceSequence)",
          "after \(divergence.commonPrefixLength) shared events")
}
```

Comparing two different runs works the same way — build a full snapshot of each:

```swift
let baseline = TraceReplayEngine(committed: runA.events).snapshot()
let candidate = TraceReplayEngine(committed: runB.events).snapshot()

let diff = SnapshotDiffEngine<MyAIDecision>().diff(base: baseline, comparison: candidate)
print(diff.summary)
```

## What the diff reports

**Span changes** — structural shape, keyed by `spanID`:

```swift
for change in diff.spanChanges {
    switch change {
    case .added(let spanID, let parentSpanID):
        print("span added: \(spanID ?? "?") under \(parentSpanID ?? "root")")
    case .removed(let spanID, let parentSpanID):
        print("span removed: \(spanID ?? "?") from \(parentSpanID ?? "root")")
    case .reparented(let spanID, let fromParent, let toParent):
        print("span \(spanID ?? "?") moved: \(fromParent ?? "root") -> \(toParent ?? "root")")
    case .contaminationChanged(let spanID, let from, let to):
        print("span \(spanID ?? "?") contamination: \(from) -> \(to)")
    }
}
```

**Event changes** — matched on the *semantic identity* `(sequence, typeIdentifier, engineName)`, compared per span:

```swift
for change in diff.eventChanges {
    switch change {
    case .added(let event, let spanID):
        print("+ \(event.event.payload.typeIdentifier) in \(spanID ?? "root")")
    case .removed(let event, let spanID):
        print("- \(event.event.payload.typeIdentifier) in \(spanID ?? "root")")
    case .modified(let before, let after, let spanID):
        print("~ \(before.event.payload.typeIdentifier) -> \(after.event.payload.typeIdentifier) in \(spanID ?? "root")")
    }
}
```

An event present on both sides under the same identity but with a different payload is `.modified`. Payload comparison is **exact value equality** on your `TraceableEvent` type (`T` is `Equatable`) — deliberately not a hash of the JSON encoding, which was lossy: hash collisions, and every encode failure mapping to the same value, could report changed payloads as equal. That is exactly the false negative a diff tool must never produce.

**Divergence points** — a positional scan, one per span (plus one for span-less root events): the length of the common prefix where both event streams agree on identity *and* payload, and the first event on each side after they stop agreeing. `divergenceSequence` is the sequence of the first differing event on the comparison side. `leftEvent` / `rightEvent` are typed as optionals, but the engine populates both whenever it reports a divergence.

## Reading the summary honestly

`DiffSummary` is a set of counters derived from the change lists. Two of them need care:

- **`contaminatedSpans` counts contamination *transitions*, in either direction** — spans whose `containsQuarantinedEvents` flag flipped between the snapshots. It is *not* a count of spans currently contaminated (that's `ReplayManifest.contaminatedSpans` on either snapshot).
- **`reparented` changes are not counted in the summary at all.** They appear only in `spanChanges`. If a moved span matters to you, scan the list.

Identity-keyed comparison also means a **reordered step is reported as an add/remove pair** — there is no "moved event" change kind. The per-span `DivergencePoint` is the tool for order questions: it pinpoints where the two streams first disagree, but only the *first* disagreement per span is reported.

## API reference

```swift
public struct SnapshotDiffEngine<T: TraceableEvent>: Sendable {
    public init()
    public func diff(base: ReplaySnapshot<T>, comparison: ReplaySnapshot<T>) -> SnapshotDiffResult<T>
}

public enum SpanChange: Sendable, Equatable {
    case added(spanID: String?, parentSpanID: String?)
    case removed(spanID: String?, parentSpanID: String?)
    case reparented(spanID: String?, fromParent: String?, toParent: String?)
    case contaminationChanged(spanID: String?, from: Bool, to: Bool)
}

public enum EventChange<T: TraceableEvent>: Sendable, Equatable {
    case added(event: ReplayEvent<T>, spanID: String?)
    case removed(event: ReplayEvent<T>, spanID: String?)
    case modified(before: ReplayEvent<T>, after: ReplayEvent<T>, spanID: String?)
}

public struct DivergencePoint<T: TraceableEvent>: Sendable, Equatable {
    public let spanID: String?
    public let commonPrefixLength: Int
    public let divergenceSequence: UInt64  // sequence of the first differing event
    public let leftEvent: ReplayEvent<T>?
    public let rightEvent: ReplayEvent<T>?
}

public struct DiffSummary: Sendable, Equatable {
    public let addedSpans: Int
    public let removedSpans: Int
    public let addedEvents: Int
    public let removedEvents: Int
    public let modifiedEvents: Int
    public let contaminatedSpans: Int      // contamination *transitions*, either direction
    public let divergencePoints: Int
}

public struct SnapshotDiffResult<T: TraceableEvent>: Sendable, Equatable {
    public let spanChanges: [SpanChange]
    public let eventChanges: [EventChange<T>]
    public let divergences: [DivergencePoint<T>]
    public var summary: DiffSummary { get }
    public var isIdentical: Bool { get }
}
```

## Constraints and limitations

- **Identity collisions lose events.** Event identity is `(sequence, typeIdentifier, engineName)`. Two events in the same span sharing all three collide in the comparison's lookup tables (last one wins), so pathological traces — e.g. duplicated sequences from corrupted recording — can misreport. Check `ReplayManifest.duplicateEventIDs` before trusting a diff over suspect data.
- **Cross-run diffs assume comparable sequences.** Identity includes `sequence`, so comparing two runs is meaningful when the runs assign sequence numbers the same way (both contiguous from 0). A run pair whose step counts drift early will report add/remove noise downstream of the first insertion — that's what `divergences` is for. For semantic *equivalence* between runs, use `TraceAlignmentEngine` instead.
- **Only the first divergence per span is reported.** Streams that re-converge and diverge again yield a single `DivergencePoint`.
- The engine only diffs event streams for spans whose nodes differ, plus added/removed spans and root events — it never mutates or reorders the snapshots it's given.
