# Trace Replay

A trace tells you what a run did. Replay tells you what the run looked like **while it was doing it**. `TraceReplayEngine` reconstructs the hierarchical span tree of a recorded run *as of any point in time* — scrub backward through an agent's execution the way you'd scrub through a video — and every reconstruction comes with a manifest that quantifies exactly how trustworthy it is: sequence gaps, duplicates, orphaned subtrees, and events that never reached durable storage.

This is the engine behind the timeline scrubber in the [trace inspector UI](UI.md), and the input format for [snapshot diffing](SNAPSHOTS.md).

## Minimal end-to-end example

Using the `MyAIDecision` event type from the [README's *Getting started* section](../README.md#getting-started):

```swift
import DProvenanceKit

let runs = try await store.queryRuns(
    TraceQueryDSL<MyAIDecision>().filter(contextID: "Case-12345")
)
guard let run = runs.first else { return }

let engine = TraceReplayEngine(committed: run.events)

let full = engine.snapshot()          // the whole run
let partial = engine.snapshot(at: 42) // the run as of sequence 42

print("spans reconstructed:", partial.manifest.reconstructedSpans)
print("sequence gaps:", partial.manifest.sequenceGaps.count)
print("events included:", partial.manifest.totalEvents, "of", full.manifest.totalEvents)
```

## How it works

The engine takes the raw events of **a single run** — the committed events, plus optionally *quarantined* events (events a [cloud writer](CLOUD.md) failed to deliver) — and merges them into one deterministic total order. Ties are broken by a fixed chain, so two replays of the same data always produce the same result:

1. `sequence` (the authoritative causal clock)
2. `timestamp`
3. `contextID`
4. `eventID.uuidString`

`snapshot(at:)` is the time-travel primitive. Pass a sequence number and you get the world state up to and including that sequence: a forest of `SpanNode`s plus a `ReplayManifest` describing the health of the data behind it. Pass `nil` (the default) for the full run.

## Walking the span tree

`ReplaySnapshot.roots` is a forest sorted by `startSequence`. Each `SpanNode` carries its events, its children (also sorted by `startSequence`), and a contamination flag that is `true` if the node **or any descendant** contains a quarantined event:

```swift
func walk(_ node: SpanNode<MyAIDecision>, indent: Int = 0) {
    let label = node.spanID ?? "(root)"
    let marker = node.containsQuarantinedEvents ? "  ⚠ quarantined" : ""
    print(String(repeating: "  ", count: indent) + "\(label) [\(node.startSequence)...\(node.endSequence)]\(marker)")
    for child in node.children {
        walk(child, indent: indent + 1)
    }
}
for root in full.roots {
    walk(root)
}
```

Spans come from `withSpan` scopes at record time (`spanID` / `parentSpanID` on each event). Events recorded outside any span appear as anonymous roots with `spanID == nil` — one anonymous root node **per span-less event**, not one shared root.

## Data health: the manifest

A reconstruction is only as honest as the data behind it, so every snapshot says what it's missing:

```swift
let snapshot = engine.snapshot()
let m = snapshot.manifest

let healthy = m.sequenceGaps.isEmpty
    && m.orphanedEvents == 0
    && m.duplicateEventIDs == 0
    && m.quarantinedEvents == 0
guard healthy else {
    print("replay is lossy: gaps=\(m.sequenceGaps) orphaned=\(m.orphanedEvents) duplicates=\(m.duplicateEventIDs)")
    return
}
```

| Field | Meaning |
| --- | --- |
| `totalEvents` | Events included in this snapshot (committed + quarantined). |
| `committedEvents` / `quarantinedEvents` | Split by `ReplaySource`. |
| `orphanedEvents` | Events in subtrees whose parent span is entirely absent from the snapshot. |
| `duplicateEventIDs` | Events whose `id` was already seen. Duplicates are **counted, not deduplicated** — a duplicated event appears twice in the tree; this counter is the only signal. |
| `reconstructedSpans` | Named spans reachable from the roots. |
| `contaminatedSpans` | Reconstructed spans whose subtree contains at least one quarantined event. |
| `sequenceGaps` | Inclusive `[lowerBound, upperBound]` ranges of missing sequence numbers. |

Orphaned subtrees are not silently dropped: their events land in `ReplaySnapshot.orphanedEvents` (sorted by `replayOrder`) — but as a flat event list; the orphaned subtree's span structure is discarded.

`ReplaySnapshotMetadata` records how the snapshot was taken:

```swift
if let cutoff = snapshot.metadata.maxSequenceIncluded {
    print("partial replay up to sequence \(cutoff)")
}
print("committed:", snapshot.metadata.sourceCounts[.committed] ?? 0)
print("quarantined:", snapshot.metadata.sourceCounts[.quarantined] ?? 0)
```

`maxSequenceIncluded` is `nil` for a full replay.

## Replaying undelivered events

`CloudTraceStore` quarantines batches the server rejected or that exhausted their retries. Feed them back into the replay alongside the committed events and the affected spans are flagged rather than silently incomplete:

```swift
let quarantined = try await cloudStore.queryQuarantinedEvents(TraceQueryDSL<MyAIDecision>())
let engine = TraceReplayEngine(committed: run.events, quarantined: quarantined)
let snapshot = engine.snapshot()

if snapshot.manifest.contaminatedSpans > 0 {
    print("\(snapshot.manifest.contaminatedSpans) spans contain undelivered events")
}
```

See [CLOUD.md](CLOUD.md) for what quarantine does and doesn't guarantee.

## API reference

```swift
public struct TraceReplayEngine<T: TraceableEvent>: Sendable {
    public let committed: [TraceEvent<T>]
    public let quarantined: [TraceEvent<T>]
    public init(committed: [TraceEvent<T>], quarantined: [TraceEvent<T>] = [])
    public func snapshot(at sequence: UInt64? = nil) -> ReplaySnapshot<T>
}

public enum ReplaySource: String, Sendable, Codable, Equatable {
    case committed, quarantined
}

public struct ReplayEvent<T: TraceableEvent>: Sendable, Equatable {
    public let source: ReplaySource
    public let event: TraceEvent<T>
    public let replayOrder: UInt64   // position in the merged deterministic total order
}

public struct SpanNode<T: TraceableEvent>: Sendable, Equatable {
    public let spanID: String?       // nil = anonymous root for a span-less event
    public let startSequence: UInt64
    public let endSequence: UInt64
    public let events: [ReplayEvent<T>]
    public let children: [SpanNode<T>]          // sorted by startSequence
    public let containsQuarantinedEvents: Bool  // true if self OR any descendant is contaminated
}

public struct SequenceGap: Sendable, Equatable {
    public let lowerBound: UInt64    // inclusive
    public let upperBound: UInt64    // inclusive
}

public struct ReplayManifest: Sendable, Equatable {
    public let totalEvents: Int
    public let committedEvents: Int
    public let quarantinedEvents: Int
    public let orphanedEvents: Int
    public let duplicateEventIDs: Int
    public let reconstructedSpans: Int
    public let contaminatedSpans: Int
    public let sequenceGaps: [SequenceGap]
}

public struct ReplaySnapshotMetadata: Sendable, Equatable {
    public let generatedAt: Date
    public let maxSequenceIncluded: UInt64?  // nil = full replay
    public let sourceCounts: [ReplaySource: Int]
}

public struct ReplaySnapshot<T: TraceableEvent>: Sendable {
    public let roots: [SpanNode<T>]              // sorted by startSequence
    public let orphanedEvents: [ReplayEvent<T>]  // sorted by replayOrder
    public let manifest: ReplayManifest
    public let metadata: ReplaySnapshotMetadata
}
```

All of these types also expose public memberwise initializers, so snapshots can be constructed directly in tests.

## Constraints and limitations

- **One run per engine.** Gap detection assumes sequences are contiguous from 0 within a single run. Feeding events from multiple runs into one engine produces meaningless gaps and cross-wired span trees — nothing enforces the single-run invariant; it is the caller's responsibility.
- **Duplicates are visible, not repaired.** A duplicated event ID appears twice in the tree. Check `manifest.duplicateEventIDs`.
- **Malformed parent cycles vanish.** A span whose `parentSpanID` chain forms a cycle (so it never reaches a root, but its parent *does* exist) appears in neither `roots` nor `orphanedEvents`; only the event totals still include its events. Cycles indicate corrupted recording, not a supported topology.
- **`snapshot(at:)` is a full rebuild.** Each call re-derives the tree and manifest — roughly O(n log n) in event count. Fine for inspection and tooling; do not call it per frame on large runs (see the [performance note in UI.md](UI.md#performance)).
