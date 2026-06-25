import Foundation
import ImGui
import SwiftSDL
import SwiftSDL_image
import SwiftSDL_ttf

// --- Platform-Specific Imports ---
#if os(Windows)
    import WinSDK
#elseif os(macOS)
    import AppKit
    import Darwin
#elseif os(Linux)
    import Glibc
#else
    import Darwin
#endif

// --- Core Engine ---
@MainActor
public final class PhrostEngine {
    /// Sentinel UUID used for snap-to-drawing-points results.
    /// When the cursor snaps to an in-progress drawing vertex, the SnapResult
    /// carries this handle rather than a real entity handle.
    internal static let drawingSnapSentinel = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    // MARK: Core SDL Pointers
    public let window: OpaquePointer
    internal let gpuDevice: OpaquePointer
    public let spriteManager: SpriteManager
    public let geometryManager: GeometryManager
    public private(set) var renderer: EngineRenderer!

    // MARK: - Managers
    public let camera: EngineCameraManager
    public let interaction: EngineInteractionManager
    public let snap: EngineSnapManager
    public let ui: EngineUIManager
    public let textManager: EngineTextManager
    public private(set) var textureManager: EngineTextureManager!
    public private(set) var platform: EnginePlatformDelegate!
    public private(set) var loopController: EngineLoopController!

    // MARK: Font Cache
    internal var fontCache: [String: OpaquePointer?] = [:]

    // MARK: UI Management
    internal var ctx: UnsafeMutablePointer<ImGuiContext>!
    internal var io: UnsafeMutablePointer<ImGuiIO>!

    /// Build font atlas
    internal var pixels: UnsafeMutablePointer<UInt8>?
    internal var width: Int32 = 0
    internal var height: Int32 = 0
    internal var bytesPerPixel: Int32 = 0
    internal var fontTexture: OpaquePointer?

    // MARK: State
    internal var running = true
    internal var windowWidth: Int32 = 0
    internal var windowHeight: Int32 = 0
    internal var pixelWidth: Int32 = 0
    internal var pixelHeight: Int32 = 0
    internal var scaleX: Float = 0
    internal var scaleY: Float = 0
    internal var currentDpiScale: Float = 1.0
    internal var currentUiScale: Float = 1.0

    // Grip infos for the current frame (computed once, used for hit-test and render).
    public internal(set) var _cachedCadGrips: [CADSelectionManager.CadGripInfo] = []
    internal var _cachedGripGeneration: Int = -1
    internal var _cachedSelectionGen: Int = -1
    internal var _cachedApplyGen: Int = -1

    // MARK: Command Processor
    /// Encapsulates all CAD command-line state and execution logic.
    public let commandProcessor: CADCommandProcessor

    // MARK: Tool / Selection State
    public let cadSelection = CADSelectionManager()
    public var currentTool: ToolMode = .select
    /// Whether the toolbar is visible.
    public var simplifyComplexBlocks: Bool = false

    /// Whether dense polylines should be simplified when loading.
    public var simplifyPolylines: Bool {
        get { DXFEntityConverter.simplifyPolylines }
        set { DXFEntityConverter.simplifyPolylines = newValue }
    }

    public func toggleSimplifyComplexBlocks() {
        simplifyComplexBlocks.toggle()
        _regenerationGeneration &+= 1
        cadSelection._selectionGeneration &+= 1
        print("[Engine] simplifyComplexBlocks: \(simplifyComplexBlocks)")
    }

    /// Toggle simplifying dense polylines.
    public func toggleSimplifyPolylines() {
        DXFEntityConverter.simplifyPolylines.toggle()
        // No need to increment regeneration generation because it only affects DXF import/parsing,
        // but let's touch the active document grid just in case.
        document.invalidateEntityGrid()
        print("[Engine] simplifyPolylines: \(DXFEntityConverter.simplifyPolylines)")
    }

    // MARK: - Double-Click Tracking for Block Editing

    /// Last left-click time (SDL ticks) for double-click detection.
    internal var _lastClickTime: UInt64 = 0
    /// Handle that was clicked last (for double-click detection).
    internal var _lastClickedHandle: UUID? = nil
    /// Screen position of last click (for double-click position check).
    internal var _lastClickScreenX: Float = 0
    internal var _lastClickScreenY: Float = 0

    // MARK: Tab Manager
    /// Tab manager — holds all open documents. Each file opens in its own tab.
    public let tabManager = TabManager()
    /// Convenience accessor for the active tab's CAD document.
    public var document: CADDocument { tabManager.activeDocument }
    /// The active tab's file URL, or nil for untitled documents.
    public var activeFileURL: URL? { tabManager.activeFileURL }
    /// Rendering bridge that converts CAD entities into SDL primitives.
    public let cadBridge = CADRendererBridge()
    // MARK: File Browser (Open)
    public var fileBrowser = ImGuiFileBrowser()
    public var saveFileBrowser = ImGuiFileBrowser()

    // Frame timing (ms). Printed every 60 frames to console.
    internal var _frameTimingCount: Int = 0
    internal var _frameTimingCadMs: Double = 0
    internal var _frameTimingPrimMs: Double = 0
    internal var _frameTimingImGuiMs: Double = 0

    /// Cached status bar left-side text. Set by render loop, read by UI.
    public var _cachedStatusLeft: String = ""
    public var _lastStatusEntityCount: Int = -1
    public var _lastStatusUndo: Int = -1
    public var _lastStatusRedo: Int = -1
    public var _lastStatusLayerID: UUID? = nil
    /// Status bar cache: last polar tracking state.
    public var _lastPolarEnabled: Bool = false
    /// Status bar cache: last OTRACK state.
    public var _lastOTrackEnabled: Bool = false
    /// Status bar cache: last extension snap state.
    public var _lastExtEnabled: Bool = false

    /// FPS string cache (recomputed every 15 frames).
    public var _cachedFpsText: String = ""
    public var _fpsCacheFrame: Int = 0

    /// Background regeneration task (nil when idle). Prevents overlapping regenerations.
    internal var _regenerationTask: Task<Void, Never>? = nil
    /// Monotonic token identifying the geometry state the renderer should display.
    /// Bumped on every tab switch and every in-tab edit. A background regeneration is
    /// tagged with the generation it was launched for; only results whose generation
    /// matches the current one are ever applied — stale results from a superseded tab or
    /// edit are discarded, never displayed. This is what prevents the tab-switch race
    /// where a slow large-file task could clobber the active tab's geometry (or leave a
    /// tab permanently showing the wrong/empty drawing).
    internal var _regenerationGeneration: Int = 0
    /// Generation a background task is currently computing (nil = none in flight).
    internal var _regenerationInFlight: Int? = nil
    /// Generation whose results are currently applied/displayed. -1 = nothing applied yet.
    internal var _appliedGeneration: Int = -1

    /// Render cache: avoid grid query + sort + map on static frames.
    internal var _cachedPrimitivesToRender: [RenderPrimitive] = []
    internal var _cachedUsingGrid: Bool = false
    internal var _cachedRenderGen: Int = -1
    internal var _cachedMutationGen: Int = -1
    internal var _cachedDisplayPaletteGen: Int = -1
    internal var _lastCameraZoom: Double = -1.0
    // MARK: Initialization
    public init?(
        title: String, width: Int32, height: Int32,
        flags: SDLWindowFlags = [],
        rendererBackend: String? = nil
    ) {
        SDL_SetMainReady()

        // Windows: mark the process as DPI-aware so SDL_WINDOW_HIGH_PIXEL_DENSITY
        // can create a true high-DPI window (pixelWidth = windowWidth * dpiScale).
        // Without this, pixelWidth == windowWidth and the OS bitmap-scales the
        // window, resulting in a blurry, incorrectly-sized UI.
        #if os(Windows)
        if !SetProcessDPIAware() {
            print("Warning: SetProcessDPIAware failed — high-DPI window may not work.")
        }
        #endif

        if !SDL_Init(SDL_INIT_VIDEO) {
            print("SDL_Init Error: \(String(cString: SDL_GetError()))")
            return nil
        }

        if !TTF_Init() {
            print("TTF_Init Error: \(String(cString: SDL_GetError()))")
            SDL_Quit()
            return nil
        }

        guard let window = SDL_CreateWindow(title, width, height, flags.rawValue) else {
            print("SDL_CreateWindow Error: \(String(cString: SDL_GetError()))")
            TTF_Quit()
            SDL_Quit()
            return nil
        }

        #if os(macOS)
        // Preserve the native NSWindow frame (including macOS rounded corners),
        // but let the SDL/ImGui content occupy the titlebar and hide the native
        // controls because TopChromeUI draws its own larger traffic lights.
        let windowProperties = SDL_GetWindowProperties(window)
        if let cocoaWindowPointer = SDL_GetPointerProperty(
            windowProperties,
            "SDL.window.cocoa.window",
            nil
        ) {
            let cocoaWindow = Unmanaged<NSWindow>
                .fromOpaque(cocoaWindowPointer)
                .takeUnretainedValue()
            cocoaWindow.styleMask.insert(.fullSizeContentView)
            cocoaWindow.titleVisibility = .hidden
            cocoaWindow.titlebarAppearsTransparent = true
            cocoaWindow.titlebarSeparatorStyle = .none
            cocoaWindow.standardWindowButton(.closeButton)?.isHidden = true
            cocoaWindow.standardWindowButton(.miniaturizeButton)?.isHidden = true
            cocoaWindow.standardWindowButton(.zoomButton)?.isHidden = true
        } else {
            print("Warning: SDL did not expose its native NSWindow.")
        }
        #endif

        // Initialize GPU Device
        #if os(macOS) || os(iOS)
            let formats = SDL_GPU_SHADERFORMAT_MSL
        #else
            let formats = SDL_GPU_SHADERFORMAT_DXIL
        #endif
        let gpuDevicePtr = SDL_CreateGPUDevice(formats, true, nil)

        guard let gpuDevice = gpuDevicePtr else {
            print("SDL_CreateGPUDevice Error: \(String(cString: SDL_GetError()))")
            SDL_DestroyWindow(window)
            TTF_Quit()
            SDL_Quit()
            return nil
        }

        // Enable text input so ImGui InputText widgets receive characters.
        SDL_StartTextInput(window)

        // Hide system cursor — we render an AutoCAD-style crosshair instead.
        SDL_HideCursor()

        if !SDL_ClaimWindowForGPUDevice(gpuDevice, window) {
            print("SDL_ClaimWindowForGPUDevice Error: \(String(cString: SDL_GetError()))")
            SDL_DestroyGPUDevice(gpuDevice)
            SDL_DestroyWindow(window)
            TTF_Quit()
            SDL_Quit()
            return nil
        }

        self.window = window
        self.gpuDevice = gpuDevice
        self.spriteManager = SpriteManager()
        self.ctx = nil
        self.io = nil
        self.geometryManager = GeometryManager()
        self.commandProcessor = CADCommandProcessor()

        self.camera = EngineCameraManager()
        self.interaction = EngineInteractionManager()
        self.snap = EngineSnapManager()
        self.ui = EngineUIManager()
        self.textManager = EngineTextManager()
        
        self.textureManager = EngineTextureManager(engine: self)
        self.platform = EnginePlatformDelegate(engine: self)
        
        self.loopController = EngineLoopController(engine: self)

        // Initialize GPU shaders & pipelines
        
        // Window hit test setup moved to after initialization
        #if os(Windows) || os(macOS)
        let hitTestCallback: SDL_HitTest = { win, area, data in
            guard let area = area else { return SDL_HITTEST_NORMAL }
            
            var w: Int32 = 0
            var h: Int32 = 0
            SDL_GetWindowSize(win, &w, &h)
            
            let x = area.pointee.x
            let y = area.pointee.y
            let border: Int32 = 8
            
            // Corner resizing
            if x < border && y < border { return SDL_HITTEST_RESIZE_TOPLEFT }
            if x > w - border && y < border { return SDL_HITTEST_RESIZE_TOPRIGHT }
            if x < border && y > h - border { return SDL_HITTEST_RESIZE_BOTTOMLEFT }
            if x > w - border && y > h - border { return SDL_HITTEST_RESIZE_BOTTOMRIGHT }
            
            // Border resizing
            if y < border { return SDL_HITTEST_RESIZE_TOP }
            if y > h - border { return SDL_HITTEST_RESIZE_BOTTOM }
            if x < border { return SDL_HITTEST_RESIZE_LEFT }
            if x > w - border { return SDL_HITTEST_RESIZE_RIGHT }
            
            // Draggable custom title bar (excluding window controls)
            #if os(macOS)
            let titleBarHeight: Int32 = 36
            #else
            let titleBarHeight: Int32 = 50
            #endif
            if y < titleBarHeight {
                #if os(Windows)
                if x > w - 138 {
                    return SDL_HITTEST_NORMAL
                }
                #else
                if x < 80 {
                    return SDL_HITTEST_NORMAL
                }
                #endif
                
                if let data = data {
                    let engine = Unmanaged<PhrostEngine>.fromOpaque(data).takeUnretainedValue()
                    if let exclude = engine.ui.topChromeExcludeRect {
                        if x >= exclude.x && x <= exclude.x + exclude.w && y >= exclude.y && y <= exclude.y + exclude.h {
                            return SDL_HITTEST_NORMAL
                        }
                    }
                }
                
                return SDL_HITTEST_DRAGGABLE
            }
            
            return SDL_HITTEST_NORMAL
        }
        _ = SDL_SetWindowHitTest(window, hitTestCallback, Unmanaged.passUnretained(self).toOpaque())

        #if os(Windows)
        // Set DWM rounded corners preference
        let hwnd = SDL_GetPointerProperty(SDL_GetWindowProperties(window), "SDL.window.win32.hwnd", nil)
        if let rawHwnd = hwnd {
            let winHwnd = unsafeBitCast(rawHwnd, to: HWND.self)
            var cornerPreference: DWORD = 2 // DWMWCP_ROUND
            _ = DwmSetWindowAttribute(
                winHwnd,
                33, // DWMWA_WINDOW_CORNER_PREFERENCE
                &cornerPreference,
                DWORD(MemoryLayout<DWORD>.size)
            )
        }
        #endif
        #endif
        // Set properties temporarily so self can be referenced in initGPUPipelines
        self.ctx = ImGuiCreateContext(nil)
        self.io = ImGuiGetIO()!
        self.io.pointee.ConfigFlags |= Int32(ImGuiConfigFlags_DockingEnable.rawValue)
        self.commandProcessor.configure(engine: self)

        // Register draw-order commands
        commandProcessor.registerFeatureCommand(
            name: "BRINGTOFRONT", aliases: ["BTF", "BRINGABOVE"],
            descriptor: DrawOrderDescriptors.bringToFront,
            factory: { BringToFrontCommand() })
        commandProcessor.registerFeatureCommand(
            name: "SENDTOBACK", aliases: ["STB", "SENDBELOW"],
            descriptor: DrawOrderDescriptors.sendToBack,
            factory: { SendToBackCommand() })
        commandProcessor.registerFeatureCommand(
            name: "BRINGABOVEOBJECTS", aliases: ["BAO"],
            descriptor: DrawOrderDescriptors.bringAboveObjects,
            factory: { DrawOrderReferenceCommand(mode: .bringAbove) })
        commandProcessor.registerFeatureCommand(
            name: "SENDUNDEROBJECTS", aliases: ["SUO"],
            descriptor: DrawOrderDescriptors.sendUnderObjects,
            factory: { DrawOrderReferenceCommand(mode: .sendUnder) })
        commandProcessor.registerFeatureCommand(
            name: "TEXTTOFRONT", aliases: ["TTF"],
            descriptor: DrawOrderDescriptors.textToFront,
            factory: { TextToFrontCommand() })
        commandProcessor.registerFeatureCommand(
            name: "HATCHTOBACK", aliases: ["HTB"],
            descriptor: DrawOrderDescriptors.hatchToBack,
            factory: { HatchToBackCommand() })

        // Initialize tab manager and wire callbacks (after ctx/io are initialized)
        tabManager.newTab()  // Start with one blank tab
        tabManager.getBackgroundColor = { [weak self] in
            guard let self = self else { return ColorRGBA.white }
            let r = UInt8(max(0.0, min(1.0, self.ui.backgroundColor.r)) * 255.0)
            let g = UInt8(max(0.0, min(1.0, self.ui.backgroundColor.g)) * 255.0)
            let b = UInt8(max(0.0, min(1.0, self.ui.backgroundColor.b)) * 255.0)
            let a = UInt8(max(0.0, min(1.0, self.ui.backgroundColor.a)) * 255.0)
            return ColorRGBA(r: r, g: g, b: b, a: a)
        }
        tabManager.captureCameraState = { [weak self] in
            guard let self = self else { return CameraState.default }
            return CameraState(offsetX: self.camera.offset.x, offsetY: self.camera.offset.y,
                               zoom: self.camera.zoom, rotation: self.camera.rotation)
        }
        tabManager.applyCameraState = { [weak self] state in
            guard let self = self else { return }
            self.camera.offset = (state.offsetX, state.offsetY)
            self.camera.zoom = state.zoom
            self.camera.rotation = state.rotation
        }
        tabManager.onActiveTabChanged = { [weak self] in
            guard let self else { return }
            self._regenerationTask?.cancel()
            self._regenerationTask = nil
            self._regenerationInFlight = nil
            self.cadBridge.cancelPending()
            self.renderer._vbBuildTask?.cancel()
            self.renderer._vbBuildTask = nil
            self.renderer.vbBuilder.cancelPending()
            // Supersede any in-flight / last-applied generation so the render loop launches a
            // fresh regeneration for the newly active tab and applies ONLY its results.
            self._regenerationGeneration &+= 1
            self._appliedGeneration = -1
            self.cadSelection.clearSelection()
            self.snap.snapTrackingEngine.clear()
        }

        self.renderer = EngineRenderer(engine: self)
        if !self.renderer.initGPUPipelines() {
            print("initGPUPipelines failed.")
            SDL_ReleaseWindowFromGPUDevice(gpuDevice, window)
            SDL_DestroyGPUDevice(gpuDevice)
            SDL_DestroyWindow(window)
            TTF_Quit()
            SDL_Quit()
            return nil
        }

        // GUI — DPI scaling
        let dpiScale = SDL_GetWindowDisplayScale(window)
        var initWinW: Int32 = 0, initWinH: Int32 = 0, initPixW: Int32 = 0, initPixH: Int32 = 0
        SDL_GetWindowSize(window, &initWinW, &initWinH)
        SDL_GetWindowSizeInPixels(window, &initPixW, &initPixH)
        let fbScale = (initWinW > 0) ? Float(initPixW) / Float(initWinW) : 1.0

        updateScale(dpiScale: dpiScale, fbScale: fbScale, force: true)

        print("Zephyr Initialized Successfully")
    }

    // MARK: Deinitialization
    deinit {
        MainActor.assumeIsolated {
            renderer.performCleanup()
        }
    }

    /// Delete all selected objects from the CAD document.
    public func deleteSelected() {
        cadSelection.deleteSelected(in: tabManager.activeDocument)
        tabManager.markActiveDirty()
    }

    /// Select all visible CAD entities.
    public func selectAll() {
        cadSelection.selectAll(in: tabManager.activeDocument)
    }

    /// Zoom to fit all CAD entities in the scene.
    public func zoomExtents() {
        var minX = Double.infinity
        var minY = Double.infinity
        var maxX = -Double.infinity
        var maxY = -Double.infinity
        var hasObjects = false

        // Use zero-allocation entitiesView
        for entity in tabManager.activeDocument.entitiesView {
            guard let bb = entity.worldBoundingBox else { continue }
            hasObjects = true
            minX = min(minX, bb.min.x)
            minY = min(minY, bb.min.y)
            maxX = max(maxX, bb.max.x)
            maxY = max(maxY, bb.max.y)
        }

        guard hasObjects else { return }

        let pad = 40.0
        minX -= pad
        minY -= pad
        maxX += pad
        maxY += pad

        let objW = maxX - minX
        let objH = maxY - minY
        let viewW = Double(windowWidth)
        let viewH = Double(windowHeight)

        let zoomX = viewW / objW
        let zoomY = viewH / objH
        camera.zoom = min(zoomX, zoomY)
        camera.offset = ((minX + maxX) / 2.0, (minY + maxY) / 2.0)
    }

    // MARK: - ImGui Frame Callback

    /// Closure called each frame between ImGuiNewFrame and ImGuiRender.
    /// Override this to add custom ImGui widgets (property panels, toolbars, etc.).
    public var imguiFrameCallback: (() -> Void)?

    // MARK: - Stop Engine

    public func stop() {
        self.running = false
    }

    internal func setupFontAtlas(dpiScale: Float, uiScale: Float) {
        let atlas = io.pointee.Fonts!
        
        // Release old GPU texture if any
        if let oldTex = self.fontTexture {
            SDL_ReleaseGPUTexture(self.gpuDevice, oldTex)
            self.fontTexture = nil
        }
        
        // Clear existing fonts in atlas
        ImFontAtlas_Clear(atlas)
        
        // imgui 1.92.x: Build font atlas with CJK support.
        igImFontAtlasBuildInit(atlas)

        // Build glyph ranges: Basic Latin + Japanese (Hiragana, Katakana, common Kanji).
        let rangesBuilder = ImFontGlyphRangesBuilder_ImFontGlyphRangesBuilder()!
        defer { ImFontGlyphRangesBuilder_destroy(rangesBuilder) }

        // Pairs of (start, end) ImWchar codepoints, 0-terminated.
        let cjkRanges: [ImWchar] = [
            0x0020, 0x00FF,   // Basic Latin + Latin-1 Supplement
            0x0370, 0x03FF,   // Greek and Coptic
            0x0400, 0x04FF,   // Cyrillic
            0x2000, 0x206F,   // General Punctuation
            0x2100, 0x214F,   // Letterlike Symbols
            0x2190, 0x21FF,   // Arrows
            0x2200, 0x22FF,   // Mathematical Operators
            0x2500, 0x257F,   // Box Drawing
            0x2580, 0x259F,   // Block Elements
            0x25A0, 0x25FF,   // Geometric Shapes
            0x2600, 0x26FF,   // Misc Symbols
            0x3000, 0x303F,   // CJK Symbols and Punctuation
            0x3040, 0x309F,   // Hiragana
            0x30A0, 0x30FF,   // Katakana
            0x3100, 0x312F,   // Bopomofo
            0x3130, 0x318F,   // Hangul Compatibility Jamo
            0x31F0, 0x31FF,   // Katakana Phonetic Extensions
            0xFF00, 0xFFEF,   // Halfwidth and Fullwidth Forms
            0,                // Terminator
        ]
        cjkRanges.withUnsafeBufferPointer { ptr in
            ImFontGlyphRangesBuilder_AddRanges(rangesBuilder, ptr.baseAddress!)
        }

        // Build the ranges vector
        var outRanges = ImVector_ImWchar()
        ImFontGlyphRangesBuilder_BuildRanges(rangesBuilder, &outRanges)
        let glyphRangesPtr = outRanges.Data  // ImWchar* to use with AddFontFromFileTTF

        let exePath = Bundle.main.executableURL?.deletingLastPathComponent().path ?? FileManager.default.currentDirectoryPath
        let fontsDir = exePath + "/Fonts"

        let geistReg = fontsDir + "/Geist-Regular.ttf"
        let geistBold = fontsDir + "/Geist-SemiBold.ttf"
        let geistSmall = fontsDir + "/Geist-Regular.ttf"
        let geistMono = fontsDir + "/GeistMono-Medium.ttf"
        let geistMonoRegular = fontsDir + "/GeistMono-Regular.ttf"
        let geistMedium = fontsDir + "/Geist-Medium.ttf"
        let geistLarge = fontsDir + "/Geist-Medium.ttf"

        let fbScale = (uiScale > 0.001) ? dpiScale / uiScale : 1.0
        var loadedFont = false

        if FileManager.default.fileExists(atPath: geistReg) {
            let fontConfigPtr = ImFontConfig_ImFontConfig()!
            fontConfigPtr.pointee.RasterizerDensity = fbScale
            _ = ImFontAtlas_AddFontFromFileTTF(atlas, geistReg, 16.0 * uiScale, fontConfigPtr, glyphRangesPtr)
            ImFontConfig_destroy(fontConfigPtr)
            loadedFont = true
            
            if FileManager.default.fileExists(atPath: geistBold) {
                let boldConfig = ImFontConfig_ImFontConfig()!
                boldConfig.pointee.RasterizerDensity = fbScale
                self.ui.boldFont = ImFontAtlas_AddFontFromFileTTF(atlas, geistBold, 16.0 * uiScale, boldConfig, glyphRangesPtr)
                ImFontConfig_destroy(boldConfig)
            }
            
            let smallConfig = ImFontConfig_ImFontConfig()!
            smallConfig.pointee.RasterizerDensity = fbScale
            self.ui.smallFont = ImFontAtlas_AddFontFromFileTTF(atlas, geistSmall, 13.0 * uiScale, smallConfig, glyphRangesPtr)
            ImFontConfig_destroy(smallConfig)

            if FileManager.default.fileExists(atPath: geistMono) {
                let monoConfig = ImFontConfig_ImFontConfig()!
                monoConfig.pointee.RasterizerDensity = fbScale
                self.ui.monoFont = ImFontAtlas_AddFontFromFileTTF(atlas, geistMono, 14.0 * uiScale, monoConfig, glyphRangesPtr)
                ImFontConfig_destroy(monoConfig)

                let commandTitleConfig = ImFontConfig_ImFontConfig()!
                commandTitleConfig.pointee.RasterizerDensity = fbScale
                self.ui.commandTitleFont = ImFontAtlas_AddFontFromFileTTF(
                    atlas, geistMono, 16.0 * uiScale, commandTitleConfig, glyphRangesPtr)
                ImFontConfig_destroy(commandTitleConfig)
            }

            if FileManager.default.fileExists(atPath: geistMonoRegular) {
                let commandPillConfig = ImFontConfig_ImFontConfig()!
                commandPillConfig.pointee.RasterizerDensity = fbScale
                self.ui.commandPillFont = ImFontAtlas_AddFontFromFileTTF(
                    atlas, geistMonoRegular, 14.0 * uiScale, commandPillConfig, glyphRangesPtr)
                ImFontConfig_destroy(commandPillConfig)
            }

            if FileManager.default.fileExists(atPath: geistMedium) {
                let commandDescriptionConfig = ImFontConfig_ImFontConfig()!
                commandDescriptionConfig.pointee.RasterizerDensity = fbScale
                self.ui.commandDescriptionFont = ImFontAtlas_AddFontFromFileTTF(
                    atlas, geistMedium, 13.0 * uiScale, commandDescriptionConfig, glyphRangesPtr)
                ImFontConfig_destroy(commandDescriptionConfig)
            }

            if FileManager.default.fileExists(atPath: geistLarge) {
                let largeConfig = ImFontConfig_ImFontConfig()!
                largeConfig.pointee.RasterizerDensity = fbScale
                self.ui.largeFont = ImFontAtlas_AddFontFromFileTTF(atlas, geistLarge, 20.0 * uiScale, largeConfig, glyphRangesPtr)
                
                let titleConfig = ImFontConfig_ImFontConfig()!
                titleConfig.pointee.RasterizerDensity = fbScale
                self.ui.titleFont = ImFontAtlas_AddFontFromFileTTF(atlas, geistLarge, 34.0 * uiScale, titleConfig, glyphRangesPtr)
                
                ImFontConfig_destroy(largeConfig)
                ImFontConfig_destroy(titleConfig)
            }
            print("Loaded Geist fonts.")
        }

        // Try Arial Unicode MS first (best coverage), then Malgun Gothic, then Arial.
        let fontPaths = [
            "C:\\Windows\\Fonts\\segoeui.ttf",
            "C:\\Windows\\Fonts\\ARIALUNI.ttf",
            "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
            "/Library/Fonts/Arial Unicode.ttf",
            "C:\\Windows\\Fonts\\malgun.ttf",
            "C:\\Windows\\Fonts\\arial.ttf",
            "/System/Library/Fonts/Supplemental/Arial.ttf",
            "/Library/Fonts/Arial.ttf",
        ]
        
        for fontPath in fontPaths {
            if FileManager.default.fileExists(atPath: fontPath) {
                let fontConfigPtr = ImFontConfig_ImFontConfig()!
                fontConfigPtr.pointee.RasterizerDensity = fbScale
                if loadedFont {
                    fontConfigPtr.pointee.MergeMode = true
                }
                _ = ImFontAtlas_AddFontFromFileTTF(atlas, fontPath, 16.0 * uiScale, fontConfigPtr, glyphRangesPtr)
                ImFontConfig_destroy(fontConfigPtr)
                loadedFont = true
                print("Loaded fallback font for CJK support: \(fontPath)")
                
                // If we didn't load Geist bold, load system bold
                if self.ui.boldFont == nil {
                    var boldFontPath = fontPath.replacingOccurrences(of: "segoeui.ttf", with: "segoeuib.ttf")
                    if boldFontPath == fontPath {
                        boldFontPath = fontPath.replacingOccurrences(of: "arial.ttf", with: "arialbd.ttf")
                    }
                    if FileManager.default.fileExists(atPath: boldFontPath) {
                        let boldFontConfigPtr = ImFontConfig_ImFontConfig()!
                        boldFontConfigPtr.pointee.RasterizerDensity = fbScale
                        self.ui.boldFont = ImFontAtlas_AddFontFromFileTTF(atlas, boldFontPath, 16.0 * uiScale, boldFontConfigPtr, glyphRangesPtr)
                        ImFontConfig_destroy(boldFontConfigPtr)
                        print("Loaded bold font at: \(boldFontPath)")
                    }
                }
                break
            }
        }

        if loadedFont {
            igImFontAtlasBuildMain(atlas)
        } else {
            // Fallback: build with default font only (ASCII-only)
            print("Warning: No CJK-capable font found. Using default font (ASCII only).")
            igImFontAtlasBuildMain(atlas)
        }

        // Extract font texture pixel data.
        if let texData = atlas.pointee.TexData {
            let w = texData.pointee.Width
            let h = texData.pointee.Height
            let bpp = texData.pointee.BytesPerPixel
            let useColors = texData.pointee.UseColors
            print("Font atlas: \(w)x\(h), \(bpp) bpp, useColors=\(useColors)")

            var tex: OpaquePointer? = nil
            if let src = texData.pointee.Pixels {
                if bpp == 1 {
                    let pixelCount = Int(w * h)
                    var rgba = [UInt8](repeating: 255, count: pixelCount * 4)
                    for i in 0..<pixelCount {
                        let a = src[i]
                        rgba[i * 4 + 0] = 255
                        rgba[i * 4 + 1] = 255
                        rgba[i * 4 + 2] = 255
                        rgba[i * 4 + 3] = a
                    }

                    tex = rgba.withUnsafeBytes { ptr in
                        renderer.uploadToGPUTexture(width: w, height: h, pixelData: ptr.baseAddress!)
                    }

                } else {
                    tex = renderer.uploadToGPUTexture(width: w, height: h, pixelData: src)
                }
            }
            if tex == nil {
                print("Failed to create font texture!")
            }
            self.fontTexture = tex
            if let tex = tex {
                ImTextureDataSetTexID(texData, UInt64(UInt(bitPattern: tex)))
            }
        } else {
            print("Warning: Font atlas TexData is nil!")
            self.fontTexture = nil
        }
        
        atlas.pointee.TexIsBuilt = true
    }

    /// Recompute UI scale and rebuild font atlas if display scale or framebuffer density changes.
    public func updateScale(dpiScale: Float, fbScale: Float, force: Bool = false) {
        let newUiScale = (fbScale > 0.001) ? dpiScale / fbScale : 1.0
        
        let oldUiScale = self.currentUiScale
        let oldDpiScale = self.currentDpiScale
        
        if force || newUiScale != oldUiScale || dpiScale != oldDpiScale {
            let factor = newUiScale / oldUiScale
            if factor != 1.0 {
                if let style = ImGuiGetStyle() {
                    ImGuiStyleScaleAllSizes(style, factor)
                }
            }
            
            self.currentDpiScale = dpiScale
            self.currentUiScale = newUiScale
            
            setupFontAtlas(dpiScale: dpiScale, uiScale: newUiScale)
            camera.renderGeneration &+= 1
        }
    }
}
