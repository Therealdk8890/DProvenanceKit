import SwiftUI
import DProvenanceKit

public struct SpanTreeView<T: TraceableEvent>: View {
    let nodes: [FlattenedSpanNode<T>]
    let diffResult: SnapshotDiffResult<T>?
    
    public init(nodes: [FlattenedSpanNode<T>], diffResult: SnapshotDiffResult<T>? = nil) {
        self.nodes = nodes
        self.diffResult = diffResult
    }
    
    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(nodes) { node in
                    if node.isVisible {
                        SpanNodeRow(node: node, diffResult: diffResult)
                    }
                }
            }
            .padding(.vertical)
        }
    }
}

struct SpanNodeRow<T: TraceableEvent>: View {
    let node: FlattenedSpanNode<T>
    let diffResult: SnapshotDiffResult<T>?
    
    var spanChange: SpanChange? {
        guard let diff = diffResult, let spanID = node.spanID else { return nil }
        return diff.spanChanges.first { change in
            switch change {
            case .added(let sID, _), .removed(let sID, _), .reparented(let sID, _, _), .contaminationChanged(let sID, _, _):
                return sID == spanID
            }
        }
    }
    
    var rowBackground: Color {
        if let change = spanChange {
            switch change {
            case .added: return Color.green.opacity(0.1)
            case .removed: return Color.red.opacity(0.1)
            case .reparented: return Color.blue.opacity(0.1)
            case .contaminationChanged: return Color.orange.opacity(0.1)
            }
        }
        if node.containsQuarantinedEvents {
            return Color.orange.opacity(0.05)
        }
        return Color.clear
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Span Header
            HStack {
                if node.depth > 0 {
                    Rectangle()
                        .fill(Color.clear)
                        .frame(width: CGFloat(node.depth * 20))
                }
                
                Image(systemName: node.isCollapsed ? "chevron.right" : "chevron.down")
                    .foregroundColor(node.hasChildren ? .primary : .clear)
                    .frame(width: 16)
                
                Text(node.spanID ?? "Root Span")
                    .font(.headline)
                    .strikethrough(isRemoved)
                
                if node.containsQuarantinedEvents {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .help("Contains Quarantined Events")
                }
                
                Spacer()
            }
            .padding(.vertical, 4)
            .padding(.horizontal)
            .background(rowBackground)
            
            // Events within this span
            if !node.isCollapsed {
                ForEach(node.events, id: \.event.id) { event in
                    EventDiffRow(event: event, depth: node.depth + 1, diffResult: diffResult)
                }
            }
        }
    }
    
    var isRemoved: Bool {
        if case .removed = spanChange { return true }
        return false
    }
}

struct EventDiffRow<T: TraceableEvent>: View {
    let event: ReplayEvent<T>
    let depth: Int
    let diffResult: SnapshotDiffResult<T>?
    
    var eventChange: EventChange<T>? {
        guard let diff = diffResult else { return nil }
        return diff.eventChanges.first { change in
            switch change {
            case .added(let e, _): return e.event.id == event.event.id
            case .removed(let e, _): return e.event.id == event.event.id
            case .modified(let old, let new, _): return old.event.id == event.event.id || new.event.id == event.event.id
            }
        }
    }
    
    var isDivergencePoint: Bool {
        guard let diff = diffResult else { return false }
        return diff.divergences.contains { div in
            div.leftEvent?.event.id == event.event.id || div.rightEvent?.event.id == event.event.id
        }
    }
    
    var body: some View {
        HStack(alignment: .top) {
            if depth > 0 {
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: CGFloat(depth * 20))
            }
            
            Circle()
                .fill(eventColor)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(event.event.payload.typeIdentifier)
                        .font(.system(.subheadline, design: .monospaced))
                        .bold()
                        .strikethrough(isRemoved)
                    
                    if isDivergencePoint {
                        Text("DIVERGENCE")
                            .font(.caption)
                            .bold()
                            .padding(.horizontal, 4)
                            .background(Color.red)
                            .foregroundColor(.white)
                            .cornerRadius(4)
                    }
                    
                    Spacer()
                    
                    Text("Seq: \(event.event.sequence)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                if let payloadText = payloadText {
                    Text(payloadText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(4)
                }
            }
            .padding(8)
            .background(eventBackground)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isDivergencePoint ? Color.red : Color.clear, lineWidth: 2)
            )
        }
        .padding(.horizontal)
        .padding(.vertical, 2)
    }
    
    var payloadText: String? {
        if let anyEvent = event.event.payload as? AnyTraceableEvent {
            return anyEvent.rawJSON
        }
        return "\(event.event.payload)"
    }
    
    var isRemoved: Bool {
        if case .removed = eventChange { return true }
        return false
    }
    
    var eventColor: Color {
        if let anyEvent = event.event.payload as? AnyTraceableEvent {
            switch anyEvent.priority {
            case .critical: return .red
            case .structural: return .orange
            case .diagnostic: return .blue
            case .telemetry: return .gray
            }
        }
        return .gray
    }
    
    var eventBackground: Color {
        if let change = eventChange {
            switch change {
            case .added: return Color.green.opacity(0.1)
            case .removed: return Color.red.opacity(0.1)
            case .modified: return Color.yellow.opacity(0.1)
            }
        }
        
        switch event.source {
        case .quarantined: return Color.orange.opacity(0.05)
        case .committed: return Color(NSColor.textBackgroundColor)
        }
    }
}
