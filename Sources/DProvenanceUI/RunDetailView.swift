import SwiftUI
import DProvenanceKit

struct RunDetailView: View {
    let run: RawTraceRun
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading) {
                    Text(run.contextID)
                        .font(.title)
                        .bold()
                    Text("Run ID: \(run.runID.uuidString)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Text("\(run.eventCount) Events")
                        .font(.headline)
                    Text("Duration: \(run.endTime.timeIntervalSince(run.startTime), specifier: "%.3f")s")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // Event List (Span Tree)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(run.events) { event in
                        EventRowView(event: event, run: run)
                    }
                }
                .padding(.vertical)
            }
        }
    }
}

struct EventRowView: View {
    let event: RawTraceEvent
    let run: RawTraceRun
    
    // Compute indentation level recursively
    var indentLevel: Int {
        var level = 0
        var currentParentSpanID = event.parentSpanID
        
        while let pid = currentParentSpanID, 
              let parentEvent = run.events.first(where: { $0.spanID == pid }) {
            level += 1
            currentParentSpanID = parentEvent.parentSpanID
        }
        return level
    }
    
    var priorityColor: Color {
        switch event.priority {
        case 3: return .red      // Critical
        case 2: return .orange   // Structural
        case 1: return .blue     // Diagnostic
        default: return .gray    // Telemetry
        }
    }
    
    var body: some View {
        HStack(alignment: .top) {
            // Indentation
            if indentLevel > 0 {
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: CGFloat(indentLevel * 20))
            }
            
            // Event Dot
            Circle()
                .fill(priorityColor)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(event.typeIdentifier)
                        .font(.system(.subheadline, design: .monospaced))
                        .bold()
                    
                    Spacer()
                    
                    Text(event.engineName)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.2))
                        .cornerRadius(4)
                }
                
                Text(event.payloadJSON)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(4)
            }
            .padding(8)
            .background(Color(NSColor.textBackgroundColor))
            .cornerRadius(8)
            .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
    }
}
