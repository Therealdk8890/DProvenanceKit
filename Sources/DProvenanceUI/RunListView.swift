#if os(macOS)
import SwiftUI
import DProvenanceKit

public struct RunListView: View {
    @EnvironmentObject public var storeManager: StoreManager
    @Binding public var selectedRunID: UUID?
    
    public init(selectedRunID: Binding<UUID?>) {
        self._selectedRunID = selectedRunID
    }
    
    public var body: some View {
        if storeManager.isLoading {
            ProgressView("Loading Database...")
        } else if let error = storeManager.errorMessage {
            Text(error)
                .foregroundColor(.red)
                .padding()
        } else {
            List(storeManager.runs, id: \.runID, selection: $selectedRunID) { run in
                VStack(alignment: .leading, spacing: 4) {
                    Text(run.contextID)
                        .font(.headline)
                    
                    HStack {
                        Text("\(run.events.count) events")
                        Spacer()
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                .tag(run.runID)
            }
        }
    }
}
#endif
