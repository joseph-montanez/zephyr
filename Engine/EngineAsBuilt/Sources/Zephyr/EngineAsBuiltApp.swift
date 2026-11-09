// MARK: - ZephyrApp
//
// The main entry point for the Zephyr CAD application.
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
//   - Resizable window with the Zephyr CAD title

import ZephyrCore
import Foundation
import ImGui

/// The main application struct serving as the program entry point (via @main).
/// All work is isolated to the main actor since ImGui and the PhrostEngine
/// must be accessed exclusively from the main thread.
@main
@MainActor
struct ZephyrApp {
    /// Application entry point.
    /// Initializes the rendering engine, registers commands and callbacks,
    /// applies the UI theme, and starts the main render loop.
    @MainActor
    static func main() {
        print("Starting Zephyr...")

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
            let flags: SDLWindowFlags = [.resizable, .highPixelDensity, .borderless, .maximized]
        #elseif os(macOS)
            // Keep a native titled window so macOS supplies its rounded frame,
            // then make its titlebar transparent and full-size in PhrostEngine.
            let flags: SDLWindowFlags = [.resizable, .highPixelDensity, .maximized]
        #else
            let flags: SDLWindowFlags = [.resizable, .highPixelDensity, .maximized]
        #endif

        guard let engine = PhrostEngine(
            title: "Zephyr CAD",
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

        // Ribbon: the command chrome is defined in AutoLISP. Seed the user
        // copy on first run, then load it — evaluation runs off-actor and the
        // UI pumps the result once per frame, so startup never blocks.
        setupRibbon(on: engine)

        // Wire up file browser callbacks for opening and saving DXF/EAB files.
        AppFileCallbacks.configure(on: engine)
        engine.windowCloseRequestHandler = { [weak engine] in
            guard let engine else { return true }
            return AppUI.requestWindowClose(engine: engine)
        }

        // The main ImGui frame callback — called once per frame by the engine
        // to render all UI panels, toolbars, and the command line.
        engine.imguiFrameCallback = { AppUI.render(engine: engine) }

        // Apply the default dark/light theme styling to all ImGui windows.
        engine.ui.applyTheme()

        // Optional in-process MCP server for AI-driven CAD work. The server
        // speaks HTTP JSON-RPC on localhost; the frame hook below drains
        // its loop-thread tasks every iteration (rendered or idle).
        let mcpPort = Self.mcpPortFlag()
        if let mcpPort {
            do {
                try MCPServer.shared.attachAndStart(port: mcpPort, engine: engine)
            } catch {
                // An explicit --mcp-port must either serve or fail loudly:
                // running on silently MCP-less lets a client attach to a
                // stale port twin (or nobody), which is undebuggable.
                print("MCP server failed to start on port \(mcpPort): \(error)")
                exit(1)
            }
        }

        print("Starting render loop...")
        engine.loopController.run(updateBlock: mcpPort != nil ? {
            MCPServer.shared.drainFrame()
        } : nil)
        print("Engine shut down.")
    }

    /// Reads `--mcp-port N` from the command line (nil = MCP server off).
    private static func mcpPortFlag() -> Int? {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--mcp-port"),
              flag + 1 < args.count,
              let port = Int(args[flag + 1]), (1...65535).contains(port)
        else { return nil }
        return port
    }

    /// Attaches the loader that owns the live ribbon model.
    private static func setupRibbon(on engine: PhrostEngine) {
        engine.commandProcessor.synchronizeToggleSysvars(engine: engine)
        let loader = RibbonSpecLoader(
            processor: engine.commandProcessor,
            documentProvider: { [weak engine] in
                engine?.document ?? CADDocument()
            },
            selectionProvider: { [weak engine] in
                engine?.cadSelection ?? CADSelectionManager()
            })
        loader.output = { text in print(text, terminator: "") }
        engine.ribbonLoader = loader
        loader.baselineFileTimestamp()
        loader.requestReload(reason: "startup")
    }
}