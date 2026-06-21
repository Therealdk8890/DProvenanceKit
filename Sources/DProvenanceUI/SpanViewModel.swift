import Foundation
import DProvenanceKit

public struct SpanViewModel<T: TraceableEvent>: Identifiable, Sendable {
    public let renderID: String
    public let spanID: String?
    public let depth: Int
    public let isCollapsed: Bool
    public let containsQuarantinedEvents: Bool
    public let events: [ReplayEvent<T>]
    public let children: [SpanViewModel<T>]
    
    public var id: String { renderID }
    
    public init(
        node: SpanNode<T>,
        snapshotID: String,
        localPathHash: String,
        depth: Int,
        hints: RenderHints
    ) {
        self.spanID = node.spanID
        self.depth = depth
        
        let pathPart = localPathHash.isEmpty ? "root" : localPathHash
        self.renderID = "\(node.spanID ?? "root")::\(snapshotID)::\(pathPart)"
        
        if let id = node.spanID {
            self.isCollapsed = hints.collapsedByDefault.contains(id)
        } else {
            self.isCollapsed = false
        }
        
        self.containsQuarantinedEvents = node.containsQuarantinedEvents
        self.events = node.events
        self.children = node.children.map { child in
            let childPath = "\(pathPart)->\(child.spanID ?? "anon")"
            return SpanViewModel(
                node: child,
                snapshotID: snapshotID,
                localPathHash: String(childPath.hashValue),
                depth: depth + 1,
                hints: hints
            )
        }
    }
}

public struct FlattenedSpanNode<T: TraceableEvent>: Identifiable, Sendable {
    public let id: String
    public let spanID: String?
    public let depth: Int
    public let isCollapsed: Bool
    public let isVisible: Bool
    public let hasChildren: Bool
    public let containsQuarantinedEvents: Bool
    public let events: [ReplayEvent<T>]
    
    public init(viewModel: SpanViewModel<T>, isVisible: Bool) {
        self.id = viewModel.renderID
        self.spanID = viewModel.spanID
        self.depth = viewModel.depth
        self.isCollapsed = viewModel.isCollapsed
        self.isVisible = isVisible
        self.hasChildren = !viewModel.children.isEmpty
        self.containsQuarantinedEvents = viewModel.containsQuarantinedEvents
        self.events = viewModel.events
    }
}

public func flattenSpanTree<T: TraceableEvent>(roots: [SpanViewModel<T>], dynamicCollapsed: Set<String>) -> [FlattenedSpanNode<T>] {
    var result: [FlattenedSpanNode<T>] = []
    
    func traverse(node: SpanViewModel<T>, isVisible: Bool) {
        result.append(FlattenedSpanNode(viewModel: node, isVisible: isVisible))
        
        // Use dynamic runtime collapse state if available, fallback to default from ViewModel
        let isCollapsed = node.spanID.map { dynamicCollapsed.contains($0) } ?? node.isCollapsed
        
        for child in node.children {
            // A child is visible only if its parent is visible and the parent is NOT collapsed.
            traverse(node: child, isVisible: isVisible && !isCollapsed)
        }
    }
    
    for root in roots {
        traverse(node: root, isVisible: true)
    }
    
    return result
}
