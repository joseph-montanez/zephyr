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

// --- UI Font Language Profiles ---
public enum UIFontLanguageProfile: String, CaseIterable, Sendable {
    case standard = "STANDARD"
    case japanese = "JAPANESE"
    case korean = "KOREAN"
    case chinese = "CHINESE"
    case arabic = "ARABIC"
    case hebrew = "HEBREW"
    case thai = "THAI"
    case devanagari = "DEVANAGARI"

    public static func parse(_ raw: String) -> UIFontLanguageProfile? {
        let normalized = raw
            .uppercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")

        switch normalized {
        case "STANDARD", "DEFAULT", "LATIN", "ENGLISH", "WESTERN", "EN":
            return .standard
        case "JAPANESE", "JAPAN", "JA", "JP":
            return .japanese
        case "KOREAN", "KOREA", "KO", "KR":
            return .korean
        case "CHINESE", "CHINESE_SIMPLIFIED", "SIMPLIFIED_CHINESE", "ZH", "ZH_CN", "CN":
            return .chinese
        case "ARABIC", "AR":
            return .arabic
        case "HEBREW", "HE", "IW":
            return .hebrew
        case "THAI", "TH":
            return .thai
        case "DEVANAGARI", "HINDI", "HI":
            return .devanagari
        default:
            return nil
        }
    }

    internal var additionalGlyphRanges: [ImWchar] {
        switch self {
        case .standard:
            return []
        case .japanese:
            return [
                0x3000, 0x303F,
                0x3040, 0x309F,
                0x30A0, 0x30FF,
                0x31F0, 0x31FF,
                0x4E00, 0x9FFF,
            ]
        case .korean:
            return [
                0x1100, 0x11FF,
                0x3130, 0x318F,
                0xA960, 0xA97F,
                0xAC00, 0xD7AF,
                0xD7B0, 0xD7FF,
            ]
        case .chinese:
            return [
                0x2E80, 0x2FFF,
                0x3000, 0x303F,
                0x3400, 0x4DBF,
                0x4E00, 0x9FFF,
                0xF900, 0xFAFF,
            ]
        case .arabic:
            return [
                0x0600, 0x06FF,
                0x0750, 0x077F,
                0x08A0, 0x08FF,
                0xFB50, 0xFDFF,
                0xFE70, 0xFEFF,
            ]
        case .hebrew:
            return [
                0x0590, 0x05FF,
                0xFB1D, 0xFB4F,
            ]
        case .thai:
            return [
                0x0E00, 0x0E7F,
            ]
        case .devanagari:
            return [
                0x0900, 0x097F,
                0xA8E0, 0xA8FF,
            ]
        }
    }

    internal var fallbackFontPaths: [String] {
        let general = [
            "C:\\Windows\\Fonts\\segoeui.ttf",
            "C:\\Windows\\Fonts\\ARIALUNI.TTF",
            "C:\\Windows\\Fonts\\arial.ttf",
            "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
            "/Library/Fonts/Arial Unicode.ttf",
            "/System/Library/Fonts/Supplemental/Arial.ttf",
            "/Library/Fonts/Arial.ttf",
            "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
            "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf",
        ]

        switch self {
        case .standard:
            return general
        case .japanese:
            return [
                "C:\\Windows\\Fonts\\YuGothR.ttc",
                "C:\\Windows\\Fonts\\meiryo.ttc",
                "C:\\Windows\\Fonts\\msgothic.ttc",
                "/System/Library/Fonts/ヒラギノ角ゴシック W3.ttc",
                "/System/Library/Fonts/ヒラギノ丸ゴ ProN W4.ttc",
                "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
                "/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc",
            ] + general
        case .korean:
            return [
                "C:\\Windows\\Fonts\\malgun.ttf",
                "/System/Library/Fonts/AppleSDGothicNeo.ttc",
                "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
                "/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc",
                "/usr/share/fonts/truetype/noto/NotoSansKR-Regular.otf",
            ] + general
        case .chinese:
            return [
                "C:\\Windows\\Fonts\\msyh.ttc",
                "C:\\Windows\\Fonts\\simsun.ttc",
                "/System/Library/Fonts/PingFang.ttc",
                "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
                "/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc",
                "/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc",
            ] + general
        case .arabic:
            return [
                "C:\\Windows\\Fonts\\segoeui.ttf",
                "C:\\Windows\\Fonts\\arial.ttf",
                "C:\\Windows\\Fonts\\Nirmala.ttf",
                "/System/Library/Fonts/GeezaPro.ttc",
                "/usr/share/fonts/truetype/noto/NotoSansArabic-Regular.ttf",
                "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
            ] + general
        case .hebrew:
            return [
                "C:\\Windows\\Fonts\\arial.ttf",
                "C:\\Windows\\Fonts\\segoeui.ttf",
                "/System/Library/Fonts/ArialHB.ttc",
                "/usr/share/fonts/truetype/noto/NotoSansHebrew-Regular.ttf",
                "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
            ] + general
        case .thai:
            return [
                "C:\\Windows\\Fonts\\leelawui.ttf",
                "C:\\Windows\\Fonts\\tahoma.ttf",
                "/System/Library/Fonts/Thonburi.ttc",
                "/usr/share/fonts/truetype/noto/NotoSansThai-Regular.ttf",
            ] + general
        case .devanagari:
            return [
                "C:\\Windows\\Fonts\\Nirmala.ttf",
                "/System/Library/Fonts/Kohinoor.ttc",
                "/usr/share/fonts/truetype/noto/NotoSansDevanagari-Regular.ttf",
            ] + general
        }
    }
}

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
    internal var uiGlyphRangesStorage: UnsafeMutablePointer<ImWchar>?
    internal var uiGlyphRangesStorageCount: Int = 0

    // MARK: State
    internal var running = true
    public internal(set) var windowWidth: Int32 = 0
    public internal(set) var windowHeight: Int32 = 0
    internal var pixelWidth: Int32 = 0
    internal var pixelHeight: Int32 = 0
    internal var scaleX: Float = 0
    internal var scaleY: Float = 0
    internal var currentDpiScale: Float = 1.0
    internal var currentUiScale: Float = 1.0
    /// The effective UI scale currently applied (auto or override).
    /// Custom UI drawing code should multiply hardcoded sizes by this value.
    public var effectiveUiScale: Float { currentUiScale }
    /// Manual UI scale override. nil = auto (derived from system DPI).
    /// Set via SETUISCALE command. 1.0 = 100%, 1.5 = 150%, etc.
    /// Setting to 0 or "auto" reverts to system-derived scale.
    public var uiScaleOverride: Float? = nil
    public private(set) var uiFontLanguageProfile: UIFontLanguageProfile = {
        guard let saved = UserDefaults.standard.string(forKey: "Zephyr.UIFontLanguageProfile"),
              let profile = UIFontLanguageProfile(rawValue: saved) else {
            return .standard
        }
        return profile
    }()
    /// Deferred rebuild flag — set by applyUiScaleOverride when called during a frame.
    /// The render loop checks this before ImGuiNewFrame() and performs the rebuild
    /// while the font atlas is unlocked.
    internal var _pendingUiScaleRebuild: (dpiScale: Float, fbScale: Float, force: Bool)? = nil

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

    /// When more than this many entities are selected, suppress all grips and
    /// show only selection outlines (mirrors AutoCAD GRIPOBJLIMIT).
    public var gripObjectMax: Int = 100
    /// Maximum number of grip squares drawn on screen (prevents ImGui 16-bit
    /// index buffer overflow). Default 1000 grips across all entities.
    public var gripMax: Int = 1000

    /// Divisor for adaptive spline tessellation chord tolerance.
    /// Chord tolerance = max(0.001, splineDiagonal / divisor).
    /// Lower = smoother curves (more segments). Default 5000.
    public var splineTessellationDivisor: Double = 5000.0

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

    // MARK: - Autosave
    public var autosaveIntervalMinutes: Double = 5.0
    internal var _autosaveAccumulator: Double = 0

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
    public var _lastStatusViewName: String = ""
    /// Status bar cache: last polar tracking state.
    public var _lastPolarEnabled: Bool = false
    /// Status bar cache: last OTRACK state.
    public var _lastOTrackEnabled: Bool = false
    /// Status bar cache: last extension snap state.
    public var _lastExtEnabled: Bool = false
    /// Status bar cache: last ortho state.
    public var _lastOrthoEnabled: Bool = false
    /// Track whether we were showing save progress last frame (to detect transition to idle).
    public var _lastHadSaveState: Bool = false

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
            let winHwnd = rawHwnd.assumingMemoryBound(to: HWND__.self)
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
            if let color = self.tabManager.activeViewBackgroundColor {
                self.ui.viewBackgroundOverride = SDL_FColor(
                    r: Float(color.r) / 255.0,
                    g: Float(color.g) / 255.0,
                    b: Float(color.b) / 255.0,
                    a: Float(color.a) / 255.0)
            } else {
                self.ui.viewBackgroundOverride = nil
            }
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
            self.tabManager.activeDocument.needsRegeneration = true
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
            uiGlyphRangesStorage?.deinitialize(count: uiGlyphRangesStorageCount)
            uiGlyphRangesStorage?.deallocate()
            uiGlyphRangesStorage = nil
            uiGlyphRangesStorageCount = 0
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

    /// Zoom to fit all visible, renderable CAD geometry in the unobscured viewport.
    public func zoomExtents() {
        guard let bounds = tabManager.activeDocument.renderableWorldBoundingBox() else {
            return
        }

        let rawWidth = max(0.0, bounds.max.x - bounds.min.x)
        let rawHeight = max(0.0, bounds.max.y - bounds.min.y)
        let dominantSpan = max(rawWidth, rawHeight)
        let minimumSpan = max(dominantSpan * 0.01, 1e-6)

        let cosRotation = abs(cos(camera.rotation))
        let sinRotation = abs(sin(camera.rotation))
        let rotatedWidth = rawWidth * cosRotation + rawHeight * sinRotation
        let rotatedHeight = rawWidth * sinRotation + rawHeight * cosRotation
        let fittedWidth = max(rotatedWidth, minimumSpan)
        let fittedHeight = max(rotatedHeight, minimumSpan)

        let viewportX: Double
        let viewportY: Double
        let viewportWidth: Double
        let viewportHeight: Double
        if let viewport = ui.drawingViewportRect {
            viewportX = Double(viewport.x)
            viewportY = Double(viewport.y)
            viewportWidth = max(Double(viewport.w), 1.0)
            viewportHeight = max(Double(viewport.h), 1.0)
        } else {
            viewportX = 0
            viewportY = 0
            viewportWidth = max(Double(windowWidth), 1.0)
            viewportHeight = max(Double(windowHeight), 1.0)
        }

        let fitZoom = min(
            viewportWidth / fittedWidth,
            viewportHeight / fittedHeight)
        camera.zoom = max(0.000001, min(fitZoom * 0.92, 1e15))

        let boundsCenterX = (bounds.min.x + bounds.max.x) * 0.5
        let boundsCenterY = (bounds.min.y + bounds.max.y) * 0.5
        let viewportCenterX = viewportX + viewportWidth * 0.5
        let viewportCenterY = viewportY + viewportHeight * 0.5
        let windowCenterX = Double(windowWidth) * 0.5
        let windowCenterY = Double(windowHeight) * 0.5
        let cameraSpaceX = (viewportCenterX - windowCenterX) / camera.zoom
        let cameraSpaceY = (viewportCenterY - windowCenterY) / camera.zoom
        let rotationCos = cos(camera.rotation)
        let rotationSin = sin(camera.rotation)
        let worldShiftX = cameraSpaceX * rotationCos - cameraSpaceY * rotationSin
        let worldShiftY = cameraSpaceX * rotationSin + cameraSpaceY * rotationCos

        camera.offset = (
            boundsCenterX - worldShiftX,
            boundsCenterY - worldShiftY)
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
        // Guard against pathological scale inputs (e.g. from minimized window
        // or NaN propagation) that would produce gargantuan font sizes.
        guard dpiScale > 0.01, uiScale > 0.01, uiScale < 64.0 else {
            print("Warning: setupFontAtlas skipped — unreasonable scale dpi=\(dpiScale) ui=\(uiScale)")
            return
        }

        let atlas = io.pointee.Fonts!
        
        // Release old GPU texture if any
        if let oldTex = self.fontTexture {
            SDL_ReleaseGPUTexture(self.gpuDevice, oldTex)
            self.fontTexture = nil
        }
        
        ImFontAtlas_Clear(atlas)

        ui.boldFont = nil
        ui.smallFont = nil
        ui.monoFont = nil
        ui.largeFont = nil
        ui.titleFont = nil
        ui.commandTitleFont = nil
        ui.commandPillFont = nil
        ui.commandDescriptionFont = nil

        uiGlyphRangesStorage?.deinitialize(count: uiGlyphRangesStorageCount)
        uiGlyphRangesStorage?.deallocate()
        uiGlyphRangesStorage = nil
        uiGlyphRangesStorageCount = 0

        igImFontAtlasBuildInit(atlas)

        let rangesBuilder = ImFontGlyphRangesBuilder_ImFontGlyphRangesBuilder()!
        defer { ImFontGlyphRangesBuilder_destroy(rangesBuilder) }

        var glyphRanges: [ImWchar] = [
            0x0020, 0x00FF,
            0x0370, 0x03FF,
            0x0400, 0x04FF,
            0x2000, 0x206F,
            0x2100, 0x214F,
            0x2190, 0x21FF,
            0x2200, 0x22FF,
            0x2500, 0x257F,
            0x2580, 0x259F,
            0x25A0, 0x25FF,
            0x2600, 0x26FF,
            0xFF00, 0xFFEF,
        ]
        glyphRanges.append(contentsOf: uiFontLanguageProfile.additionalGlyphRanges)
        glyphRanges.append(0)

        glyphRanges.withUnsafeBufferPointer { ptr in
            ImFontGlyphRangesBuilder_AddRanges(rangesBuilder, ptr.baseAddress!)
        }

        var outRanges = ImVector_ImWchar()
        ImFontGlyphRangesBuilder_BuildRanges(rangesBuilder, &outRanges)
        guard outRanges.Size > 0, let builtRanges = outRanges.Data else {
            print("Warning: Failed to build UI glyph ranges for \(uiFontLanguageProfile.rawValue).")
            return
        }

        let rangeCount = Int(outRanges.Size)
        let persistentRanges = UnsafeMutablePointer<ImWchar>.allocate(capacity: rangeCount)
        persistentRanges.initialize(from: builtRanges, count: rangeCount)
        uiGlyphRangesStorage = persistentRanges
        uiGlyphRangesStorageCount = rangeCount
        let glyphRangesPtr = UnsafePointer(persistentRanges)

        let exePath = Bundle.main.executableURL?.deletingLastPathComponent().path ?? FileManager.default.currentDirectoryPath
        let fontsDir = exePath + "/Fonts"

        let geistReg = fontsDir + "/Geist-Regular.ttf"
        let geistBold = fontsDir + "/Geist-SemiBold.ttf"
        let geistSmall = fontsDir + "/Geist-Regular.ttf"
        let geistMono = fontsDir + "/GeistMono-Medium.ttf"
        let geistMonoRegular = fontsDir + "/GeistMono-Regular.ttf"
        let geistMedium = fontsDir + "/Geist-Medium.ttf"
        let geistLarge = fontsDir + "/Geist-Medium.ttf"

        let dpi = dpiScale
        let fallbackFontPath = uiFontLanguageProfile.fallbackFontPaths.first {
            FileManager.default.fileExists(atPath: $0)
        }
        var loadedFont = false
        var mergedFallback = false

        func addUIFont(primaryPath: String, size: Float) -> UnsafeMutablePointer<ImFont>? {
            let primaryExists = FileManager.default.fileExists(atPath: primaryPath)
            guard primaryExists || fallbackFontPath != nil else { return nil }

            let resolvedPrimary = primaryExists ? primaryPath : fallbackFontPath!
            let primaryConfig = ImFontConfig_ImFontConfig()!
            primaryConfig.pointee.RasterizerDensity = dpi
            let font = ImFontAtlas_AddFontFromFileTTF(
                atlas, resolvedPrimary, size * uiScale, primaryConfig, glyphRangesPtr)
            ImFontConfig_destroy(primaryConfig)
            guard font != nil else { return nil }

            if let fallbackFontPath,
               fallbackFontPath.caseInsensitiveCompare(resolvedPrimary) != .orderedSame {
                let fallbackConfig = ImFontConfig_ImFontConfig()!
                fallbackConfig.pointee.RasterizerDensity = dpi
                fallbackConfig.pointee.MergeMode = true
                let merged = ImFontAtlas_AddFontFromFileTTF(
                    atlas, fallbackFontPath, size * uiScale, fallbackConfig, glyphRangesPtr)
                ImFontConfig_destroy(fallbackConfig)
                if merged != nil {
                    mergedFallback = true
                }
            } else if fallbackFontPath != nil {
                mergedFallback = true
            }

            loadedFont = true
            return font
        }

        _ = addUIFont(primaryPath: geistReg, size: 16.0)
        self.ui.boldFont = addUIFont(primaryPath: geistBold, size: 16.0)
        self.ui.smallFont = addUIFont(primaryPath: geistSmall, size: 13.0)
        self.ui.monoFont = addUIFont(primaryPath: geistMono, size: 14.0)
        self.ui.commandTitleFont = addUIFont(primaryPath: geistMono, size: 16.0)
        self.ui.commandPillFont = addUIFont(primaryPath: geistMonoRegular, size: 14.0)
        self.ui.commandDescriptionFont = addUIFont(primaryPath: geistMedium, size: 13.0)
        self.ui.largeFont = addUIFont(primaryPath: geistLarge, size: 20.0)
        self.ui.titleFont = addUIFont(primaryPath: geistLarge, size: 34.0)

        if let fallbackFontPath {
            print("Loaded \(uiFontLanguageProfile.rawValue) UI fallback source: \(fallbackFontPath)")
        } else if uiFontLanguageProfile != .standard {
            print("Warning: No fallback font was found for UI language profile \(uiFontLanguageProfile.rawValue).")
        }

        if fallbackFontPath != nil && !mergedFallback {
            print("Warning: UI fallback font could not be merged into the active font set.")
        }
        if !loadedFont {
            print("Warning: No UI font found. Using the ImGui default font.")
        }
        igImFontAtlasBuildMain(atlas)

        // Extract font texture pixel data.
        if let texData = atlas.pointee.TexData {
            let w = texData.pointee.Width
            let h = texData.pointee.Height
            let bpp = texData.pointee.BytesPerPixel
            let useColors = texData.pointee.UseColors
            print("Font atlas [\(uiFontLanguageProfile.rawValue)]: \(w)x\(h), \(bpp) bpp, useColors=\(useColors)")

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
    /// Safe to call during a frame — the actual rebuild is deferred to before the next NewFrame.
    public func updateScale(dpiScale: Float, fbScale: Float, force: Bool = false) {
        // Guard against zero/negative values when the window is minimized or
        // otherwise in an invalid state.  Rebuilding the font atlas with bogus
        // scale values produces gargantuan glyphs that overflow the atlas.
        guard dpiScale > 0.01, fbScale > 0.01 else { return }

        let autoScale = (fbScale > 0.001) ? dpiScale / fbScale : 1.0
        let newUiScale = uiScaleOverride ?? autoScale
        
        let oldUiScale = self.currentUiScale
        let oldDpiScale = self.currentDpiScale
        
        if force || newUiScale != oldUiScale || dpiScale != oldDpiScale {
            // Defer the atlas rebuild and style rescaling to before the next NewFrame.
            // If the atlas is currently locked (during a frame), touching it will assert.
            _pendingUiScaleRebuild = (dpiScale, fbScale, force)
        }
    }

    /// Perform a pending UI scale rebuild. Must be called outside of an ImGui frame
    /// (before ImGuiNewFrame / after ImGuiRender), when the font atlas is unlocked.
    internal func applyPendingUiScaleRebuild() {
        guard let (dpiScale, fbScale, _) = _pendingUiScaleRebuild else { return }
        _pendingUiScaleRebuild = nil

        let autoScale = (fbScale > 0.001) ? dpiScale / fbScale : 1.0
        let newUiScale = uiScaleOverride ?? autoScale
        let oldUiScale = self.currentUiScale

        let factor = oldUiScale > 0.001 ? newUiScale / oldUiScale : 1.0
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

    /// Apply a UI scale override or revert to auto (pass nil or 0).
    /// Triggers a full font atlas rebuild and ImGui style rescaling.
    public func applyUiScaleOverride(_ override: Float?) {
        let validOverride: Float? = (override != nil && override! > 0.001) ? override : nil
        guard validOverride != uiScaleOverride else { return }
        uiScaleOverride = validOverride
        let fbScale = (windowWidth > 0) ? Float(pixelWidth) / Float(windowWidth) : 1.0
        updateScale(dpiScale: currentDpiScale, fbScale: fbScale, force: true)
    }
    @discardableResult
    public func applyUIFontLanguageProfile(_ profile: UIFontLanguageProfile) -> Bool {
        guard profile != uiFontLanguageProfile else { return false }
        uiFontLanguageProfile = profile
        UserDefaults.standard.set(profile.rawValue, forKey: "Zephyr.UIFontLanguageProfile")

        let fbScale = (windowWidth > 0 && pixelWidth > 0)
            ? Float(pixelWidth) / Float(windowWidth)
            : max(scaleX, 1.0)
        updateScale(dpiScale: currentDpiScale, fbScale: fbScale, force: true)
        return true
    }

}
