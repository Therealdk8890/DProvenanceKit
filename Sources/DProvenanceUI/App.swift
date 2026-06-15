import SwiftUI
import AppKit

@main
struct DProvenanceUIApp: App {
    @StateObject private var storeManager = StoreManager()
    
    init() {
        // Force SPM executable to behave like a regular macOS GUI app
        NSApplication.shared.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(storeManager)
        }
        .windowStyle(HiddenTitleBarWindowStyle())
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Database...") {
                    storeManager.openDatabase()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}
