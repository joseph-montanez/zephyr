import Foundation
import SwiftSDL

#if os(Windows)
    import WinSDK
#endif

// =========================================================================
// MARK: - EnginePlatformDelegate
//
// Wraps platform-specific calls and window management, replacing
// Engine+Platform.swift.
// =========================================================================
@MainActor
public final class EnginePlatformDelegate {
    
    private unowned let engine: PhrostEngine

    public init(engine: PhrostEngine) {
        self.engine = engine
    }

    // MARK: - Window Management

    public func setWindowTitle(_ title: String) {
        SDL_SetWindowTitle(engine.window, title)
    }

    public func setWindowSize(_ w: Int32, _ h: Int32) {
        SDL_SetWindowSize(engine.window, w, h)
    }

    public func setWindowFullscreen(_ fullscreen: Bool) {
        SDL_SetWindowFullscreen(engine.window, fullscreen)
    }

    public func setWindowBordered(_ bordered: Bool) {
        SDL_SetWindowBordered(engine.window, bordered)
    }

    public func setWindowResizable(_ resizable: Bool) {
        SDL_SetWindowResizable(engine.window, resizable)
    }

    public func setWindowAlwaysOnTop(_ onTop: Bool) {
        SDL_SetWindowAlwaysOnTop(engine.window, onTop)
    }

    public func getWindowSize() -> (w: Int32, h: Int32) {
        return (engine.windowWidth, engine.windowHeight)
    }

    public func getWindowPixelSize() -> (w: Int32, h: Int32) {
        return (engine.pixelWidth, engine.pixelHeight)
    }

    /// Returns the name of the active SDL3 render backend.
    /// Common values: "direct3d11", "direct3d12", "vulkan", "opengl", "software".
    public func getRendererBackend() -> String {
        guard let driver = SDL_GetGPUDeviceDriver(engine.gpuDevice) else { return "unknown" }
        return String(cString: driver)
    }

    /// Returns the name of the active SDL3 video driver.
    /// e.g. "windows", "cocoa", "x11".
    public func getVideoDriver() -> String {
        guard let driver = SDL_GetCurrentVideoDriver() else { return "unknown" }
        return String(cString: driver)
    }
}
