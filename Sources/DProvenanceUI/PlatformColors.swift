import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Semantic background colors bridged per platform so every view in this
/// target compiles for both macOS (AppKit) and iOS (UIKit). The package
/// declares .iOS(.v16); nothing in this target may import AppKit unguarded.
extension Color {
    static var dpkControlBackground: Color {
        #if canImport(AppKit)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(UIColor.secondarySystemBackground)
        #endif
    }

    static var dpkWindowBackground: Color {
        #if canImport(AppKit)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(UIColor.systemGroupedBackground)
        #endif
    }

    static var dpkTextBackground: Color {
        #if canImport(AppKit)
        Color(nsColor: .textBackgroundColor)
        #else
        Color(UIColor.systemBackground)
        #endif
    }
}
