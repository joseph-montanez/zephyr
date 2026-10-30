import Foundation
import CSDL3
import SwiftSDL
import ImGui

// =========================================================================
// MARK: - EngineUIManager
//
// Integrates the ImGui library with the SDL3 GPU rendering pipeline.
// Handles:
//   - Rendering ImGui draw lists as GPU draw calls
//   - Mapping SDL3 input events (mouse, keyboard, text) to ImGui IO
//   - UI state visibility (toolbars, layers, block panels)
//   - Applying themes to both the UI and Viewport background
// =========================================================================
/// Document panels need a window target. Layers are document-local, so a
/// window may render them for the tab it actually shows. Blocks and Data
/// Tables still drive the shared active selection/command state, so they
/// render only where the active tab is shown.
public enum DocumentPanelUIPolicy {
    public static func shouldRenderLayers(
        isVisible: Bool,
        hasShownTab: Bool
    ) -> Bool {
        isVisible && hasShownTab
    }

    public static func shouldRenderActiveDocumentPanel(
        isVisible: Bool,
        showsActiveTab: Bool
    ) -> Bool {
        isVisible && showsActiveTab
    }
}

/// The command line owns one shared buffer (`commandProcessor`) but is
/// rendered once per OS window frame. Render it only in the window
/// showing the active tab; otherwise every window shows — and can
/// mutate through — the same input, and per-window ImGui contexts fight
/// over keyboard focus (first letter duplicates, later letters land in
/// the wrong window).
public enum CommandLineUIPolicy {
    public static func shouldRender(showsActiveTab: Bool) -> Bool {
        showsActiveTab
    }
}

/// Selection-context editors (hatch/array/table ribbons and the properties
/// inspector) all read the one shared active selection/document. Render
/// them only in the window showing the active tab; otherwise every open
/// OS window shows — and can mutate through — the same editor.
public enum SelectionContextUIPolicy {
    public static func shouldRender(showsActiveTab: Bool) -> Bool {
        showsActiveTab
    }

    public static func shouldRenderHatchEditor(
        showsActiveTab: Bool,
        hasActiveFeatureCommand: Bool,
        selectedCount: Int,
        hasLastSelectedHandle: Bool
    ) -> Bool {
        shouldRender(showsActiveTab: showsActiveTab)
            && !hasActiveFeatureCommand
            && selectedCount == 1
            && hasLastSelectedHandle
    }
}

/// The properties inspector is a persistent panel, not a selection popup:
/// while toggled on it stays open across deselection (Escape, deleting the
/// selected entity, entering the block editor) and shows an empty state
/// until something is selected again. It closes only when the user toggles
/// it off (PROPS command or the window's close button).
public enum PropertiesPanelUIPolicy {
    public enum Content: Equatable {
        /// Panel toggled off — render nothing.
        case hidden
        /// Panel open with no resolved selected entity — empty state.
        case empty
        /// Panel open with a resolved selected entity — its properties.
        case entity
    }

    public static func content(
        isVisible: Bool,
        hasSelectedEntity: Bool
    ) -> Content {
        guard isVisible else { return .hidden }
        return hasSelectedEntity ? .entity : .empty
    }

    // MARK: - Inspected target within a multi-selection

    /// With two or more entities selected the panel offers a picker: All
    /// (the summed view, edits apply to every selected entity) or one
    /// single entity (its properties are shown and edits apply to it
    /// only). The pick is a handle, with nil meaning All. A pick survives
    /// only while its entity is still selected; a stale pick resolves
    /// back to All rather than narrowing edits to a deselected entity.
    /// `orderedSelectedHandles` is the panel's stable (sorted) view of
    /// the selection.
    public static func resolvedInspectedHandle(
        _ inspectedHandle: UUID?,
        orderedSelectedHandles: [UUID]
    ) -> UUID? {
        guard let inspectedHandle,
              orderedSelectedHandles.contains(inspectedHandle)
        else { return nil }
        return inspectedHandle
    }

    /// The handles edits made in the panel apply to: the inspected entity
    /// alone, or every selected entity in All mode.
    public static func editHandles(
        orderedSelectedHandles: [UUID],
        inspectedHandle: UUID?
    ) -> Set<UUID> {
        if let single = resolvedInspectedHandle(
            inspectedHandle, orderedSelectedHandles: orderedSelectedHandles) {
            return [single]
        }
        return Set(orderedSelectedHandles)
    }

    /// Which entity's properties the panel shows: the inspected pick,
    /// else the last-clicked entity, else the first selected one so All
    /// mode still shows something when there is no last-clicked entity.
    public static func displayedHandle(
        orderedSelectedHandles: [UUID],
        inspectedHandle: UUID?,
        lastSelectedHandle: UUID?
    ) -> UUID? {
        if let single = resolvedInspectedHandle(
            inspectedHandle, orderedSelectedHandles: orderedSelectedHandles) {
            return single
        }
        if let lastSelectedHandle,
           orderedSelectedHandles.contains(lastSelectedHandle) {
            return lastSelectedHandle
        }
        return orderedSelectedHandles.first
    }

    /// Staleness check for the panel's cached picker list. The list is a
    /// function of (selection, document contents), so it only needs
    /// rebuilding when the document, the selection generation, or the
    /// document revision (labels embed block names / geometry kinds)
    /// moves. Rebuilding per frame makes a large selection pay entity
    /// copies + label building + an allocating sort on the render path.
    public static func pickerCacheStale(
        cachedDocument: ObjectIdentifier?,
        document: ObjectIdentifier,
        cachedSelectionGeneration: Int,
        selectionGeneration: Int,
        cachedRevision: UInt64,
        revision: UInt64,
        cachedCount: Int,
        selectionCount: Int
    ) -> Bool {
        cachedDocument != document
            || cachedSelectionGeneration != selectionGeneration
            || cachedRevision != revision
            || cachedCount != selectionCount
    }
}

/// Drawing-view tabs belong to the tab shown in each OS window/pane, not
/// to the one global active tab. A window may display another tab's view
/// list, but switching still runs through the active-tab path after input
/// activation has made that window's tab active.
public enum DrawingViewTabBarPolicy {
    public static func shouldRender(
        shownTabViewCount: Int,
        isEditingBlock: Bool
    ) -> Bool {
        shownTabViewCount > 1 && !isEditingBlock
    }

    public static func clampedViewIndex(_ index: Int, viewCount: Int) -> Int {
        guard viewCount > 0 else { return 0 }
        return min(max(index, 0), viewCount - 1)
    }

    public static func shouldSwitch(
        showsActiveTab: Bool,
        selectedViewIndex: Int,
        clickedViewIndex: Int
    ) -> Bool {
        showsActiveTab && selectedViewIndex != clickedViewIndex
    }
}

/// Left-side status values for one OS window/pane: the drawing that
/// window actually shows, not the one global active tab.
public struct StatusBarShownInfo: Equatable {
    public var tabName: String
    public var isDirty: Bool
    public var viewName: String
    public var layerName: String
    public var entityCount: Int

    public init(
        tabName: String, isDirty: Bool, viewName: String,
        layerName: String, entityCount: Int
    ) {
        self.tabName = tabName
        self.isDirty = isDirty
        self.viewName = viewName
        self.layerName = layerName
        self.entityCount = entityCount
    }
}

/// The status bar is rendered once per OS window, so its filename, view,
/// layer, and entity count must come from that window's shown tab/view.
/// Reading the active tab (and one shared text cache) made every window
/// report the active drawing.
public enum StatusBarUIPolicy {
    public static func shownInfo(tab: DocumentTab?, viewIndex: Int) -> StatusBarShownInfo {
        guard let tab, !tab.drawingViews.isEmpty else {
            return StatusBarShownInfo(
                tabName: "Untitled", isDirty: false, viewName: "Model",
                layerName: "none", entityCount: 0)
        }
        let clamped = DrawingViewTabBarPolicy.clampedViewIndex(
            viewIndex, viewCount: tab.drawingViews.count)
        let view = tab.drawingViews[clamped]
        let document = view.document
        let layerName: String
        if let layerID = document.activeLayerID, let layer = document.layer(for: layerID) {
            layerName = layer.name
        } else {
            layerName = "none"
        }
        return StatusBarShownInfo(
            tabName: tab.displayName,
            isDirty: tab.hasUnsavedChanges,
            viewName: view.name,
            layerName: layerName,
            entityCount: document.entityCount)
    }

    public static func leftText(info: StatusBarShownInfo, trackingSuffix: String) -> String {
        let dirtyMark = info.isDirty ? " *" : ""
        return "\(info.tabName)\(dirtyMark)  ·  View: \(info.viewName)  ·  Layer: \(info.layerName)  ·  Entities: \(info.entityCount)\(trackingSuffix)"
    }
}

/// Capture policy for the radial nav's mouse handling.
///
/// Only pan/zoom/rotate (zones 2, 3, 4, 6) consume relative deltas and need
/// SDL relative capture. Moving the nav itself (zone 1) and one-shot clicks
/// (zones 0/5) are absolute gestures: capturing for those hides the OS
/// cursor and parks it mid-window and, with no warp-back owed, strands it
/// there on release, which surfaces as a cursor stuck in the middle after
/// moving the nav when the app window sits on a secondary monitor.
@MainActor
public enum RadialNavCapture {
    /// Zones that consume relative deltas and need SDL relative capture:
    /// right (zoom in), bottom (pan), left (zoom out), outer ring (rotate).
    public static func wantsRelativeCapture(zone: Int?) -> Bool {
        switch zone {
        case 2, 3, 4, 6:
            return true
        default:
            return false
        }
    }

    /// Whether release owes a warp-back to the press point. Dragging the nav
    /// itself (zone 1) intentionally keeps the cursor at the drop point.
    public static func wantsWarpBack(activeZone: Int?, wasDragged: Bool) -> Bool {
        activeZone != 1 || !wasDragged
    }

    /// Backstop for a lost mouse-up: ImGui still reports the item held while
    /// the hardware button is already up (seen when the app window sits on a
    /// secondary monitor). Treat as released so relative capture can never
    /// strand the cursor mid-window.
    public static func shouldForceRelease(
        wasActive: Bool, isActive: Bool, physicalLeftDown: Bool
    ) -> Bool {
        wasActive && isActive && !physicalLeftDown
    }

    /// Clamp a nav origin into the current window so the whole nav stays
    /// visible. A remembered spot from a larger window (or a drag) would
    /// otherwise end up off-screen after a resize.
    public static func clampedPosition(
        x: Float, y: Float, dw: Float, dh: Float, size: Float
    ) -> ImVec2 {
        ImVec2(
            x: min(max(x, 0), max(0, dw - size)),
            y: min(max(y, 0), max(0, dh - size)))
    }
}

/// The radial nav captures the mouse (relative mode) and warps it back on
/// release. Both SDL calls must target the OS window the nav is rendered
/// in: targeting the main window from a float frame teleports the cursor
/// into the main window at the float-local coordinates.
@MainActor
public enum RadialNavWindowPolicy {
    public static func targetWindow(
        frameRole: EngineUIManager.UIFrameRole,
        windowManager: EngineWindowManager,
        floatWindowIDs: [UUID: SDL_WindowID]
    ) -> EngineManagedWindow? {
        switch frameRole {
        case .mainWindow:
            return windowManager.mainWindow
        case .floatWindow(let hostedTabID):
            if let hostedTabID {
                if let windowID = floatWindowIDs[hostedTabID],
                   let window = windowManager.window(for: windowID) {
                    return window
                }
                if let window = windowManager.auxWindows
                    .first(where: { $0.hostedTabID == hostedTabID }) {
                    return window
                }
            }
            if let focused = windowManager.focusedWindow, !focused.isMain {
                return focused
            }
            return windowManager.mainWindow
        }
    }
}

@MainActor
public final class EngineUIManager {
    
    // MARK: - UI State Properties
    
    public var radialNavVisible: Bool = false
    public var showFPS: Bool = false

    /// Whether the properties panel is visible (toggled via "props" command).
    public var showPropertiesPanel: Bool = false
    
    /// Whether the Draw Tools palette is visible (toggled via "DRAW" command).
    public var drawPaletteVisible: Bool = false

    /// Whether the Blocks panel is visible (toggled via "BLOCKS" command).
    public var blockPanelVisible: Bool = false

    /// Whether the External References palette is visible ("XREF").
    public var xrefPanelVisible: Bool = false
    public var xrefRefPathType: Int = 1
    public var xrefSearchPaths: [String] = []
    public var xrefMaxLoaded: Int = 32
    public var xrefMaxDepth: Int = 16
    public var xrefMaxPrimitives: Int = 5_000_000
    public var xrefFadePercent: Int = 50
    public var xrefBindType: Int = 0

    /// Whether the Data Tables panel is visible (toggled via "TABLE" command).
    public var dataTablePanelVisible: Bool = false

    public var styleManagerActive: Bool = false
    public var leaderStyleManagerActive: Bool = false
    public var dimStyleManagerActive: Bool = false

    /// Whether the Layers panel is visible (toggled via "LA"/"LAYER" command). Default true.
    public var layersPanelVisible: Bool = false

    /// Whether the file tab bar is visible (toggled via "FILETAB"/"FILETABCLOSE").
    public var fileTabsVisible: Bool = true

    // MARK: - Ribbon

    /// Whether the ribbon window is shown (toggled via "RIBBON"/"RIBBONCLOSE").
    public var ribbonVisible: Bool = true
    /// Clean-screen mode (CLEANSCREENON/OFF, Ctrl+0): chrome hidden to
    /// maximize the canvas, with the pre-hide state saved for restore.
    public var cleanScreenActive: Bool = false
    private var savedChromeForCleanScreen: CleanScreenChrome?

    /// Snapshot of hideable chrome, for CLEANSCREENON → CLEANSCREENOFF.
    public struct CleanScreenChrome: Sendable {
        public var ribbonVisible: Bool
        public var showPropertiesPanel: Bool
        public var drawPaletteVisible: Bool
        public var blockPanelVisible: Bool
        public var xrefPanelVisible: Bool
        public var dataTablePanelVisible: Bool
        public var layersPanelVisible: Bool
        public var fileTabsVisible: Bool
        public var radialNavVisible: Bool
    }

    /// Hide all chrome for clean-screen mode, remembering prior state.
    public func enterCleanScreen() {
        guard !cleanScreenActive else { return }
        savedChromeForCleanScreen = CleanScreenChrome(
            ribbonVisible: ribbonVisible,
            showPropertiesPanel: showPropertiesPanel,
            drawPaletteVisible: drawPaletteVisible,
            blockPanelVisible: blockPanelVisible,
            xrefPanelVisible: xrefPanelVisible,
            dataTablePanelVisible: dataTablePanelVisible,
            layersPanelVisible: layersPanelVisible,
            fileTabsVisible: fileTabsVisible,
            radialNavVisible: radialNavVisible)
        ribbonVisible = false
        showPropertiesPanel = false
        drawPaletteVisible = false
        blockPanelVisible = false
        xrefPanelVisible = false
        dataTablePanelVisible = false
        layersPanelVisible = false
        fileTabsVisible = false
        radialNavVisible = false
        cleanScreenActive = true
    }

    /// Restore chrome hidden by `enterCleanScreen()`.
    public func exitCleanScreen() {
        guard cleanScreenActive else { return }
        if let saved = savedChromeForCleanScreen {
            ribbonVisible = saved.ribbonVisible
            showPropertiesPanel = saved.showPropertiesPanel
            drawPaletteVisible = saved.drawPaletteVisible
            blockPanelVisible = saved.blockPanelVisible
            xrefPanelVisible = saved.xrefPanelVisible
            dataTablePanelVisible = saved.dataTablePanelVisible
            layersPanelVisible = saved.layersPanelVisible
            fileTabsVisible = saved.fileTabsVisible
            radialNavVisible = saved.radialNavVisible
        }
        savedChromeForCleanScreen = nil
        cleanScreenActive = false
    }
    /// Ribbon presentation: classic menu bar, labels-only, or icons + labels.
    /// Cycled by the ribbon's own mode button; persisted as its raw value.
    public var ribbonMode: RibbonDisplayMode = .full
    /// Title of the active ribbon tab. Persisted; the renderer falls back to
    /// the first tab when the definition no longer contains it.
    public var activeRibbonTab: String?
    public var fpsCacheFrame: Int = 15

    /// When true, the block editor close-confirmation popup is shown.
    /// Set by the "Save & Close Block" button or BCLOSE command;
    /// cleared by the popup's Save/Discard/Cancel actions.
    public var blockClosePending: Bool = false

    /// Whether the first-run setup popup was completed. Loaded from
    /// settings at startup; the popup shows while this is false.
    public var hasCompletedSetup: Bool = false

    public var layerMoveActive: Bool = false
    public var layerMoveSelectionIndex: Int = 0
    public var layerMoveBuffer: String = ""
    public var layerMoveMatches: [Layer] = []
    
    public var topChromeExcludeRect: SDL_Rect? = nil

    /// Which OS window the in-progress UI frame belongs to. The renderer
    /// sets it before each window's uiBuilder runs; AppUI uses it to skip
    /// main-only chrome (file tab bar, top chrome, app-global dialogs) in
    /// float windows, which otherwise render the full interface.
    public enum UIFrameRole: Equatable {
        case mainWindow
        case floatWindow(hostedTabID: UUID?)
    }
    public var frameRole: UIFrameRole = .mainWindow
    public var isFloatFrame: Bool {
        if case .floatWindow = frameRole { return true }
        return false
    }

    public private(set) var drawingViewportRect: SDL_FRect? = nil
    private var drawingViewportBaseRect: SDL_FRect? = nil
    private var dockedPanelRects: [SDL_FRect] = []

    
    public var boldFont: UnsafeMutablePointer<ImFont>? = nil
    public var smallFont: UnsafeMutablePointer<ImFont>? = nil
    public var monoFont: UnsafeMutablePointer<ImFont>? = nil
    public var largeFont: UnsafeMutablePointer<ImFont>? = nil
    public var titleFont: UnsafeMutablePointer<ImFont>? = nil
    public var commandTitleFont: UnsafeMutablePointer<ImFont>? = nil
    public var commandPillFont: UnsafeMutablePointer<ImFont>? = nil
    public var commandDescriptionFont: UnsafeMutablePointer<ImFont>? = nil
    
    // MARK: - Theme State
    
    /// The currently active AppTheme instance.
    public var currentTheme: AppTheme = AppTheme.dark {
        didSet {
            if igGetCurrentContext() != nil {
                applyTheme()
            }
        }
    }

    /// The currently active AppTheme instance (alias for currentTheme).
    public var theme: AppTheme {
        get { currentTheme }
        set { currentTheme = newValue }
    }

    /// Whether the current UI theme is dark (true) or light (false).
    /// Maintained for backwards compatibility. Setting this sets the theme
    /// to AppTheme.dark or AppTheme.light.
    public var isDarkTheme: Bool {
        get { currentTheme.isDark }
        set {
            if newValue != currentTheme.isDark {
                currentTheme = newValue ? AppTheme.dark : AppTheme.light
            }
        }
    }
    
    /// User/theme viewport background color (normalized 0-1).
    private var baseBackgroundColor = SDL_FColor(r: 0.06, g: 0.17, b: 0.25, a: 1.0)

    /// Temporary background supplied by the active drawing view, such as paper space.
    public var viewBackgroundOverride: SDL_FColor? {
        didSet { displayPaletteGeneration &+= 1 }
    }

    /// Effective viewport background. SET-BACKGROUND updates the model-space value
    /// without replacing a temporary paper-space override.
    public var backgroundColor: SDL_FColor {
        get { viewBackgroundOverride ?? baseBackgroundColor }
        set {
            baseBackgroundColor = newValue
            displayPaletteGeneration &+= 1
        }
    }

    /// Effective background for an arbitrary tab's drawing view: the view's own
    /// background when set, else the shared model-space color. Mirrors
    /// `backgroundColor` without touching the active tab's override.
    public func backgroundColor(forViewBackground viewBackground: ColorRGBA?) -> SDL_FColor {
        if let viewBackground {
            return SDL_FColor(
                r: Float(viewBackground.r) / 255.0,
                g: Float(viewBackground.g) / 255.0,
                b: Float(viewBackground.b) / 255.0,
                a: Float(viewBackground.a) / 255.0)
        }
        return baseBackgroundColor
    }

    /// Whether the effective drawing background needs the light-background CAD palette.
    /// This intentionally follows the viewport override rather than the surrounding UI theme.
    public var isViewportBackgroundLight: Bool {
        Self.isLightBackground(backgroundColor)
    }

    /// Luminance test for an arbitrary viewport background (secondary views).
    public static func isLightBackground(_ color: SDL_FColor) -> Bool {
        let luminance = 0.2126 * Double(color.r)
            + 0.7152 * Double(color.g)
            + 0.0722 * Double(color.b)
        return luminance >= 0.5
    }

    /// Monotonic counter bumped on any change that affects display-adaptive colors
    /// (background color, dark/light theme). The render cache compares this against
    /// its cached value to detect when the vertex buffer must be rebuilt.
    public internal(set) var displayPaletteGeneration: Int = 0
    
    public init() {}

    public func beginDrawingViewportFrame(
        x: Float, y: Float, width: Float, height: Float
    ) {
        let rect = SDL_FRect(
            x: x,
            y: y,
            w: max(width, 1.0),
            h: max(height, 1.0))
        drawingViewportBaseRect = rect
        dockedPanelRects.removeAll(keepingCapacity: true)
        drawingViewportRect = rect
    }

    /// Snapshot the drawing-viewport rects so a float-window frame can
    /// restore them afterwards. The main window recomputes them every frame,
    /// but poll-time readers (zoom-to-fit) must see main-window values.
    internal func snapshotDrawingViewport() -> (base: SDL_FRect?, current: SDL_FRect?) {
        (drawingViewportBaseRect, drawingViewportRect)
    }

    internal func restoreDrawingViewport(base: SDL_FRect?, current: SDL_FRect?) {
        drawingViewportBaseRect = base
        drawingViewportRect = current
    }

    public func excludeDockedPanelRect(
        x: Float, y: Float, width: Float, height: Float
    ) {
        guard width > 1.0, height > 1.0 else { return }
        dockedPanelRects.append(SDL_FRect(x: x, y: y, w: width, h: height))
        recomputeDrawingViewport()
    }

    private func recomputeDrawingViewport() {
        guard let base = drawingViewportBaseRect else { return }

        let baseLeft = base.x
        let baseTop = base.y
        let baseRight = base.x + base.w
        let baseBottom = base.y + base.h
        var panels: [SDL_FRect] = []
        var xEdges = [baseLeft, baseRight]
        var yEdges = [baseTop, baseBottom]

        for rect in dockedPanelRects {
            let left = max(baseLeft, rect.x)
            let top = max(baseTop, rect.y)
            let right = min(baseRight, rect.x + rect.w)
            let bottom = min(baseBottom, rect.y + rect.h)
            guard right - left > 1.0, bottom - top > 1.0 else { continue }
            panels.append(SDL_FRect(
                x: left,
                y: top,
                w: right - left,
                h: bottom - top))
            xEdges.append(left)
            xEdges.append(right)
            yEdges.append(top)
            yEdges.append(bottom)
        }

        func uniqueSorted(_ values: [Float]) -> [Float] {
            let sorted = values.sorted()
            var result: [Float] = []
            for value in sorted {
                if let last = result.last, abs(last - value) <= 0.5 { continue }
                result.append(value)
            }
            return result
        }

        let xs = uniqueSorted(xEdges)
        let ys = uniqueSorted(yEdges)
        var best = base
        var bestArea: Float = panels.isEmpty ? base.w * base.h : 0
        let baseCenterX = base.x + base.w * 0.5
        let baseCenterY = base.y + base.h * 0.5
        var bestCenterDistance = Float.infinity

        if xs.count >= 2, ys.count >= 2 {
            for leftIndex in 0..<(xs.count - 1) {
                for rightIndex in (leftIndex + 1)..<xs.count {
                    let left = xs[leftIndex]
                    let right = xs[rightIndex]
                    let width = right - left
                    guard width > 1.0 else { continue }

                    for topIndex in 0..<(ys.count - 1) {
                        for bottomIndex in (topIndex + 1)..<ys.count {
                            let top = ys[topIndex]
                            let bottom = ys[bottomIndex]
                            let height = bottom - top
                            guard height > 1.0 else { continue }

                            let isBlocked = panels.contains { panel in
                                let overlapWidth = min(right, panel.x + panel.w)
                                    - max(left, panel.x)
                                let overlapHeight = min(bottom, panel.y + panel.h)
                                    - max(top, panel.y)
                                return overlapWidth > 0.5 && overlapHeight > 0.5
                            }
                            if isBlocked { continue }

                            let area = width * height
                            let centerX = (left + right) * 0.5
                            let centerY = (top + bottom) * 0.5
                            let centerDistance = abs(centerX - baseCenterX)
                                + abs(centerY - baseCenterY)
                            if area > bestArea + 0.5
                                || (abs(area - bestArea) <= 0.5
                                    && centerDistance < bestCenterDistance) {
                                bestArea = area
                                bestCenterDistance = centerDistance
                                best = SDL_FRect(
                                    x: left,
                                    y: top,
                                    w: width,
                                    h: height)
                            }
                        }
                    }
                }
            }
        }

        drawingViewportRect = bestArea > 1.0 ? best : base
    }
    
    // MARK: - Theme Management
    
    /// Apply the current theme to both ImGui style colors and the viewport background.
    public func applyTheme() {
        guard igGetCurrentContext() != nil, let style = igGetStyle() else { return }

        // Canvas/viewport background
        backgroundColor = theme.viewportBg

        // Base ImGui theme
        if isDarkTheme {
            igStyleColorsDark(style)
        } else {
            igStyleColorsLight(style)
        }

        withUnsafeMutablePointer(to: &style.pointee.Colors) { tuplePtr in
            tuplePtr.withMemoryRebound(to: ImVec4.self, capacity: Int(ImGuiCol_COUNT.rawValue)) { colors in
                
                colors[Int(ImGuiCol_Button.rawValue)]         = theme.buttonBg
                colors[Int(ImGuiCol_ButtonHovered.rawValue)]  = theme.brandGoldHover
                colors[Int(ImGuiCol_ButtonActive.rawValue)]   = theme.brandGoldActive

                colors[Int(ImGuiCol_FrameBg.rawValue)]        = theme.frameBg
                colors[Int(ImGuiCol_FrameBgHovered.rawValue)] = isDarkTheme ? theme.hoverBg : ImVec4(x: 0.80, y: 0.87, z: 0.93, w: 0.90)
                colors[Int(ImGuiCol_FrameBgActive.rawValue)]  = theme.activeBg

                colors[Int(ImGuiCol_Header.rawValue)]        = theme.border
                colors[Int(ImGuiCol_HeaderHovered.rawValue)] = theme.brandGoldHover
                colors[Int(ImGuiCol_HeaderActive.rawValue)]  = theme.brandGoldActive

                colors[Int(ImGuiCol_Tab.rawValue)]           = theme.tabBarBg
                colors[Int(ImGuiCol_TabHovered.rawValue)]    = theme.border
                colors[Int(ImGuiCol_TabSelected.rawValue)]   = theme.panelBg

                colors[Int(ImGuiCol_TitleBg.rawValue)]       = theme.topChromeBg
                colors[Int(ImGuiCol_TitleBgActive.rawValue)] = theme.topChromeBg
                colors[Int(ImGuiCol_PopupBg.rawValue)]       = theme.panelBg
                
                // Idle hairlines stay subtle in every theme; the opaque
                // border tone is reserved for hover, and brand gold for
                // the active/resizing state.
                colors[Int(ImGuiCol_Separator.rawValue)]     = theme.borderDim
                colors[Int(ImGuiCol_SeparatorHovered.rawValue)] = theme.border
                colors[Int(ImGuiCol_SeparatorActive.rawValue)]  = theme.brandGold
                colors[Int(ImGuiCol_Border.rawValue)]        = theme.borderDim
                
                colors[Int(ImGuiCol_WindowBg.rawValue)]      = theme.panelBg
                colors[Int(ImGuiCol_Text.rawValue)]          = theme.textPrimary
                colors[Int(ImGuiCol_TextDisabled.rawValue)]  = theme.textDim
                colors[Int(ImGuiCol_SliderGrab.rawValue)]    = theme.brandGold
                colors[Int(ImGuiCol_SliderGrabActive.rawValue)] = theme.brandGoldActive
                colors[Int(ImGuiCol_CheckMark.rawValue)]     = theme.brandGold
            }
        }
    }

    /// Switch to a theme by name/identifier, returning true if found.
    @discardableResult
    public func setTheme(named name: String) -> Bool {
        if let newTheme = AppTheme.theme(named: name) {
            setTheme(newTheme)
            return true
        }
        return false
    }

    /// Switch to a specific AppTheme instance.
    public func setTheme(_ newTheme: AppTheme) {
        currentTheme = newTheme
        displayPaletteGeneration &+= 1
        applyTheme()
    }

    /// Cycle to the next available theme in sequence.
    public func cycleTheme() {
        let next = AppTheme.nextTheme(after: currentTheme)
        setTheme(next)
    }

    /// Toggle between dark and light theme.
    public func toggleTheme() {
        if isDarkTheme {
            if currentTheme.id.hasPrefix("catppuccin") {
                setTheme(AppTheme.catppuccinLatte)
            } else {
                setTheme(AppTheme.light)
            }
        } else {
            if currentTheme.id == AppTheme.catppuccinLatte.id {
                setTheme(AppTheme.catppuccinMocha)
            } else {
                setTheme(AppTheme.dark)
            }
        }
    }
    
    // MARK: - ImGui Rendering

    internal func renderImGuiDrawData(cmd: OpaquePointer, renderPass: OpaquePointer, renderer: EngineRenderer, fontTexture: OpaquePointer?) {
        guard let drawData = ImGuiGetDrawData(), drawData.pointee.CmdListsCount > 0 else {
            return
        }

        let fbWidth = Int(drawData.pointee.DisplaySize.x * drawData.pointee.FramebufferScale.x)
        let fbHeight = Int(drawData.pointee.DisplaySize.y * drawData.pointee.FramebufferScale.y)
        if fbWidth <= 0 || fbHeight <= 0 { return }

        // Bind pipeline
        SDL_BindGPUGraphicsPipeline(renderPass, renderer.imguiPipeline)

        // Bind vertex and index buffers
        var vertexBinding = SDL_GPUBufferBinding(buffer: renderer.imguiVertexBuffer, offset: 0)
        SDL_BindGPUVertexBuffers(renderPass, 0, &vertexBinding, 1)

        var indexBinding = SDL_GPUBufferBinding(buffer: renderer.imguiIndexBuffer, offset: 0)
        let indexElementSize = MemoryLayout<ImDrawIdx>.stride == MemoryLayout<UInt16>.stride
            ? SDL_GPU_INDEXELEMENTSIZE_16BIT
            : SDL_GPU_INDEXELEMENTSIZE_32BIT
        SDL_BindGPUIndexBuffer(renderPass, &indexBinding, indexElementSize)

        // Push orthographic projection matrix
        let w = Float(drawData.pointee.DisplaySize.x)
        let h = Float(drawData.pointee.DisplaySize.y)
        var proj: [Float] = [
            2.0 / w, 0.0, 0.0, 0.0,
            0.0, -2.0 / h, 0.0, 0.0,
            0.0, 0.0, 0.5, 0.0,
            -1.0, 1.0, 0.0, 1.0
        ]
        SDL_PushGPUVertexUniformData(cmd, 0, &proj, UInt32(proj.count * 4))

        let clipOff = drawData.pointee.DisplayPos
        let clipScale = drawData.pointee.FramebufferScale

        var globalVtxOffset = 0
        var globalIdxOffset = 0

        for n in 0..<Int(drawData.pointee.CmdListsCount) {
            guard let cmdList = drawData.pointee.CmdLists.Data?[n] else { continue }

            for cmdIdx in 0..<Int(cmdList.pointee.CmdBuffer.Size) {
                let cmdDraw = cmdList.pointee.CmdBuffer.Data[cmdIdx]

                if cmdDraw.ElemCount == 0 { continue }

                if let _ = cmdDraw.UserCallback {
                    continue
                }

                // Compute scissor rect
                var clipMinX = (cmdDraw.ClipRect.x - clipOff.x) * clipScale.x
                var clipMinY = (cmdDraw.ClipRect.y - clipOff.y) * clipScale.y
                var clipMaxX = (cmdDraw.ClipRect.z - clipOff.x) * clipScale.x
                var clipMaxY = (cmdDraw.ClipRect.w - clipOff.y) * clipScale.y

                if clipMinX < 0 { clipMinX = 0 }
                if clipMinY < 0 { clipMinY = 0 }
                if clipMaxX > Float(fbWidth) { clipMaxX = Float(fbWidth) }
                if clipMaxY > Float(fbHeight) { clipMaxY = Float(fbHeight) }
                if clipMaxX <= clipMinX || clipMaxY <= clipMinY { continue }

                var scissor = SDL_Rect(
                    x: Int32(clipMinX),
                    y: Int32(clipMinY),
                    w: Int32(clipMaxX - clipMinX),
                    h: Int32(clipMaxY - clipMinY)
                )
                SDL_SetGPUScissor(renderPass, &scissor)

                // Bind texture-sampler
                let textureID = ImDrawCmdGetTexID(&cmdList.pointee.CmdBuffer.Data[cmdIdx])
                let texturePtr: OpaquePointer?
                if textureID != 0 {
                    texturePtr = OpaquePointer(bitPattern: UInt(textureID))
                } else {
                    texturePtr = fontTexture
                }

                var textureBinding = SDL_GPUTextureSamplerBinding(texture: texturePtr, sampler: renderer.fontSampler)
                SDL_BindGPUFragmentSamplers(renderPass, 0, &textureBinding, 1)

                // Issue draw call
                SDL_DrawGPUIndexedPrimitives(
                    renderPass,
                    cmdDraw.ElemCount,
                    1,
                    UInt32(globalIdxOffset) + cmdDraw.IdxOffset,
                    Int32(globalVtxOffset) + Int32(cmdDraw.VtxOffset),
                    0
                )
            }

            globalVtxOffset += Int(cmdList.pointee.VtxBuffer.Size)
            globalIdxOffset += Int(cmdList.pointee.IdxBuffer.Size)
        }
    }

    // MARK: - ImGui Input Processing

    /// Capture one SDL event into a window's ImGui input queue. The queue is
    /// replayed into the shared context immediately before that window's
    /// `NewFrame` (see `replayQueuedInput`), so every sequential frame
    /// consumes only its own window's input.
    ///
    /// - Returns: Whether ImGui wants the event, read from the target
    ///   window's *last rendered frame* — never live `io` state, which
    ///   belongs to whichever window framed last.
    internal func enqueueImGuiInput(event: inout SDL_Event, for target: EngineManagedWindow) -> Bool {
        switch event.type {

        case UInt32(SDL_EVENT_MOUSE_MOTION.rawValue):
            target.mouseX = event.motion.x
            target.mouseY = event.motion.y
            target.hasMousePos = true
            target.inputQueue.append(.mousePos(x: event.motion.x, y: event.motion.y))
            return target.wantCaptureMouse

        case UInt32(SDL_EVENT_MOUSE_BUTTON_DOWN.rawValue),
            UInt32(SDL_EVENT_MOUSE_BUTTON_UP.rawValue):
            let isDown = (event.type == UInt32(SDL_EVENT_MOUSE_BUTTON_DOWN.rawValue))
            var imGuiButton: Int32 = 0

            let SDL_BUTTON_LEFT = 1
            let SDL_BUTTON_MIDDLE = 2
            let SDL_BUTTON_RIGHT = 3

            switch Int32(event.button.button) {
            case Int32(SDL_BUTTON_LEFT): imGuiButton = 0
            case Int32(SDL_BUTTON_RIGHT): imGuiButton = 1
            case Int32(SDL_BUTTON_MIDDLE): imGuiButton = 2
            default: return false
            }
            target.inputQueue.append(.mouseButton(index: imGuiButton, down: isDown))
            return target.wantCaptureMouse

        case UInt32(SDL_EVENT_MOUSE_WHEEL.rawValue):
            var wheelX = event.wheel.x
            var wheelY = event.wheel.y
            if event.wheel.direction.rawValue == SDL_MouseWheelDirection.flipped.rawValue {
                wheelX *= -1
                wheelY *= -1
            }
            target.inputQueue.append(.mouseWheel(x: wheelX, y: wheelY))
            return target.wantCaptureMouse

        case UInt32(SDL_EVENT_TEXT_INPUT.rawValue):
            if let textPtr = event.text.text {
                target.inputQueue.append(.text(String(cString: textPtr)))
            }
            return target.wantCaptureKeyboard

        case UInt32(SDL_EVENT_KEY_DOWN.rawValue),
            UInt32(SDL_EVENT_KEY_UP.rawValue):
            let isDown = (event.type == UInt32(SDL_EVENT_KEY_DOWN.rawValue))
            let imKey = Self.mapSDLKeyToImGuiKey(event.key.key)

            if imKey != ImGuiKey_None {
                target.inputQueue.append(.key(key: imKey, down: isDown))
            }

            if event.key.scancode == SDL_SCANCODE_LCTRL || event.key.scancode == SDL_SCANCODE_RCTRL {
                target.inputQueue.append(.key(key: ImGuiMod_Ctrl, down: isDown))
            }
            if event.key.scancode == SDL_SCANCODE_LSHIFT || event.key.scancode == SDL_SCANCODE_RSHIFT {
                target.inputQueue.append(.key(key: ImGuiMod_Shift, down: isDown))
            }
            if event.key.scancode == SDL_SCANCODE_LALT || event.key.scancode == SDL_SCANCODE_RALT {
                target.inputQueue.append(.key(key: ImGuiMod_Alt, down: isDown))
            }
            if event.key.scancode == SDL_SCANCODE_LGUI || event.key.scancode == SDL_SCANCODE_RGUI {
                target.inputQueue.append(.key(key: ImGuiMod_Super, down: isDown))
            }
            return target.wantCaptureKeyboard

        case UInt32(SDL_EVENT_WINDOW_FOCUS_GAINED.rawValue):
            target.inputQueue.append(.focus(gained: true))
            return false

        case UInt32(SDL_EVENT_WINDOW_FOCUS_LOST.rawValue):
            // Mirror the stock-backend behavior: a window that loses focus
            // releases everything it held so no button stays stuck down.
            target.inputQueue.append(.focus(gained: false))
            for button in 0..<5 {
                target.inputQueue.append(.mouseButton(index: Int32(button), down: false))
            }
            return false

        case UInt32(SDL_EVENT_WINDOW_MOUSE_LEAVE.rawValue):
            target.hasMousePos = false
            return false

        default:
            return false
        }
    }

    /// Drain a window's queued input into the shared ImGui context. Must run
    /// immediately before that window's `NewFrame`, after its `DisplaySize`
    /// is set. Always re-seeds the window's last known mouse position first:
    /// `io.MousePos` still holds whichever window framed last.
    private static let debugInputGates =
        ProcessInfo.processInfo.environment["ZEPHYR_DEBUG_INPUT"] != nil

    internal func replayQueuedInput(for target: EngineManagedWindow, appFocused: Bool) {
        defer { target.inputQueue.removeAll(keepingCapacity: true) }
        guard let io = ImGuiGetIO() else { return }
        if Self.debugInputGates && !target.isMain && !target.inputQueue.isEmpty {
            let kinds = target.inputQueue.map { queued -> String in
                switch queued {
                case .mousePos: return "pos"
                case .mouseButton(let index, let down): return "btn\(index)\(down ? "+" : "-")"
                case .mouseWheel: return "wheel"
                case .key(_, let down): return down ? "key+" : "key-"
                case .text: return "text"
                case .focus(let gained): return gained ? "foc+" : "foc-"
                }
            }.joined(separator: ",")
            print("[InputGate] REPLAY win=\(target.id) queued=[\(kinds)] "
                + "hasMousePos=\(target.hasMousePos) mouse=(\(target.mouseX),\(target.mouseY)) "
                + "appFocused=\(appFocused)")
        }

        if target.hasMousePos {
            ImGuiIO_AddMousePosEvent(io, target.mouseX, target.mouseY)
        } else {
            ImGuiIO_AddMousePosEvent(io, -256000.0, -256000.0)
        }
        for queued in target.inputQueue {
            switch queued {
            case .mousePos(let x, let y):
                ImGuiIO_AddMousePosEvent(io, x, y)
            case .mouseButton(let index, let down):
                ImGuiIO_AddMouseButtonEvent(io, index, down)
            case .mouseWheel(let x, let y):
                ImGuiIO_AddMouseWheelEvent(io, x, y)
            case .key(let key, let down):
                ImGuiIO_AddKeyEvent(io, key, down)
            case .text(let string):
                string.withCString { ImGuiIO_AddInputCharactersUTF8(io, $0) }
            case .focus(let gained):
                // ImGui app focus is global, but the queued events are
                // per-window: one window losing focus to a sibling is not
                // an app-focus loss (which would clear keys/active state
                // mid-typing). Only report loss when nothing is focused.
                ImGuiIO_AddFocusEvent(io, gained || appFocused)
            }
        }
    }

    private static func mapSDLKeyToImGuiKey(_ k: UInt32) -> ImGuiKey {
        switch k {
        case SDLK_TAB:        return ImGuiKey_Tab
        case SDLK_LEFT:       return ImGuiKey_LeftArrow
        case SDLK_RIGHT:      return ImGuiKey_RightArrow
        case SDLK_UP:         return ImGuiKey_UpArrow
        case SDLK_DOWN:       return ImGuiKey_DownArrow
        case SDLK_PAGEUP:     return ImGuiKey_PageUp
        case SDLK_PAGEDOWN:   return ImGuiKey_PageDown
        case SDLK_HOME:       return ImGuiKey_Home
        case SDLK_END:        return ImGuiKey_End
        case SDLK_INSERT:     return ImGuiKey_Insert
        case SDLK_DELETE:     return ImGuiKey_Delete
        case SDLK_BACKSPACE:  return ImGuiKey_Backspace
        case SDLK_SPACE:      return ImGuiKey_Space
        case SDLK_RETURN, SDLK_KP_ENTER: return ImGuiKey_Enter
        case SDLK_ESCAPE:     return ImGuiKey_Escape
        case SDLK_CAPSLOCK:   return ImGuiKey_CapsLock
        case SDLK_SCROLLLOCK: return ImGuiKey_ScrollLock
        case SDLK_NUMLOCKCLEAR: return ImGuiKey_NumLock
        case SDLK_PRINTSCREEN: return ImGuiKey_PrintScreen
        case SDLK_PAUSE:      return ImGuiKey_Pause
        case SDLK_A...SDLK_Z:
            return ImGuiKey(rawValue: ImGuiKey_A.rawValue + ImGuiKey.RawValue(k - SDLK_A))
        case SDLK_0...SDLK_9:
            return ImGuiKey(rawValue: ImGuiKey_0.rawValue + ImGuiKey.RawValue(k - SDLK_0))
        case SDLK_F1...SDLK_F12:
            return ImGuiKey(rawValue: ImGuiKey_F1.rawValue + ImGuiKey.RawValue(k - SDLK_F1))
        case SDLK_KP_0: return ImGuiKey_Keypad0
        case SDLK_KP_1: return ImGuiKey_Keypad1
        case SDLK_KP_2: return ImGuiKey_Keypad2
        case SDLK_KP_3: return ImGuiKey_Keypad3
        case SDLK_KP_4: return ImGuiKey_Keypad4
        case SDLK_KP_5: return ImGuiKey_Keypad5
        case SDLK_KP_6: return ImGuiKey_Keypad6
        case SDLK_KP_7: return ImGuiKey_Keypad7
        case SDLK_KP_8: return ImGuiKey_Keypad8
        case SDLK_KP_9: return ImGuiKey_Keypad9
        case SDLK_KP_DECIMAL:  return ImGuiKey_KeypadDecimal
        case SDLK_KP_DIVIDE:   return ImGuiKey_KeypadDivide
        case SDLK_KP_MULTIPLY: return ImGuiKey_KeypadMultiply
        case SDLK_KP_MINUS:    return ImGuiKey_KeypadSubtract
        case SDLK_KP_PLUS:     return ImGuiKey_KeypadAdd
        case SDLK_KP_EQUALS:   return ImGuiKey_KeypadEqual
        case SDLK_LCTRL:       return ImGuiKey_LeftCtrl
        case SDLK_LSHIFT:      return ImGuiKey_LeftShift
        case SDLK_LALT:        return ImGuiKey_LeftAlt
        case SDLK_LGUI:        return ImGuiKey_LeftSuper
        case SDLK_RCTRL:       return ImGuiKey_RightCtrl
        case SDLK_RSHIFT:      return ImGuiKey_RightShift
        case SDLK_RALT:        return ImGuiKey_RightAlt
        case SDLK_RGUI:        return ImGuiKey_RightSuper
        case SDLK_MENU:        return ImGuiKey_Menu
        case SDLK_COMMA:       return ImGuiKey_Comma
        case SDLK_PERIOD:      return ImGuiKey_Period
        case SDLK_SLASH:       return ImGuiKey_Slash
        case SDLK_SEMICOLON:   return ImGuiKey_Semicolon
        case SDLK_EQUALS:      return ImGuiKey_Equal
        case SDLK_LEFTBRACKET:  return ImGuiKey_LeftBracket
        case SDLK_BACKSLASH:    return ImGuiKey_Backslash
        case SDLK_RIGHTBRACKET: return ImGuiKey_RightBracket
        case SDLK_GRAVE:        return ImGuiKey_GraveAccent
        case SDLK_MINUS:        return ImGuiKey_Minus
        case SDLK_APOSTROPHE:   return ImGuiKey_Apostrophe
        default:
            return ImGuiKey_None
        }
    }
}
