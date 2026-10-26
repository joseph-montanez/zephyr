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
    /// Live stores of the ACTIVE tab's render context. Repointed on
    /// every tab switch (contexts are pooled per tab and never wiped).
    public var spriteManager: SpriteManager
    public var geometryManager: GeometryManager
    public private(set) var renderer: EngineRenderer!

    /// Set once `init` runs to completion. A failable init that returns nil
    /// still runs `deinit`, but unowned references to self are already
    /// invalid there — so renderer teardown must be skipped on that path.
    private var initCompleted = false

    // MARK: - Managers
    public let camera: EngineCameraManager
    public let interaction: EngineInteractionManager
    public let snap: EngineSnapManager
    public let ui: EngineUIManager
    public let textManager: EngineTextManager
    public private(set) var textureManager: EngineTextureManager!
    public private(set) var platform: EnginePlatformDelegate!
    public private(set) var loopController: EngineLoopController!
    /// Registry of every OS window owned by the engine (main + auxiliaries).
    public let windowManager = EngineWindowManager()
    /// Loads the AutoLISP ribbon definition and owns the live ribbon model.
    /// Created by the app at startup (it needs the command processor); nil
    /// until then, and the UI simply renders nothing while it is nil.
    public var ribbonLoader: RibbonSpecLoader?
    /// Tab ID shown in the main window's canvas. Follows the active tab while
    /// it is docked; untouched while a float window is focused. Nil when every
    /// tab floats.
    public var mainShownTabID: UUID? = nil
    /// Float window IDs keyed by hosted tab ID.
    public private(set) var floatWindowIDs: [UUID: SDL_WindowID] = [:]
    /// Split-pane arrangement of the main window's canvas.
    public var mainPanes = PaneLayout()
    /// Remembered per-pane camera views (AutoCAD-style: each pane keeps its
    /// own zoom/pan). The focused pane's view is the live camera; entries
    /// exist only for non-focused panes. See `PaneViewStore`.
    public var paneViews = PaneViewStore()

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

    /// C string copy of the ImGui ini file path — must stay alive for the
    /// lifetime of the ImGui context because ImGui stores the raw pointer.
    private var _imguiIniPath: UnsafeMutablePointer<CChar>? = nil

    // MARK: State
    internal var running = true
    /// Called before an OS or custom-titlebar close request is accepted.
    /// Return false when the app needs to show an unsaved-changes confirmation first.
    public var windowCloseRequestHandler: (() -> Bool)?
    /// Deferred native dialog request. Set during ImGui rendering, executed
    /// after SDL event polling so SDL_ShowOpenFileDialog works correctly.
    public var pendingDialogRequest: (@MainActor () -> Void)?
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
        renderer.bumpAllContextGenerations()
        cadSelection._selectionGeneration &+= 1
        print("[Engine] simplifyComplexBlocks: \(simplifyComplexBlocks)")
    }

    /// When more than this many entities are selected, suppress all grips
    /// (mirrors AutoCAD GRIPOBJLIMIT). Entities keep geometry highlight.
    public var gripObjectMax: Int = 100
    /// Maximum number of grip squares drawn on screen (prevents ImGui 16-bit
    /// index buffer overflow). Default 1000 grips across all entities.
    public var gripMax: Int = 1000
    /// When a window/crossing drag preview exceeds this many entities,
    /// live preview highlighting is disabled for the whole set (mirrors
    /// AutoCAD SELECTIONPREVIEWLIMIT).
    public var selectionPreviewLimit: Int =
        CADSelectionDisplayPolicy.defaultSelectionPreviewLimit

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
    public var cadBridge = CADRendererBridge()
    // MARK: File Browser (Open)
    public var fileBrowser = ImGuiFileBrowser()
    public var saveFileBrowser = ImGuiFileBrowser()

    // MARK: - Autosave
    public var autosaveIntervalMinutes: Double = 5.0
    internal var _autosaveAccumulator: Double = 0

    /// Xref change-detection poll interval (AutoCAD XNOTIFYTIME default).
    public var xrefNotifyIntervalMinutes: Double = 5.0
    internal var _xrefPollAccumulator: Double = 0

    // Frame timing (ms). Printed every 60 frames to console.
    internal var _frameTimingCount: Int = 0
    internal var _frameTimingCadMs: Double = 0
    internal var _frameTimingPrimMs: Double = 0
    internal var _frameTimingImGuiMs: Double = 0

    /// FPS string cache (recomputed every 15 frames).
    public var _cachedFpsText: String = ""
    public var _fpsCacheFrame: Int = 0

    /// Render cache: avoid grid query + sort + map on static frames.
    internal var _cachedPrimitivesToRender: [RenderPrimitive] = []
    internal var _cachedRenderGen: Int = -1
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

        // Initialize GPU Device. The format follows the platform
        // convention shared with the shader loader (SPIR-V on Linux).
        let formats = EngineRenderer.gpuShaderConvention().format
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

        windowManager.register(handle: window, id: SDL_GetWindowID(window), isMain: true)

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
        // The main window owns the primary context; float windows get their
        // own (sharing this atlas) in createAuxWindow.
        if let mainWindow = windowManager.mainWindow {
            mainWindow.imguiContext = self.ctx
            mainWindow.imguiIO = self.io
        }

        // Point ImGui's ini file to the app support directory so docking layout
        // persists between launches.
        if let iniURL = UserSettings.imguiIniURL() {
            let iniPath = iniURL.path
            self._imguiIniPath = z_strdup(iniPath)
            if let iniCStr = self._imguiIniPath {
                self.io.pointee.IniFilename = UnsafePointer(iniCStr)
            }
            if FileManager.default.fileExists(atPath: iniPath) {
                ImGuiLoadIniSettingsFromDisk(iniPath)
            }
        }

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
        commandProcessor.registerFeatureCommand(
            name: "DRAWORDER", aliases: ["DR"],
            descriptor: DrawOrderDescriptors.drawOrder,
            factory: { DrawOrderUmbrellaCommand() })

        // Register AutoLISP entry points (LOAD / EVAL / SCRIPT).
        commandProcessor.registerFeatureCommand(
            name: "LOAD", aliases: [],
            descriptor: LispDescriptors.load,
            factory: { LispCommand(mode: .load) })
        commandProcessor.registerFeatureCommand(
            name: "EVAL", aliases: [],
            descriptor: LispDescriptors.eval,
            factory: { LispCommand(mode: .eval) })
        commandProcessor.registerFeatureCommand(
            name: "SCRIPT", aliases: ["SCR"],
            descriptor: LispDescriptors.script,
            factory: { LispCommand(mode: .script) })

        // Initialize tab manager and wire callbacks (after ctx/io are initialized)
        _ = tabManager.newTab()  // Start with one blank tab
        mainShownTabID = tabManager.activeTab?.id
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
        tabManager.captureSelectionState = { [weak self] in
            guard let self = self else { return .empty }
            return SelectionState(
                selectedHandles: self.cadSelection.selectedHandles,
                lastSelectedHandle: self.cadSelection.lastSelectedHandle,
                selectedLeaderContentHandle: self.cadSelection.selectedLeaderContentHandle)
        }
        tabManager.applySelectionState = { [weak self] state in
            guard let self = self else { return }
            self.cadSelection.selectedHandles = state.selectedHandles
            self.cadSelection.lastSelectedHandle = state.lastSelectedHandle
            self.cadSelection.selectedLeaderContentHandle = state.selectedLeaderContentHandle
            self.cadSelection._selectionGeneration &+= 1
        }
        tabManager.onActiveTabChanged = { [weak self] in
            guard let self else { return }
            if ProcessInfo.processInfo.environment["ZEPHYR_DEBUG_INPUT"] != nil {
                print("[Diag] activeTab -> \(self.tabManager.activeTab?.displayName ?? "nil") (floated: \(self.tabManager.activeTab?.isFloated ?? false))")
            }
            // A pending rectangle selection belongs to the tab/view (and
            // window) where its first corner landed. Switching tabs or
            // views — including focus moving to another OS window — must
            // not let the next click land as its second corner elsewhere.
            self.interaction.cancelRectSelect()
            if let color = self.tabManager.activeViewBackgroundColor {
                self.ui.viewBackgroundOverride = SDL_FColor(
                    r: Float(color.r) / 255.0,
                    g: Float(color.g) / 255.0,
                    b: Float(color.b) / 255.0,
                    a: Float(color.a) / 255.0)
            } else {
                self.ui.viewBackgroundOverride = nil
            }
            // Render contexts are pooled PER TAB: switching tabs wipes
            // nothing and rebuilds nothing. The engine-global store
            // pointers simply repoint at the incoming tab's warm context
            // (its geometry/sprites/bridge were built while it was last
            // visible and revise lazily via builtRevision checks). This
            // replaces the old supersede-and-clear, which blanked and
            // regenerated the drawing on EVERY window-focus change.
            if let activeID = self.tabManager.activeTab?.id {
                let actx = self.renderer.tabCtx(for: activeID)
                self.geometryManager = actx.geometry
                self.spriteManager = actx.sprites
                self.cadBridge = actx.bridge
            }
            // Selection is NOT cleared here anymore: TabManager captured the
            // departing view's selection and applied the incoming view's
            // before this callback (fresh tabs apply .empty).
            self.snap.snapTrackingEngine.clear()
            self.syncWindowsToActiveTab()
        }
        tabManager.onTabClosedID = { [weak self] tabID in
            guard let self else { return }
            // A closed tab takes its float window and secondary context with it.
            self.closeFloatWindow(hosting: tabID)
            self.dropSecondaryCtx(for: tabID)
            self.mainPanes.rebindAll(
                from: tabID,
                to: self.tabManager.tabs.first(where: { !$0.isFloated })?.id)
            if let activeID = self.tabManager.activeTab?.id {
                self.ensurePaneViews(for: activeID)
            }
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

        // Load persisted user settings and apply them to the UI manager.
        let settings = UserSettings.load()
        if let theme = AppTheme.theme(named: settings.themeName) {
            self.ui.currentTheme = theme
        } else {
            self.ui.isDarkTheme = settings.isDarkTheme
        }
        self.ui.applyTheme()
        self.ui.layersPanelVisible = settings.layersPanelVisible
        self.ui.drawPaletteVisible = settings.drawPaletteVisible
        self.ui.blockPanelVisible = settings.blockPanelVisible
        self.ui.xrefPanelVisible = settings.xrefPanelVisible
        self.ui.xrefRefPathType = settings.xrefRefPathType
        self.ui.xrefSearchPaths = settings.xrefSearchPaths
        self.ui.xrefMaxLoaded = settings.xrefMaxLoaded
        self.ui.xrefMaxDepth = settings.xrefMaxDepth
        self.ui.xrefMaxPrimitives = settings.xrefMaxPrimitives
        self.ui.xrefFadePercent = settings.xrefFadePercent
        self.ui.xrefBindType = settings.xrefBindType
        self.ui.dataTablePanelVisible = settings.dataTablePanelVisible
        self.ui.showPropertiesPanel = settings.showPropertiesPanel
        self.ui.showFPS = settings.showFPS
        self.ui.hasCompletedSetup = settings.hasCompletedSetup
        self.ui.radialNavVisible = settings.radialNavVisible
        self.ui.ribbonVisible = settings.ribbonVisible
        self.ui.activeRibbonTab = settings.activeRibbonTab
        if let mode = RibbonDisplayMode(rawValue: settings.ribbonMode) {
            self.ui.ribbonMode = mode
        }

        print("Zephyr Initialized Successfully")
    }

    internal func activateInitialWindowForInput() {
        #if os(macOS)
        let application = NSApplication.shared
        _ = application.setActivationPolicy(.regular)
        application.activate(ignoringOtherApps: true)

        let properties = SDL_GetWindowProperties(window)
        if let cocoaWindowPointer = SDL_GetPointerProperty(
            properties,
            "SDL.window.cocoa.window",
            nil
        ) {
            let cocoaWindow = Unmanaged<NSWindow>
                .fromOpaque(cocoaWindowPointer)
                .takeUnretainedValue()
            cocoaWindow.makeKeyAndOrderFront(nil)
            _ = cocoaWindow.makeFirstResponder(cocoaWindow.contentView)
        }

        _ = SDL_RaiseWindow(window)
        SDL_StartTextInput(window)
        if let io {
            ImGuiIO_AddFocusEvent(io, true)
        }
        #endif
    }

    // MARK: Deinitialization
    deinit {
        MainActor.assumeIsolated {
            if initCompleted {
                renderer.performCleanup()
            }
            uiGlyphRangesStorage?.deinitialize(count: uiGlyphRangesStorageCount)
            uiGlyphRangesStorage?.deallocate()
            uiGlyphRangesStorage = nil
            uiGlyphRangesStorageCount = 0
            if let ptr = _imguiIniPath {
                free(ptr)
                _imguiIniPath = nil
            }
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

    // MARK: - Auxiliary Windows

    /// Create an additional OS window on the shared GPU device and register
    /// it for sequential rendering. Aux windows are plain titled windows
    /// (no custom chrome or hit-testing).
    /// - Returns: The registered window, or nil when creation/claim fails.
    @discardableResult
    public func createAuxWindow(title: String, width: Int32, height: Int32) -> EngineManagedWindow? {
        let flags: SDLWindowFlags = [.resizable, .highPixelDensity]
        guard let handle = SDL_CreateWindow(title, width, height, flags.rawValue) else {
            print("SDL_CreateWindow (aux) Error: \(String(cString: SDL_GetError()))")
            return nil
        }
        guard SDL_ClaimWindowForGPUDevice(gpuDevice, handle) else {
            print("SDL_ClaimWindowForGPUDevice (aux) Error: \(String(cString: SDL_GetError()))")
            SDL_DestroyWindow(handle)
            return nil
        }
        SDL_StartTextInput(handle)
        let registered = windowManager.register(handle: handle, id: SDL_GetWindowID(handle), isMain: false)
        // Own ImGui context per OS window (shared font atlas). A single
        // context across alternating per-window frames leaves every
        // window's widgets WasActive-stale at hover time, so buttons
        // could never hover or fire in float windows.
        let styleToCopy = ImGuiGetStyle()?.pointee
        let auxCtx = ImGuiCreateContext(io.pointee.Fonts)!
        registered.imguiContext = auxCtx
        // CreateContext restores the previously-current context, so switch
        // explicitly before capturing the new context's IO.
        igSetCurrentContext(auxCtx)
        registered.imguiIO = ImGuiGetIO()!
        registered.imguiIO?.pointee.ConfigFlags |= Int32(ImGuiConfigFlags_DockingEnable.rawValue)
        registered.imguiIO?.pointee.IniFilename = nil
        if let styleToCopy, let style = ImGuiGetStyle() {
            style.pointee = styleToCopy
        }
        // CreateContext left the aux context current; restore main.
        if let main = windowManager.mainWindow {
            activateImGuiContext(for: main)
        }
        print("[Engine] Created aux window (id \(registered.id), title \"\(title)\").")
        return registered
    }

    /// Destroy an auxiliary window and remove it from the registry.
    /// Unknown IDs and the main window are ignored.
    public func closeAuxWindow(id: SDL_WindowID) {
        guard let aux = windowManager.window(for: id), !aux.isMain else { return }
        print("[Engine] Closing aux window (id \(id)).")
        if let auxCtx = aux.imguiContext {
            if igGetCurrentContext() == auxCtx, let main = windowManager.mainWindow {
                activateImGuiContext(for: main)
            }
            ImGuiDestroyContext(auxCtx)
            aux.imguiContext = nil
            aux.imguiIO = nil
        }
        SDL_ReleaseWindowFromGPUDevice(gpuDevice, aux.handle)
        SDL_DestroyWindow(aux.handle)
        windowManager.unregister(id: id)
    }

    /// Make a window's ImGui context current and repoint `engine.io` at
    /// its IO, so all frame/poll code transparently works on that window.
    internal func activateImGuiContext(for window: EngineManagedWindow) {
        guard let ctx = window.imguiContext, let windowIO = window.imguiIO else { return }
        if igGetCurrentContext() != ctx {
            igSetCurrentContext(ctx)
        }
        if io != windowIO {
            io = windowIO
        }
    }

    // MARK: - Float / Dock Tabs

    /// Maximum simultaneous float windows (each costs a swapchain + regen pipeline).
    public static let maxFloatWindows = 4

    /// The tab shown in the main window's canvas: the focused pane's tab when
    /// split, else the tracked tab when still docked, else the first docked
    /// tab, else nil when every tab floats.
    public func mainShownTab() -> DocumentTab? {
        if mainPanes.isSplit {
            guard let tabID = mainPanes.focusedTabID,
                  let tab = tabManager.tab(for: tabID), !tab.isFloated else { return nil }
            return tab
        }
        if let id = mainShownTabID,
           let tab = tabManager.tab(for: id), !tab.isFloated {
            return tab
        }
        // The tracked tab just floated (or vanished): stay on its nearest
        // docked neighbor instead of jumping back to the first tab.
        let fallbackID = mainShownTabID
            .flatMap { tabManager.nearestDockedTabID(replacing: $0) }
            ?? tabManager.tabs.first(where: { !$0.isFloated })?.id
        if let fallbackID, let fallback = tabManager.tab(for: fallbackID) {
            mainShownTabID = fallback.id
            return fallback
        }
        mainShownTabID = nil
        return nil
    }

    /// Whether the main window's canvas currently shows the active tab.
    public func mainWindowShowsActiveTab() -> Bool {
        guard let active = tabManager.activeTab, !active.isFloated else { return false }
        if mainPanes.isSplit {
            return mainPanes.focusedTabID == active.id
        }
        return mainShownTabID == active.id
    }

    /// Whether a window's canvas shows the active tab (and may therefore
    /// receive CAD input and render the primary pipeline).
    public func windowShowsActiveTab(_ window: EngineManagedWindow) -> Bool {
        guard let activeID = tabManager.activeTab?.id else { return false }
        if window.isMain {
            if mainPanes.isSplit {
                return mainPanes.focusedTabID == activeID
            }
            return mainShownTabID == activeID
        }
        return window.hostedTabID == activeID
    }

    /// Activate the tab a window shows, in response to direct user
    /// interaction (click, wheel, pen, key) in that window. Focus events
    /// normally do this first, but interaction must not depend on them:
    /// when a float window's focus event is lost, misrouted, or bounced,
    /// `windowShowsActiveTab` would stay false forever and every canvas
    /// event in that window would be dropped while its drawing renders
    /// on as an inert secondary view. A click is unambiguous intent.
    public func activateTabForInteraction(in window: EngineManagedWindow) {
        let targetID: UUID?
        if window.isMain {
            targetID = mainPanes.isSplit ? mainPanes.focusedTabID : mainShownTab()?.id
        } else {
            targetID = window.hostedTabID
        }
        if let targetID, targetID != tabManager.activeTab?.id,
           let idx = tabManager.indexOfTab(id: targetID) {
            tabManager.switchToTab(at: idx)
        }
    }

    /// Reconcile windows with the active tab: the main canvas follows docked
    /// tabs, and the hosting window is raised WHEN IT ISN'T ALREADY FOCUSED.
    /// Raising unconditionally made the main window jump over float windows
    /// on every tab/view switch (all of which land here), even when the user
    /// was working in — or had just raised — the other window. Clicked
    /// windows are raised by the input handler's click-to-raise (some WMs
    /// focus without raising); this raise only completes cross-window
    /// activations (e.g. Ctrl+Tab to a floated tab).
    /// Called after every tab switch, keeping the "focused window shows the
    /// active tab" invariant (focus changes complete it from the other side).
    public func syncWindowsToActiveTab() {
        guard let active = tabManager.activeTab else { return }
        if active.isFloated {
            if let windowID = floatWindowIDs[active.id],
               let window = windowManager.window(for: windowID),
               !window.isFocused {
                SDL_RaiseWindow(window.handle)
            }
        } else {
            mainShownTabID = active.id
            if mainPanes.isSplit {
                followActiveTabInPanes(activeID: active.id)
            }
            if let main = windowManager.mainWindow, !main.isFocused {
                SDL_RaiseWindow(main.handle)
            }
        }
    }

    /// Keep the split panes coherent with the active tab: focus the pane
    /// already showing it, else rebind the focused pane to it.
    public func followActiveTabInPanes(activeID: UUID) {
        guard mainPanes.isSplit else { return }
        // Prefer the focused pane when it already shows the tab: avoids a
        // gratuitous focus — and camera — jump (e.g. on view switches).
        if mainPanes.focusedTabID == activeID { return }
        if let leaf = mainPanes.findLeaf(showing: activeID) {
            let fromID = mainPanes.focusedLeafID
            let fromTab = mainPanes.tabID(of: fromID)
            mainPanes.focus(id: leaf.id)
            // The defocused pane showed `fromTab` until this switch; that
            // tab's cameraState was just saved from the live camera, i.e.
            // the pane's last displayed view. Skipped when it already showed
            // the incoming tab (re-entrant focus): its entry is intact.
            if let fromTab, fromTab != activeID,
               let tab = tabManager.tab(for: fromTab) {
                paneViews.save(
                    leafID: fromID, tabID: fromTab,
                    viewIndex: tab.activeViewIndex, state: tab.cameraState)
            }
            _ = adoptPaneView(leafID: leaf.id, tabID: activeID)
        } else {
            mainPanes.rebindLeaf(mainPanes.focusedLeafID, to: activeID)
        }
        ensurePaneViews(for: activeID)
    }

    // MARK: - Pane Camera Views

    /// Remember the live camera and active drawing view as `leafID`'s view
    /// of `tabID`. Call when the pane is becoming non-focused; the focused
    /// pane needs no entry.
    public func savePaneView(leafID: UUID, tabID: UUID?) {
        guard let capture = tabManager.captureCameraState else { return }
        let viewIndex = tabID.flatMap { tabManager.tab(for: $0)?.activeViewIndex } ?? 0
        paneViews.save(leafID: leafID, tabID: tabID, viewIndex: viewIndex, state: capture())
    }

    /// Adopt `leafID`'s remembered view of `tabID` (now the active tab),
    /// consuming the entry: sync the tab's active drawing view (Model,
    /// paper layout, ...) so the primary pipeline and editing follow the
    /// pane, then apply its camera. Call when the pane gains focus.
    /// - Returns: False when no view was remembered (caller keeps the live
    ///   camera — the pane was already showing it).
    @discardableResult
    public func adoptPaneView(leafID: UUID, tabID: UUID?) -> Bool {
        guard let entry = paneViews.take(leafID: leafID, tabID: tabID) else { return false }
        if let tabID, tabID == tabManager.activeTab?.id,
           let tab = tabManager.tab(for: tabID),
           entry.viewIndex >= 0, entry.viewIndex < tab.drawingViews.count,
           entry.viewIndex != tab.activeViewIndex {
            _ = tabManager.switchToView(at: entry.viewIndex)
        }
        tabManager.applyCameraState?(entry.state)
        return true
    }

    /// Give every non-focused pane showing `tabID` a remembered view for the
    /// tab switch that just completed, preserving what each pane displayed:
    /// its own remembered entry when present, else the tab's active drawing
    /// view and camera (which the switch left untouched for the incoming tab).
    public func ensurePaneViews(for tabID: UUID) {
        guard mainPanes.isSplit else { return }
        let tab = tabManager.tab(for: tabID)
        let fallbackState = tab?.cameraState
            ?? tabManager.captureCameraState?()
            ?? CameraState.default
        let fallbackView = tab?.activeViewIndex ?? 0
        for node in mainPanes.leaves() {
            guard case .leaf(let id, let shown) = node,
                  shown == tabID, id != mainPanes.focusedLeafID,
                  paneViews.entry(leafID: id, tabID: tabID) == nil
            else { continue }
            paneViews.save(
                leafID: id, tabID: tabID,
                viewIndex: fallbackView, state: fallbackState)
        }
    }

    /// Drop a tab's secondary render context, releasing its GPU buffers.
    public func dropSecondaryCtx(for tabID: UUID) {
        guard let ctx = renderer.secondaryCtxs.removeValue(forKey: tabID) else { return }
        if ctx === renderer.primaryCtx {
            // The adopted primary context object is recycled as the spare
            // for the next first-rendered tab, not destroyed.
            renderer.primaryCtxAdoptedTabID = nil
            ctx.builtTabID = nil
            ctx.builtViewIndex = -1
            ctx.builtDocumentID = nil
            ctx.invalidateBuiltState(device: gpuDevice)
        } else {
            ctx.destroy(device: gpuDevice)
        }
    }

    /// Float a tab into its own OS window. An already-floated tab is simply
    /// raised. The main canvas falls back to another docked tab.
    /// - Returns: False when the tab is unknown or the window cap is reached.
    @discardableResult
    public func floatTab(id: UUID) -> Bool {
        guard let tab = tabManager.tab(for: id) else { return false }
        if tab.isFloated {
            if let windowID = floatWindowIDs[id],
               let window = windowManager.window(for: windowID) {
                SDL_RaiseWindow(window.handle)
            }
            return true
        }
        guard floatWindowIDs.count < Self.maxFloatWindows else {
            print("[CAD] Cannot float tab: \(Self.maxFloatWindows) floating windows already open. Dock one with TABDOCK first.")
            return false
        }
        guard let aux = createAuxWindow(title: tab.displayName, width: 1280, height: 800) else {
            return false
        }
        aux.hostedTabID = id
        floatWindowIDs[id] = aux.id
        tabManager.setFloated(id: id, true)
        let replacementID = tabManager.nearestDockedTabID(replacing: id)
        mainPanes.rebindAll(from: id, to: replacementID)
        if let activeID = tabManager.activeTab?.id {
            ensurePaneViews(for: activeID)
        }
        if mainShownTabID == id {
            mainShownTabID = replacementID
        }
        SDL_RaiseWindow(aux.handle)
        return true
    }

    /// Dock a floated tab back into the main tab bar, closing its window.
    /// - Returns: False when the tab is not floated.
    @discardableResult
    public func dockTab(id: UUID) -> Bool {
        guard tabManager.isFloated(id: id) else { return false }
        tabManager.setFloated(id: id, false)
        closeFloatWindow(hosting: id)
        dropSecondaryCtx(for: id)
        syncWindowsToActiveTab()
        return true
    }

    /// Destroy the float window hosting a tab (tab itself untouched).
    /// Used when the tab closes; docking uses `dockTab` instead.
    public func closeFloatWindow(hosting tabID: UUID) {
        if let windowID = floatWindowIDs.removeValue(forKey: tabID) {
            closeAuxWindow(id: windowID)
        }
    }

    /// SDL handle to parent modal file dialogs on: the float window
    /// hosting the active tab when it floats, else the main window.
    /// (macOS sheets parent off the key window instead; see
    /// `NativeFileDialog.showMacOpenDialog`.)
    public var dialogParentWindow: OpaquePointer {
        if let active = tabManager.activeTab, active.isFloated,
           let windowID = floatWindowIDs[active.id],
           let window = windowManager.window(for: windowID) {
            return window.handle
        }
        return window
    }

    // MARK: - Split Panes

    /// Activate a docked tab from the main tab bar, retargeting the focused
    /// pane to it when split.
    public func activateDockedTab(at index: Int) {
        guard index >= 0, index < tabManager.tabs.count else { return }
        let id = tabManager.tabs[index].id
        if mainPanes.isSplit {
            mainPanes.rebindLeaf(mainPanes.focusedLeafID, to: id)
        }
        tabManager.switchToTab(at: index)
        if let activeID = tabManager.activeTab?.id {
            ensurePaneViews(for: activeID)
        }
    }

    /// Focus the split pane under a main-window point, activating its tab.
    /// Each pane keeps its own view: the defocused pane remembers the live
    /// camera, and the focused pane restores its remembered view, so neither
    /// pane's picture changes on click.
    /// - Returns: True when focus moved (caller swallows the click).
    public func focusSplitPane(at point: (x: Float, y: Float)) -> Bool {
        guard mainPanes.isSplit,
              let canvasF = ui.drawingViewportRect else { return false }
        let canvas = PaneRect(x: canvasF.x, y: canvasF.y, w: canvasF.w, h: canvasF.h)
        guard let leaf = mainPanes.hitTest(point: point, canvas: canvas),
              leaf.id != mainPanes.focusedLeafID else { return false }
        let fromID = mainPanes.focusedLeafID
        let fromTab = mainPanes.tabID(of: fromID)
        mainPanes.focus(id: leaf.id)
        // The live camera is the active tab's view: only worth remembering
        // when the defocused pane showed it.
        if fromTab == tabManager.activeTab?.id {
            savePaneView(leafID: fromID, tabID: fromTab)
        }
        if case .leaf(_, let tabID) = leaf, let tabID {
            if tabID == tabManager.activeTab?.id {
                _ = adoptPaneView(leafID: leaf.id, tabID: tabID)
            } else if let idx = tabManager.indexOfTab(id: tabID) {
                tabManager.switchToTab(at: idx)
                // The switch may have refocused another pane already showing
                // the tab (follow); only adopt this pane's view when focus
                // stayed here, else it needs a fresh entry as a same-tab pane.
                if mainPanes.focusedLeafID == leaf.id {
                    _ = adoptPaneView(leafID: leaf.id, tabID: tabID)
                } else {
                    ensurePaneViews(for: tabID)
                }
            }
        }
        return true
    }

    /// Split the focused pane. The new pane shows the next docked tab, or the
    /// same tab (dual view, AutoCAD-style) when it is the only one. Both
    /// panes start on the current view; each keeps its own from then on.
    public func splitMainPane(axis: PaneSplitAxis) {
        let tabs = tabManager.tabs
        let focusedID = mainPanes.focusedTabID ?? mainShownTab()?.id ?? tabManager.activeTab?.id
        if !mainPanes.isSplit {
            mainPanes.rebindLeaf(mainPanes.focusedLeafID, to: focusedID)
        }
        var newTabID = focusedID
        if tabs.filter({ !$0.isFloated }).count > 1, let focusedID,
           let idx = tabs.firstIndex(where: { $0.id == focusedID }) {
            var j = (idx + 1) % tabs.count
            while tabs[j].isFloated || tabs[j].id == focusedID {
                j = (j + 1) % tabs.count
                if j == idx { break }
            }
            if tabs[j].id != focusedID {
                newTabID = tabs[j].id
            }
        }
        // Heal stale focus so the split source is known, then remember its
        // view: the split moves focus to the new pane, leaving the source
        // non-focused (its live view becomes its remembered one).
        mainPanes.focus(id: mainPanes.focusedLeafID)
        let sourceID = mainPanes.focusedLeafID
        let sourceTab = mainPanes.tabID(of: sourceID)
        mainPanes.splitFocused(axis: axis, newTabID: newTabID)
        if sourceTab == tabManager.activeTab?.id {
            savePaneView(leafID: sourceID, tabID: sourceTab)
        }
        activatePaneTab()
        if let activeID = tabManager.activeTab?.id {
            ensurePaneViews(for: activeID)
        }
    }

    /// Close the focused pane, promoting its sibling (AutoCAD `JOIN`).
    @discardableResult
    public func joinMainPane() -> Bool {
        let removedID = mainPanes.focusedLeafID
        guard mainPanes.closeFocused() else { return false }
        paneViews.remove(leafID: removedID)
        let gainedID = mainPanes.focusedLeafID
        activatePaneTab()
        // Docking may have switched tabs and refocused yet another pane
        // already showing it; only adopt the promoted pane's view when focus
        // stayed there, else it needs a fresh entry as a same-tab pane.
        if mainPanes.focusedLeafID == gainedID,
           let tabID = mainPanes.tabID(of: gainedID),
           tabID == tabManager.activeTab?.id {
            _ = adoptPaneView(leafID: gainedID, tabID: tabID)
        } else if let activeID = tabManager.activeTab?.id {
            ensurePaneViews(for: activeID)
        }
        return true
    }

    /// Collapse to the focused pane, saving the tree for TOGGLE/VPMIN.
    @discardableResult
    public func unsplitMainPane() -> Bool {
        guard mainPanes.collapseToFocused() else { return false }
        activatePaneTab()
        return true
    }

    /// Toggle between single and the last multi-pane arrangement.
    @discardableResult
    public func toggleMainPanes() -> Bool {
        guard mainPanes.toggle() else { return false }
        activatePaneTab()
        return true
    }

    /// Restore the arrangement saved by VPMAX (single-pane only).
    @discardableResult
    public func vpMinRestore() -> Bool {
        guard !mainPanes.isSplit, mainPanes.savedTree != nil else { return false }
        return toggleMainPanes()
    }

    /// The main canvas as a `PaneRect` (nil before the first layout).
    private var mainPaneCanvas: PaneRect? {
        guard let c = ui.drawingViewportRect else { return nil }
        return PaneRect(x: c.x, y: c.y, w: c.w, h: c.h)
    }

    /// Give every split pane an equal share (VPEQUAL).
    /// - Returns: False when the main view is not split.
    @discardableResult
    public func equalizeMainPanes() -> Bool {
        guard mainPanes.isSplit else { return false }
        mainPanes.equalizeAll()
        return true
    }

    /// Move the divider nearest the focused pane (Ctrl+Alt+Arrow).
    /// - Returns: False when no divider runs along that axis.
    @discardableResult
    public func nudgeFocusedPane(_ direction: PaneNudgeDirection) -> Bool {
        guard mainPanes.isSplit, let canvas = mainPaneCanvas else { return false }
        return mainPanes.nudgeFocused(direction, canvas: canvas)
    }

    /// Grow (positive) or shrink (negative) the focused pane by `delta`
    /// (fraction of its parent split) — VPRESIZE.
    /// - Returns: False when the main view is not split.
    @discardableResult
    public func resizeFocusedPane(by delta: Float) -> Bool {
        guard mainPanes.isSplit, let canvas = mainPaneCanvas else { return false }
        return mainPanes.resizeFocused(by: delta, canvas: canvas)
    }

    /// Activate the focused pane's tab after a structural pane change.
    private func activatePaneTab() {
        if let tabID = mainPanes.focusedTabID,
           tabID != tabManager.activeTab?.id,
           let idx = tabManager.indexOfTab(id: tabID) {
            tabManager.switchToTab(at: idx)
        }
    }

    // MARK: - Metrics Borrow (float-window frames)

    /// Snapshot the engine-global metrics slots so a float-window frame can
    /// borrow them and restore afterwards.
    internal func snapshotMetrics() -> (w: Int32, h: Int32, pw: Int32, ph: Int32, sx: Float, sy: Float) {
        (windowWidth, windowHeight, pixelWidth, pixelHeight, scaleX, scaleY)
    }

    internal func restoreMetrics(_ m: (w: Int32, h: Int32, pw: Int32, ph: Int32, sx: Float, sy: Float)) {
        windowWidth = m.w
        windowHeight = m.h
        pixelWidth = m.pw
        pixelHeight = m.ph
        scaleX = m.sx
        scaleY = m.sy
    }

    /// Point the engine-global metrics slots at a window's cached metrics.
    /// Pair with `snapshotMetrics`/`restoreMetrics` around float-window work.
    internal func borrowMetrics(from window: EngineManagedWindow) {
        windowWidth = window.width
        windowHeight = window.height
        pixelWidth = window.pixelWidth
        pixelHeight = window.pixelHeight
        scaleX = window.scaleX
        scaleY = window.scaleY
    }

    /// Point the window-size slots at a split pane's dimensions (same window,
    /// so pixel size and scale are untouched). Pair with snapshot/restore.
    internal func borrowPaneDims(width: Int32, height: Int32) {
        windowWidth = width
        windowHeight = height
    }

    // MARK: - ImGui Frame Callback

    /// Closure called each frame between ImGuiNewFrame and ImGuiRender.
    /// Override this to add custom ImGui widgets (property panels, toolbars, etc.).
    public var imguiFrameCallback: (() -> Void)?

    // MARK: - Stop Engine

    public func requestStop() {
        guard windowCloseRequestHandler?() ?? true else { return }
        stop()
    }

    /// Immediately stops the engine. Confirmation UI should call this only
    /// after the user has explicitly chosen to discard changes and exit.
    public func stop() {
        // Persist user settings and ImGui docking layout before shutting down.
        UserSettings.capture(ui: ui).save()
        if let iniURL = UserSettings.imguiIniURL() {
            let dir = iniURL.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: dir.path) {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            ImGuiSaveIniSettingsToDisk(iniURL.path)
        }
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

        self.initCompleted = true
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
            if ProcessInfo.processInfo.environment["ZEPHYR_DEBUG_INPUT"] != nil {
                print("[Diag] uiScale pending: dpi \(oldDpiScale)->\(dpiScale) ui \(oldUiScale)->\(newUiScale) fb=\(fbScale) force=\(force)")
            }
            _pendingUiScaleRebuild = (dpiScale, fbScale, force)
        }
    }

    /// Perform a pending UI scale rebuild. Must be called outside of an ImGui frame
    /// (before ImGuiNewFrame / after ImGuiRender), when the font atlas is unlocked.
    internal func applyPendingUiScaleRebuild() {
        guard let (dpiScale, fbScale, _) = _pendingUiScaleRebuild else { return }
        _pendingUiScaleRebuild = nil
        if ProcessInfo.processInfo.environment["ZEPHYR_DEBUG_INPUT"] != nil {
            print("[Diag] FONT ATLAS REBUILD dpi=\(dpiScale) fb=\(fbScale)")
        }

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
