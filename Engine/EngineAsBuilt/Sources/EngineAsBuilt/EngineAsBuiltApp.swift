// MARK: - EngineAsBuiltApp
//
// The main entry point for the EngineAsBuilt CAD application.
// This @main struct initializes the PhrostEngine rendering engine,
// configures all subsystems (commands, file callbacks, theme),
// and enters the main render loop.
//
// Platform-specific logic:
//   - Windows: Uses the D3D12 renderer backend via direct3d12
//   - macOS/Linux: Uses the default Metal/OpenGL backends
//
// Window defaults:
//   - 1920x1080 resolution with high-DPI support
//   - Resizable window with the EngineAsBuilt CAD title

import EngineAsBuiltCore
import Foundation
import ImGui

/// The main application struct serving as the program entry point (via @main).
/// All work is isolated to the main actor since ImGui and the PhrostEngine
/// must be accessed exclusively from the main thread.
@main
@MainActor
struct EngineAsBuiltApp {
    /// Application entry point.
    /// Initializes the rendering engine, registers commands and callbacks,
    /// applies the UI theme, and starts the main render loop.
    @MainActor
    static func main() {
        print("Starting EngineAsBuilt...")

        // On Windows ARM64/AMD64, explicitly request D3D12 for best compatibility.
        // Other platforms use the engine's default backend (Metal on macOS, OpenGL/Vulkan on Linux).
        #if os(Windows)
            let backend: String? = "direct3d12"
        #else
            let backend: String? = nil
        #endif

        // Create the rendering engine with the CAD window configuration.
        // Flags: resizable window with high-pixel-density (Retina/HiDPI) support.
        #if os(Windows)
            let flags: SDLWindowFlags = [.resizable, .highPixelDensity, .borderless]
        #elseif os(macOS)
            // Keep a native titled window so macOS supplies its rounded frame,
            // then make its titlebar transparent and full-size in PhrostEngine.
            let flags: SDLWindowFlags = [.resizable, .highPixelDensity]
        #else
            let flags: SDLWindowFlags = [.resizable, .highPixelDensity]
        #endif

        guard let engine = PhrostEngine(
            title: "EngineAsBuilt CAD",
            width: 1920,
            height: 1080,
            flags: flags,
            rendererBackend: backend
        ) else {
            print("Failed to initialize engine.")
            return
        }

        print("Engine created successfully.")
        print("Renderer backend: \(engine.platform.getRendererBackend())")
        print("Video driver: \(engine.platform.getVideoDriver())")

        // Register all built-in CAD commands (LINE, CIRCLE, ARC, etc.)
        // and feature commands like CLEANSPECKLES.
        AppCommandRegistration.register(on: engine)

        // Wire up file browser callbacks for opening and saving DXF/EAB files.
        AppFileCallbacks.configure(on: engine)

        // The main ImGui frame callback — called once per frame by the engine
        // to render all UI panels, toolbars, and the command line.
        engine.imguiFrameCallback = { AppUI.render(engine: engine) }

        // Apply the default dark/light theme styling to all ImGui windows.
        engine.ui.applyTheme()

        print("Starting render loop...")
        engine.loopController.run()
        print("Engine shut down.")
    }
}
