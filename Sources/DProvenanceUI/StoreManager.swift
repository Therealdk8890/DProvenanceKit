import Foundation
import Combine
import AppKit
import DProvenanceKit

@MainActor
final class StoreManager: ObservableObject {
    @Published var store: RawTraceStore?
    @Published var runs: [RawTraceRun] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    
    func openDatabase() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.data, .database] // Or any extension if not strict
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        
        if panel.runModal() == .OK, let url = panel.url {
            loadDatabase(at: url)
        }
    }
    
    func loadDatabase(at url: URL) {
        isLoading = true
        errorMessage = nil
        runs = []
        
        Task {
            do {
                let newStore = try RawTraceStore(fileURL: url)
                let fetchedRuns = try await newStore.fetchAllRuns()
                
                self.store = newStore
                self.runs = fetchedRuns
                self.isLoading = false
            } catch {
                self.errorMessage = "Failed to load database: \(error.localizedDescription)"
                self.isLoading = false
            }
        }
    }
}
