import Foundation

// =========================================================================
// MARK: - SDLWindowFlags
//
// Swift OptionSet wrapper for SDL3 window creation flags.
// Mirrors the C-level SDL_WINDOW_* macros from SDL_video.h.
// Used when constructing a PhrostEngine to specify window behavior:
// fullscreen, resizable, borderless, high-DPI, always-on-top, etc.

/// SDL3 window creation flags as Swift constants.
/// Mirrors the C `SDL_WINDOW_*` macros from SDL_video.h.
/// Use with `PhrostEngine.init(flags:)`.
public struct SDLWindowFlags: OptionSet, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static let fullscreen        = SDLWindowFlags(rawValue: 0x0000_0000_0000_0001)
    public static let openGL            = SDLWindowFlags(rawValue: 0x0000_0000_0000_0002)
    public static let hidden            = SDLWindowFlags(rawValue: 0x0000_0000_0000_0008)
    public static let borderless        = SDLWindowFlags(rawValue: 0x0000_0000_0000_0010)
    public static let resizable         = SDLWindowFlags(rawValue: 0x0000_0000_0000_0020)
    public static let minimized         = SDLWindowFlags(rawValue: 0x0000_0000_0000_0040)
    public static let maximized         = SDLWindowFlags(rawValue: 0x0000_0000_0000_0080)
    public static let highPixelDensity  = SDLWindowFlags(rawValue: 0x0000_0000_0000_2000)
    public static let alwaysOnTop       = SDLWindowFlags(rawValue: 0x0000_0000_0001_0000)
    public static let utility           = SDLWindowFlags(rawValue: 0x0000_0000_0002_0000)
    public static let tooltip           = SDLWindowFlags(rawValue: 0x0000_0000_0004_0000)
    public static let popupMenu         = SDLWindowFlags(rawValue: 0x0000_0000_0008_0000)
    public static let vulkan            = SDLWindowFlags(rawValue: 0x0000_0000_1000_0000)
    public static let metal             = SDLWindowFlags(rawValue: 0x0000_0000_2000_0000)
    public static let transparent       = SDLWindowFlags(rawValue: 0x0000_0000_4000_0000)
    public static let notFocusable      = SDLWindowFlags(rawValue: 0x0000_0000_8000_0000)
}
