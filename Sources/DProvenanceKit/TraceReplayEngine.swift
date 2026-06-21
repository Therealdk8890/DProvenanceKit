import Foundation

public struct TraceReplayEngine<T: TraceableEvent>: Sendable {
    public let committed: [TraceEvent<T>]
    public let quarantined: [TraceEvent<T>]
    
    private let allEvents: [ReplayEvent<T>]
    
    public init(committed: [TraceEvent<T>], quarantined: [TraceEvent<T>] = []) {
        self.committed = committed
        self.quarantined = quarantined
        
        var rawCombined: [(source: ReplaySource, event: TraceEvent<T>)] = []
        rawCombined.reserveCapacity(committed.count + quarantined.count)
        
        for c in committed {
            rawCombined.append((source: .committed, event: c))
        }
        for q in quarantined {
            rawCombined.append((source: .quarantined, event: q))
        }
        
        // Tie-breaker rules for deterministic total ordering:
        // 1. sequence
        // 2. timestamp
        // 3. contextID
        // 4. eventID
        rawCombined.sort { a, b in
            if a.event.sequence != b.event.sequence {
                return a.event.sequence < b.event.sequence
            }
            if a.event.timestamp != b.event.timestamp {
                return a.event.timestamp < b.event.timestamp
            }
            if a.event.contextID != b.event.contextID {
                return a.event.contextID < b.event.contextID
            }
            // Final deterministic tie breaker
            return a.event.id.uuidString < b.event.id.uuidString
        }
        
        var finalEvents: [ReplayEvent<T>] = []
        finalEvents.reserveCapacity(rawCombined.count)
        for (index, tuple) in rawCombined.enumerated() {
            finalEvents.append(ReplayEvent(source: tuple.source, event: tuple.event, replayOrder: UInt64(index)))
        }
        
        self.allEvents = finalEvents
    }
    
    public func snapshot(at sequence: UInt64? = nil) -> ReplaySnapshot<T> {
        let maxSeq = sequence ?? UInt64.max
        
        var validEvents: [ReplayEvent<T>] = []
        for e in allEvents {
            if e.event.sequence <= maxSeq {
                validEvents.append(e)
            }
        }
        
        // Calculate gaps (assuming events are from a single run where sequence should be contiguous starting from 0)
        var sequenceGaps: [SequenceGap] = []
        if !validEvents.isEmpty {
            var expectedNext: UInt64 = 0
            for i in 0..<validEvents.count {
                let current = validEvents[i].event.sequence
                if current > expectedNext {
                    sequenceGaps.append(SequenceGap(lowerBound: expectedNext, upperBound: current - 1))
                }
                if current >= expectedNext {
                    expectedNext = current + 1
                }
            }
        }
        
        var spanMap: [String: NodeBuilder] = [:]
        var rootBuilders: [NodeBuilder] = []
        
        // Pass 1: Create builders and group events by span
        for e in validEvents {
            if let spanID = e.event.spanID {
                if spanMap[spanID] == nil {
                    spanMap[spanID] = NodeBuilder(spanID: spanID, parentSpanID: e.event.parentSpanID)
                }
                spanMap[spanID]!.add(event: e)
            } else {
                let rootNode = NodeBuilder(spanID: nil, parentSpanID: nil)
                rootNode.add(event: e)
                rootBuilders.append(rootNode)
            }
        }
        
        var orphanedEvents: [ReplayEvent<T>] = []
        var roots: [NodeBuilder] = []
        
        // Pass 2: Wire up children and identify orphaned subtrees
        for (_, node) in spanMap {
            if let parentID = node.parentSpanID {
                if let parent = spanMap[parentID] {
                    parent.children.append(node)
                }
            } else {
                roots.append(node)
            }
        }
        
        for node in rootBuilders {
            roots.append(node)
        }
        
        // Pass 3: Collect orphaned events (subtrees whose parent span is entirely missing from the snapshot)
        for (_, node) in spanMap {
            if let pid = node.parentSpanID, spanMap[pid] == nil {
                func collectEvents(from n: NodeBuilder) {
                    orphanedEvents.append(contentsOf: n.events)
                    for child in n.children {
                        collectEvents(from: child)
                    }
                }
                collectEvents(from: node)
            }
        }
        
        var trueRoots = roots.map { $0.build() }
        trueRoots.sort { $0.startSequence < $1.startSequence }
        orphanedEvents.sort { $0.replayOrder < $1.replayOrder }
        
        var committedCount = 0
        var quarantinedCount = 0
        var uniqueEventIDs = Set<UUID>()
        var duplicateCount = 0
        
        for e in validEvents {
            if e.source == .committed { committedCount += 1 }
            else { quarantinedCount += 1 }
            
            if !uniqueEventIDs.insert(e.event.id).inserted {
                duplicateCount += 1
            }
        }
        
        // Traverse trees to count constructed spans and contaminated spans
        var reconstructedSpansCount = 0
        var contaminatedSpansCount = 0
        
        func traverse(_ node: SpanNode<T>) {
            if node.spanID != nil {
                reconstructedSpansCount += 1
                if node.containsQuarantinedEvents {
                    contaminatedSpansCount += 1
                }
            }
            for child in node.children {
                traverse(child)
            }
        }
        for r in trueRoots {
            traverse(r)
        }
        
        let manifest = ReplayManifest(
            totalEvents: validEvents.count,
            committedEvents: committedCount,
            quarantinedEvents: quarantinedCount,
            orphanedEvents: orphanedEvents.count,
            duplicateEventIDs: duplicateCount,
            reconstructedSpans: reconstructedSpansCount,
            contaminatedSpans: contaminatedSpansCount,
            sequenceGaps: sequenceGaps
        )
        
        let metadata = ReplaySnapshotMetadata(
            generatedAt: Date(),
            maxSequenceIncluded: sequence,
            sourceCounts: [.committed: committedCount, .quarantined: quarantinedCount]
        )
        
        return ReplaySnapshot(
            roots: trueRoots,
            orphanedEvents: orphanedEvents,
            manifest: manifest,
            metadata: metadata
        )
    }
    
    final class NodeBuilder {
        let spanID: String?
        let parentSpanID: String?
        var startSequence: UInt64 = UInt64.max
        var endSequence: UInt64 = 0
        var events: [ReplayEvent<T>] = []
        var children: [NodeBuilder] = []
        var containsQuarantinedEvents: Bool = false
        
        init(spanID: String?, parentSpanID: String?) {
            self.spanID = spanID
            self.parentSpanID = parentSpanID
        }
        
        func add(event: ReplayEvent<T>) {
            events.append(event)
            startSequence = min(startSequence, event.event.sequence)
            endSequence = max(endSequence, event.event.sequence)
            if event.source == .quarantined {
                containsQuarantinedEvents = true
            }
        }
        
        func build() -> SpanNode<T> {
            let builtChildren = children.map { $0.build() }
            let anyChildQuarantined = builtChildren.contains { $0.containsQuarantinedEvents }
            return SpanNode(
                spanID: spanID,
                startSequence: startSequence == UInt64.max ? 0 : startSequence,
                endSequence: endSequence,
                events: events,
                children: builtChildren.sorted { $0.startSequence < $1.startSequence },
                containsQuarantinedEvents: containsQuarantinedEvents || anyChildQuarantined
            )
        }
    }
}
