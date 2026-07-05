import Foundation
import Combine
#if canImport(AppKit)
import AppKit
#endif
import DProvenanceKit

@MainActor
public final class StoreManager: ObservableObject {
    @Published public var store: RawTraceStore?
    @Published public var runs: [TraceRun<AnyTraceableEvent>] = []
    @Published public var isLoading = false
    @Published public var errorMessage: String?
    
    public init() {}
    
    #if canImport(AppKit)
    /// macOS only — file-picker UI. iOS hosts supply a URL to `loadDatabase(at:)`
    /// themselves (e.g. via a document picker).
    public func openDatabase() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.data, .database] // Or any extension if not strict
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            loadDatabase(at: url)
        }
    }
    #endif
    
    public func loadDatabase(at url: URL) {
        isLoading = true
        errorMessage = nil
        runs = []
        
        Task {
            do {
                let newStore = try RawTraceStore(fileURL: url)
                let fetchedRawRuns = try await newStore.fetchAllRuns()
                
                let mappedRuns = fetchedRawRuns.map { rawRun in
                    TraceRun<AnyTraceableEvent>(
                        runID: rawRun.runID,
                        contextID: rawRun.contextID,
                        events: rawRun.events.map { $0.toTraceEvent() }
                    )
                }
                
                self.store = newStore
                self.runs = mappedRuns
                self.isLoading = false
            } catch {
                self.errorMessage = "Failed to load database: \(error.localizedDescription)"
                self.isLoading = false
            }
        }
    }
}
