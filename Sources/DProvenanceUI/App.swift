import SwiftUI

@main
struct DProvenanceUIApp: App {
    @StateObject private var storeManager = StoreManager()
    
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
