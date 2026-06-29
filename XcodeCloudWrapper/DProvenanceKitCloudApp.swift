import SwiftUI
import DProvenanceKit

@main
struct DProvenanceKitCloudApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

private struct ContentView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("DProvenanceKit")
                .font(.title)
                .bold()
            Text("Xcode Cloud wrapper target")
                .foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(minWidth: 360, minHeight: 180)
    }
}
