import SwiftUI
import DProvenanceKit

struct ContentView: View {
    @EnvironmentObject var storeManager: StoreManager
    @State private var selectedRunID: UUID?
    
    var body: some View {
        NavigationSplitView {
            RunListView(selectedRunID: $selectedRunID)
                .navigationTitle("Traces")
        } detail: {
            if let selectedRunID = selectedRunID,
               let run = storeManager.runs.first(where: { $0.id == selectedRunID }) {
                RunDetailView(run: run)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "cpu")
                        .font(.system(size: 64))
                        .foregroundColor(.secondary)
                    
                    if storeManager.store == nil {
                        Text("No Database Loaded")
                            .font(.headline)
                        Button("Open Traces.sqlite") {
                            storeManager.openDatabase()
                        }
                    } else {
                        Text("Select a Run to view details")
                            .font(.headline)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }
}
