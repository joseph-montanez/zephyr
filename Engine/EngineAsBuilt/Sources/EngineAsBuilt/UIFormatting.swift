import EngineAsBuiltCore
import Foundation
import ImGui

// MARK: - UIFormatting
//
// Utility functions for formatting values into display strings
// used across all ImGui UI panels.
//
// Currently provides color-to-hex-string conversion for displaying
// RGBA colors in property panels and geometry inspectors.

@MainActor
struct UIFormatting {
    /// Formats a ColorRGBA into a CSS-style hex string (e.g., "#FF00AA").
    /// Alpha channel is ignored; only RGB components are included.
    static func colorStr(_ c: ColorRGBA) -> String {
        String(format: "#%02X%02X%02X", c.r, c.g, c.b)
    }
}
