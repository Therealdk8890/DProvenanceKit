import Foundation

public struct SnapshotDiffEngine<T: TraceableEvent>: Sendable {
    
    public init() {}
    
    private struct EventIdentity: Hashable {
        let sequence: UInt64
        let typeIdentifier: String
        let engineName: String
    }
    
    private struct EventSignature: Hashable {
        let payloadHash: Int
        let source: ReplaySource
    }
    
    private func identity(for e: ReplayEvent<T>) -> EventIdentity {
        return EventIdentity(
            sequence: e.event.sequence,
            typeIdentifier: e.event.payload.typeIdentifier,
            engineName: e.event.engineName
        )
    }
    
    private func signature(for e: ReplayEvent<T>) -> EventSignature {
        let data = try? JSONEncoder().encode(e.event.payload)
        return EventSignature(payloadHash: data?.hashValue ?? 0, source: e.source)
    }
    
    struct SpanInfo {
        let node: SpanNode<T>
        let parentID: String?
    }
    
    private func buildMap(_ roots: [SpanNode<T>]) -> [String: SpanInfo] {
        var map: [String: SpanInfo] = [:]
        func traverse(_ node: SpanNode<T>, parentID: String?) {
            if let id = node.spanID {
                map[id] = SpanInfo(node: node, parentID: parentID)
                for child in node.children {
                    traverse(child, parentID: id)
                }
            } else {
                for child in node.children {
                    traverse(child, parentID: nil)
                }
            }
        }
        for root in roots {
            traverse(root, parentID: nil)
        }
        return map
    }
    
    private func gatherRootEvents(_ roots: [SpanNode<T>]) -> [ReplayEvent<T>] {
        var events: [ReplayEvent<T>] = []
        for root in roots {
            if root.spanID == nil {
                events.append(contentsOf: root.events)
            }
        }
        return events
    }
    
    public func diff(base: ReplaySnapshot<T>, comparison: ReplaySnapshot<T>) -> SnapshotDiffResult<T> {
        var spanChanges: [SpanChange] = []
        var eventChanges: [EventChange<T>] = []
        var divergences: [DivergencePoint<T>] = []
        
        let baseMap = buildMap(base.roots)
        let compMap = buildMap(comparison.roots)
        
        func diffEvents(baseEvents: [ReplayEvent<T>], compEvents: [ReplayEvent<T>], spanID: String?) {
            var commonPrefix = 0
            let minLen = min(baseEvents.count, compEvents.count)
            while commonPrefix < minLen {
                let b = baseEvents[commonPrefix]
                let c = compEvents[commonPrefix]
                if identity(for: b) == identity(for: c) && signature(for: b) == signature(for: c) {
                    commonPrefix += 1
                } else {
                    break
                }
            }
            
            if commonPrefix < minLen {
                divergences.append(DivergencePoint(
                    spanID: spanID,
                    commonPrefixLength: commonPrefix,
                    divergenceSequence: compEvents[commonPrefix].event.sequence,
                    leftEvent: baseEvents[commonPrefix],
                    rightEvent: compEvents[commonPrefix]
                ))
            }
            
            var baseDict: [EventIdentity: ReplayEvent<T>] = [:]
            for e in baseEvents { baseDict[identity(for: e)] = e }
            
            var compDict: [EventIdentity: ReplayEvent<T>] = [:]
            for e in compEvents { compDict[identity(for: e)] = e }
            
            for e in compEvents {
                let id = identity(for: e)
                if let b = baseDict[id] {
                    if signature(for: b) != signature(for: e) {
                        eventChanges.append(.modified(before: b, after: e, spanID: spanID))
                    }
                } else {
                    eventChanges.append(.added(event: e, spanID: spanID))
                }
            }
            
            for e in baseEvents {
                let id = identity(for: e)
                if compDict[id] == nil {
                    eventChanges.append(.removed(event: e, spanID: spanID))
                }
            }
        }
        
        // Diff root events
        diffEvents(baseEvents: gatherRootEvents(base.roots), compEvents: gatherRootEvents(comparison.roots), spanID: nil)
        
        // Diff spans
        for (id, compInfo) in compMap {
            if let baseInfo = baseMap[id] {
                if baseInfo.parentID != compInfo.parentID {
                    spanChanges.append(.reparented(spanID: id, fromParent: baseInfo.parentID, toParent: compInfo.parentID))
                }
                if baseInfo.node.containsQuarantinedEvents != compInfo.node.containsQuarantinedEvents {
                    spanChanges.append(.contaminationChanged(spanID: id, from: baseInfo.node.containsQuarantinedEvents, to: compInfo.node.containsQuarantinedEvents))
                }
                
                if baseInfo.node != compInfo.node {
                    diffEvents(baseEvents: baseInfo.node.events, compEvents: compInfo.node.events, spanID: id)
                }
            } else {
                spanChanges.append(.added(spanID: id, parentSpanID: compInfo.parentID))
                diffEvents(baseEvents: [], compEvents: compInfo.node.events, spanID: id)
            }
        }
        
        for (id, baseInfo) in baseMap {
            if compMap[id] == nil {
                spanChanges.append(.removed(spanID: id, parentSpanID: baseInfo.parentID))
                diffEvents(baseEvents: baseInfo.node.events, compEvents: [], spanID: id)
            }
        }
        
        return SnapshotDiffResult(
            spanChanges: spanChanges,
            eventChanges: eventChanges,
            divergences: divergences
        )
    }
}
