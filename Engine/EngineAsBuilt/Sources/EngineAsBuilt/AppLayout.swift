import EngineAsBuiltCore
import Foundation
import ImGui

// MARK: - AppLayout
//
// Defines the pixel layout constants for all UI chrome regions.
// These computed dimensions are used to position toolbars, panels,
// the command line, and status bar consistently across frames.
//
// Layout stack (top to bottom):
//   1. Toolbar
//   2. Tab Bar
//   3. (canvas area — not measured here)
//   4. Command Line (bottom)
//   5. Status Bar (very bottom)

@MainActor
struct AppLayout {
    /// Height of the tab bar (ImGui frame height + 14px padding).
    static var tabBarHeight: Float { ImGuiGetFrameHeight() + 14 }
    /// Height of the custom top chrome containing macOS window controls and document title.
    static var topChromeHeight: Float {
        #if os(macOS)
        return 36.0
        #else
        return 50.0
        #endif
    }
    
    // Legacy aliases for components not yet redesigned
    static var toolbarHeight: Float { 0 }
    static var belowToolbarY: Float { belowChromeY }

    /// Height of the command-line input strip.
    static var commandLineHeight: Float { ImGuiGetFrameHeight() + 8 }
    /// Height of the thin status bar at the bottom.
    static var statusBarHeight: Float { ImGuiGetTextLineHeight() + 12 }
    
    /// Y-coordinate just below the top chrome — where the tab bar starts.
    static var belowChromeY: Float { topChromeHeight }
    /// Y-coordinate just below the tab bar — where the canvas area begins.
    static var belowTabBarY: Float { topChromeHeight + tabBarHeight }
}
