import SwiftUI
import DProvenanceKit

struct RunListView: View {
    @EnvironmentObject var storeManager: StoreManager
    @Binding var selectedRunID: UUID?
    
    var body: some View {
        if storeManager.isLoading {
            ProgressView("Loading Database...")
        } else if let error = storeManager.errorMessage {
            Text(error)
                .foregroundColor(.red)
                .padding()
        } else {
            List(storeManager.runs, selection: $selectedRunID) { run in
                VStack(alignment: .leading, spacing: 4) {
                    Text(run.contextID)
                        .font(.headline)
                    
                    HStack {
                        Text("\(run.eventCount) events")
                        Spacer()
                        Text(run.startTime.formatted(date: .abbreviated, time: .shortened))
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                .tag(run.id)
            }
        }
    }
}
