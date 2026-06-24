import Foundation
import SwiftSDL

// =========================================================================
// MARK: - CADCommandProcessor
//
// The central command dispatcher for the EngineAsBuilt CAD application.
// Manages command registration, execution, and interactive feature command
// lifecycle (start → input events → cancel/finish).
//
// Two command types are supported:
//   1. One-shot commands: Execute immediately on invocation (e.g., ZOOMEXTENTS,
//      UNDO, REDO). These are non-interactive.
//   2. Feature commands: Stateful commands that receive mouse/keyboard input
//      until the user signals completion (e.g., LINE, CIRCLE, HATCH).
//
// The processor also manages the command-line UI state including the input
// buffer, autocomplete matching, and selection index navigation.

// =========================================================================
// MARK: - CommandResult / FeatureCommand Protocol
// =========================================================================

/// Result returned by `FeatureCommand` event handlers.
public enum CommandResult {
    /// Command is still active, waiting for more input.
    case `continue`
    /// Command is finished — the processor will call `cancel()` and release it.
    case finished
}

/// Protocol for a stateful, interactive feature command (e.g. CleanSpeckles).
/// The `CADCommandProcessor` routes all unhandled mouse clicks, mouse motion,
/// and key events to the active feature command until it signals `.finished`.
///
/// Conformers must be **class-bound** (`AnyObject`) so the processor can hold
/// a reference and the command can mutate its own internal state.
@MainActor
public protocol FeatureCommand: AnyObject {
    /// Called once when the command becomes active.
    func start(engine: PhrostEngine, processor: CADCommandProcessor)

    /// Called on cancellation (Escape) or when the command finishes normally.
    func cancel(engine: PhrostEngine, processor: CADCommandProcessor)

    /// Left mouse button down in world-space coordinates.
    func handleMouseClick(worldX: Double, worldY: Double, engine: PhrostEngine, processor: CADCommandProcessor) -> CommandResult

    /// Mouse motion in world-space (called every frame the mouse moves).
    func handleMouseMotion(worldX: Double, worldY: Double, engine: PhrostEngine, processor: CADCommandProcessor)

    /// Key-down events not handled by the main loop (Escape is intercepted before routing).
    func handleKeyDown(scancode: SDL_Scancode, engine: PhrostEngine, processor: CADCommandProcessor) -> CommandResult

    /// Called every frame during `render()` after the crosshair cursor, so the
    /// command can draw visual overlays (selection rectangle, rubber-band lines,
    /// custom cursors, etc.) onto the ImGui foreground draw list.
    /// Use `igGetForegroundDrawList_ViewportPtr(nil)` to draw.
    func renderOverlay(cam: CameraTransform, engine: PhrostEngine)

    /// Called during the main ImGui rendering phase, allowing the command to
    /// draw standard ImGui windows, popups, and dialogs.
    func renderImGui(engine: PhrostEngine)

    /// Determines whether CAD cursor snapping is active while this command is running.
    var isSnappingEnabled: Bool { get }

    /// In-progress points that should be snap targets during drawing.
    func getDrawingSnapPoints() -> [Vector3]

    /// Called when the user types text into the command line and presses Enter
    /// while this command is active but the text didn't match a registered command.
    /// Returns `.finished` if the command consumed the text and is done;
    /// `.continue` if the text was consumed but the command is still active.
    func handleCommandText(_ text: String, engine: PhrostEngine, processor: CADCommandProcessor) -> CommandResult
}

public extension FeatureCommand {
    /// Determines whether CAD cursor snapping is active while this command is running.
    var isSnappingEnabled: Bool { return true }

    /// In-progress points that should be snap targets during drawing.
    /// Default: empty — only multi-point commands override.
    func getDrawingSnapPoints() -> [Vector3] { [] }

    /// Default implementation: does nothing.
    func renderImGui(engine: PhrostEngine) {}

    /// Default: ignore command-line text.
    func handleCommandText(_ text: String, engine: PhrostEngine, processor: CADCommandProcessor) -> CommandResult { .continue }
}

// =========================================================================
// MARK: - Command Metadata (Autocomplete)
// =========================================================================

/// Category for grouping commands in autocomplete suggestions.
public enum CommandCategory: String, CaseIterable, Sendable {
    case draw    = "Draw"
    case modify  = "Modify"
    case view    = "View"
    case layer   = "Layer"
    case block   = "Block"
    case settings = "Settings"
}

/// Metadata describing one CAD command for autocomplete and help.
public struct CommandDescriptor: Sendable {
    /// Canonical command name (uppercased, e.g. "MOVE").
    public let canonicalName: String
    /// Alternative short names that trigger the same command.
    public let aliases: [String]
    /// UI grouping category.
    public let category: CommandCategory
    /// Parameter syntax hint displayed in the suggestion popup (e.g. "<name>", "<index|hex>").
    public let syntax: String
    /// One-sentence description of what the command does.
    public let description: String

    /// All strings that match this command (canonical name + all aliases).
    public var allMatches: [String] {
        [canonicalName] + aliases
    }

    public init(
        canonicalName: String,
        aliases: [String] = [],
        category: CommandCategory,
        syntax: String = "",
        description: String = ""
    ) {
        self.canonicalName = canonicalName.uppercased()
        self.aliases = aliases.map { $0.uppercased() }
        self.category = category
        self.syntax = syntax
        self.description = description
    }

    /// Master list of every known command, used for autocomplete matching.
    /// Feature commands that are dynamically registered are added at startup
    /// via `addDynamicDescriptor(_:)`.
    public nonisolated(unsafe) static var allCommands: [CommandDescriptor] = [
        // --- File ---
        CommandDescriptor(canonicalName: "NEW",        aliases: ["N"],             category: .draw,    syntax: "", description: "Create a new blank drawing in a new tab"),
        CommandDescriptor(canonicalName: "OPEN",       aliases: [],                category: .draw,    syntax: "", description: "Open a DXF or EAB file in a new tab"),
        CommandDescriptor(canonicalName: "CLOSE",      aliases: [],                category: .draw,    syntax: "", description: "Close the active drawing tab"),
        CommandDescriptor(canonicalName: "SAVE",       aliases: [],                category: .draw,    syntax: "", description: "Save the current drawing to its file"),
        CommandDescriptor(canonicalName: "SAVEAS",     aliases: [],                category: .draw,    syntax: "", description: "Save the current drawing as a new file"),
        CommandDescriptor(canonicalName: "PDFEXPORT",  aliases: ["EXPORTPDF"],     category: .draw,    syntax: "", description: "Export the current drawing to a PDF file"),
        CommandDescriptor(canonicalName: "PDFIMPORT",  aliases: ["PDFI", "PDF"],   category: .draw,    syntax: "", description: "Import a PDF page as an image underlay"),
        // --- Draw ---
        CommandDescriptor(canonicalName: "LINE",       aliases: ["L"],             category: .draw,    syntax: "", description: "Draw a line segment by picking two points"),
        CommandDescriptor(canonicalName: "POLYLINE",   aliases: ["PL", "PLINE"],   category: .draw,    syntax: "", description: "Draw a multi-segment polyline"),
        CommandDescriptor(canonicalName: "CIRCLE",     aliases: ["C"],             category: .draw,    syntax: "", description: "Draw a circle by center and radius"),
        CommandDescriptor(canonicalName: "ARC",        aliases: ["A"],             category: .draw,    syntax: "", description: "Draw an arc by center, radius, and angles"),
        CommandDescriptor(canonicalName: "RECTANGLE",  aliases: ["REC", "RECT"],   category: .draw,    syntax: "", description: "Draw a rectangle by two opposite corners"),
        CommandDescriptor(canonicalName: "ELLIPSE",    aliases: ["EL"],            category: .draw,    syntax: "", description: "Draw an ellipse by center and axes"),
        CommandDescriptor(canonicalName: "HATCH",      aliases: ["H", "BH"],       category: .draw,    syntax: "", description: "Fill a closed boundary with a hatch pattern"),
        CommandDescriptor(canonicalName: "SPLINE",     aliases: ["SPL"],           category: .draw,    syntax: "", description: "Draw a smooth spline curve through control points"),
        CommandDescriptor(canonicalName: "RAY",        aliases: [],                category: .draw,    syntax: "", description: "Draw a ray from a start point in a direction"),
        CommandDescriptor(canonicalName: "DRAW",       aliases: ["D", "TOOLS"],    category: .draw,    syntax: "", description: "Open the draw tools palette"),
        CommandDescriptor(canonicalName: "TEXT",       aliases: ["T", "DTEXT", "MTEXT"], category: .draw, syntax: "", description: "Place a new text entity"),
        CommandDescriptor(canonicalName: "MEASUREGEOM",aliases: ["MEASURE", "MEA", "MG"], category: .draw, syntax: "", description: "Measure geometry: quick measure, distance, area, and angle"),
        // --- Modify ---
        CommandDescriptor(canonicalName: "MOVE",       aliases: ["M"],             category: .modify,  syntax: "", description: "Move selected entities by picking two points"),
        CommandDescriptor(canonicalName: "ROTATE",     aliases: ["R"],             category: .modify,  syntax: "", description: "Rotate selected entities around their collective center"),
        CommandDescriptor(canonicalName: "SCALE",      aliases: ["S"],             category: .modify,  syntax: "", description: "Scale selected entities around their collective center"),
        CommandDescriptor(canonicalName: "ERASE",      aliases: ["E"],             category: .modify,  syntax: "", description: "Delete all currently selected entities"),
        CommandDescriptor(canonicalName: "CLEANSPECKLES", aliases: ["CS", "SPECKLES"], category: .modify, syntax: "", description: "Remove tiny/speckle entities from the drawing"),
        CommandDescriptor(canonicalName: "DDEDIT",     aliases: ["ED"],            category: .modify,  syntax: "", description: "Edit the selected text entity"),
        CommandDescriptor(canonicalName: "JOIN",       aliases: ["J"],             category: .modify,  syntax: "", description: "Join selected line entities into polylines"),
        CommandDescriptor(canonicalName: "TRIM",       aliases: ["TR"],            category: .modify,  syntax: "", description: "Trim lines at intersections — click the side to remove"),
        CommandDescriptor(canonicalName: "SPLINEEDIT", aliases: ["SPE"],           category: .modify,  syntax: "", description: "Edit an existing spline (reverse, convert to polyline, etc.)"),
        // --- View ---
        CommandDescriptor(canonicalName: "SELECTALL",  aliases: ["SELALL"],        category: .view,    syntax: "", description: "Select all entities in the active layer"),
        CommandDescriptor(canonicalName: "ZOOM",        aliases: ["Z"],             category: .view,    syntax: "", description: "Zoom: All/Center/Dynamic/Extents/Left/Previous/Right/Scale/Object/Window"),
        CommandDescriptor(canonicalName: "ZOOMEXTENTS",aliases: ["ZOOME"],         category: .view,    syntax: "", description: "Zoom to fit all entities in the viewport"),
        CommandDescriptor(canonicalName: "VIEW",       aliases: ["VIEWS"],         category: .view,    syntax: "[name|index]", description: "List, select, or cycle model and sheet views"),
        CommandDescriptor(canonicalName: "SHEET",      aliases: ["LAYOUT"],        category: .view,    syntax: "[name|index]", description: "Select or cycle imported DXF sheet layouts"),
        CommandDescriptor(canonicalName: "MODEL",      aliases: ["2DVIEW"],        category: .view,    syntax: "", description: "Switch to the DXF 2D model-space view"),
        CommandDescriptor(canonicalName: "NEXTVIEW",   aliases: ["VIEWNEXT"],      category: .view,    syntax: "", description: "Switch to the next model or sheet view"),
        CommandDescriptor(canonicalName: "PREVIOUSVIEW", aliases: ["PREVVIEW", "VIEWPREV"], category: .view, syntax: "", description: "Switch to the previous model or sheet view"),
        CommandDescriptor(canonicalName: "AALINES",    aliases: ["AA"],            category: .view,    syntax: "", description: "Toggle anti-aliased line rendering on/off"),
        CommandDescriptor(canonicalName: "PROPS",      aliases: ["PROPERTIES", "PR"], category: .view, syntax: "", description: "Show/hide the properties panel for the selected entity"),
        CommandDescriptor(canonicalName: "NAV",        aliases: ["RADIALNAV"],     category: .view,    syntax: "", description: "Show/hide the radial navigation tool"),
        // --- Layer ---
        CommandDescriptor(canonicalName: "LAYER",      aliases: ["LA"],            category: .layer,   syntax: "", description: "Show/hide the layer panel"),
        CommandDescriptor(canonicalName: "LAYER NEW",  aliases: ["LA NEW"],        category: .layer,   syntax: "<name>", description: "Create a new layer with an optional name"),
        CommandDescriptor(canonicalName: "LAYER DELETE", aliases: ["LAYER DEL", "LA DELETE", "LA DEL"], category: .layer, syntax: "<name>", description: "Delete a layer by name"),
        CommandDescriptor(canonicalName: "LAYER RENAME", aliases: ["LA RENAME"],   category: .layer,   syntax: "<oldName> <newName>", description: "Rename an existing layer"),
        CommandDescriptor(canonicalName: "LAYERMOVE",    aliases: ["LM", "LAYMOVE"], category: .layer, syntax: "", description: "Move selected entities to a different layer (autocomplete prompt)"),
        // --- Block ---
        CommandDescriptor(canonicalName: "BLOCK",      aliases: ["BMAKE"],         category: .block,   syntax: "<name>", description: "Create a new block from selected entities"),
        CommandDescriptor(canonicalName: "BEDIT",      aliases: ["EDITBLOCK", "BE"], category: .block,  syntax: "", description: "Edit the selected block reference in-place"),
        CommandDescriptor(canonicalName: "BCLOSE",     aliases: [],                category: .block,   syntax: "", description: "Close the block editor and save changes"),
        CommandDescriptor(canonicalName: "BLOCKS",     aliases: ["BLOCKPANEL"],    category: .block,   syntax: "", description: "Show/hide the block panel"),
        // --- Settings ---
        CommandDescriptor(canonicalName: "THEME",      aliases: ["DARKMODE", "LIGHTMODE"], category: .settings, syntax: "[DARK|LIGHT]", description: "Toggle or set the UI theme (dark/light mode)"),
        CommandDescriptor(canonicalName: "FPS",        aliases: [],                        category: .settings, syntax: "", description: "Toggle FPS counter in the title bar"),
        CommandDescriptor(canonicalName: "SET-BACKGROUND", aliases: ["SETBG", "BACKGROUND"], category: .settings, syntax: "<index|hex>", description: "Set viewport background color (ACI index 1-255 or hex RRGGBB)"),
        CommandDescriptor(canonicalName: "GRID",            aliases: [],                category: .settings, syntax: "", description: "Toggle the background grid on/off"),
        CommandDescriptor(canonicalName: "GRID SNAP",       aliases: [],                category: .settings, syntax: "", description: "Toggle snapping to grid intersections on/off"),
        CommandDescriptor(canonicalName: "GRID SPACING",    aliases: [],                category: .settings, syntax: "<value>", description: "Set the base grid spacing in world units"),
        CommandDescriptor(canonicalName: "GRID ORIGIN",     aliases: [],                category: .settings, syntax: "<x> <y>", description: "Set the grid origin in world coordinates"),
        CommandDescriptor(canonicalName: "SIMPLIFY",        aliases: ["SIMP", "COMPLEX", "COMPLEXBLOCKS"], category: .settings, syntax: "[ON|OFF]", description: "Toggle or set the simplification of complex block references to bounding boxes on/off"),
        CommandDescriptor(canonicalName: "SIMPLIFYPOLY",    aliases: ["SIMPPOLY", "COMPLEXPOLY", "SIMPLIFYPOLYLINES"], category: .settings, syntax: "[ON|OFF]", description: "Toggle or set the simplification of dense polylines on/off"),
        // --- Snap Toggles ---
        CommandDescriptor(canonicalName: "POLAR",           aliases: [],                category: .settings, syntax: "", description: "Toggle polar tracking on/off"),
        CommandDescriptor(canonicalName: "POLARANG",        aliases: [],                category: .settings, syntax: "<degrees>", description: "Set polar angle increment (e.g. 15, 30, 45, 90)"),
        CommandDescriptor(canonicalName: "OTRACK",          aliases: [],                category: .settings, syntax: "", description: "Toggle object snap tracking on/off"),
        CommandDescriptor(canonicalName: "EXTENSION",       aliases: ["EXT"],           category: .settings, syntax: "", description: "Toggle extension snapping on/off"),
    ]
}

// =========================================================================
// MARK: - CADCommandProcessor
// =========================================================================

/// Encapsulates the CAD command-line entry system: command state, execution,
/// and click/motion handling during active two-point commands (MOVE, ROTATE, SCALE).
///
/// Held by `PhrostEngine` as a single `commandProcessor` property.
/// All command state and logic lives here; the engine only retains direct-action
/// methods (`deleteSelected`, `selectAll`, `zoomExtents`) that are also called
/// from keyboard shortcuts.
@MainActor
public final class CADCommandProcessor {
    // MARK: Command State

    /// Active command name, e.g. "MOVE", "ROTATE", nil when idle.
    public internal(set) var activeCommand: String? = nil
    /// Prompt text to display during command execution.
    public internal(set) var commandPrompt: String? = nil
    /// Whether the command line input is open for typing.
    public var commandLineActive: Bool = false
    /// Current command text buffer.
    public var commandBuffer: String = ""
    /// Stored reference point for two-point commands (MOVE, etc.).
    public internal(set) var commandRefPoint: (Double, Double)? = nil
    /// Autocomplete selection index into the current match list (0-based).
    public var commandSelectionIndex: Int = 0
    /// Last text for which matches were computed (avoids recalc every frame).
    private let commandMatcher = CADCommandMatcher()
    internal var _lastMatchInput: String {
        get { commandMatcher.lastInput }
        set { commandMatcher.lastInput = newValue }
    }
    /// Cached autocomplete matches.
    internal var _cachedMatches: [(descriptor: CommandDescriptor, matchingAlias: String)] {
        get { commandMatcher.cachedMatches }
        set { commandMatcher.cachedMatches = newValue }
    }

    /// Last executed command text, used by Spacebar repeat-last-command (AutoCAD style).
    public var lastExecutedCommand: String?

    // MARK: Move Ghost Preview State
    /// World-space mouse position during MOVE command (for ghost preview).
    public internal(set) var _moveGhostWorldX: Double = 0
    public internal(set) var _moveGhostWorldY: Double = 0

    // MARK: Feature Command State

    /// Currently active feature command (class-bound protocol reference).
    /// When non-nil, all mouse/key events are routed to it instead of the
    /// built-in tool handlers.
    public internal(set) var activeFeatureCommand: (any FeatureCommand)? = nil

    /// Registry of feature command factories, keyed by canonical name and aliases.
    public typealias FeatureCommandFactory = () -> any FeatureCommand
    private var featureCommandRegistry: [String: FeatureCommandFactory] = [:]

    // MARK: Engine Reference

    /// Weak reference to the owning engine, used to access document, selection, and drag state.
    /// Set via `configure(engine:)` during `PhrostEngine.init?` after all stored properties are initialized.
    private weak var engine: PhrostEngine?

    // MARK: Initialization

    public init() {}

    /// Called by `PhrostEngine.init?` to provide the engine reference after self is available.
    internal func configure(engine: PhrostEngine) {
        self.engine = engine
    }

    // MARK: - Feature Command Registry

    /// Register a feature command factory under a canonical name and optional aliases.
    /// The factory is called each time the command is invoked, giving it a clean slate.
    /// If an optional descriptor is provided, it is added to the autocomplete registry.
    public func registerFeatureCommand(
        name: String, aliases: [String] = [],
        descriptor: CommandDescriptor? = nil,
        factory: @escaping FeatureCommandFactory
    ) {
        featureCommandRegistry[name.uppercased()] = factory
        for alias in aliases {
            featureCommandRegistry[alias.uppercased()] = factory
        }
        // Register in the autocomplete descriptor list if not already present.
        if let desc = descriptor {
            if !CommandDescriptor.allCommands.contains(where: { $0.canonicalName == desc.canonicalName }) {
                CommandDescriptor.allCommands.append(desc)
            }
        }
    }

    /// Clean up the active feature command (calls `cancel()`, nils the reference,
    /// and resets the prompt).
    internal func finishFeatureCommand(engine: PhrostEngine) {
        guard let cmd = activeFeatureCommand else { return }
        cmd.cancel(engine: engine, processor: self)
        activeFeatureCommand = nil
        commandPrompt = nil
    }

    // MARK: - Command Execution

    /// Execute a command string (e.g. "MOVE", "M", "ERASE").
    public func executeCommand(_ text: String) {
        let upper = text.uppercased().trimmingCharacters(in: .whitespaces)
        guard !upper.isEmpty else { return }
        lastExecutedCommand = text

        if handleDrawingViewCommand(text) {
            clearCommand()
            return
        }

        // If a command is active waiting for additional input, handle it here.
        if let cmd = activeCommand {
            switch cmd {
            case "BLOCK":
                if let engine = engine, !upper.isEmpty {
                    let block = engine.document.createBlockFromEntities(
                        handles: engine.cadSelection.selectedHandles, name: text.trimmingCharacters(in: .whitespaces))
                    if block != nil {
                        print("[CAD] Block '\(text.trimmingCharacters(in: .whitespaces))' created.")
                        engine.cadSelection.clearSelection()
                    } else {
                        print("[CAD] Failed to create block.")
                    }
                }
                clearCommand()
                return
            default:
                break
            }
        }

        switch upper {
        // --- File Commands ---
        case "N", "NEW":
            engine?.tabManager.newTab()
            engine?.zoomExtents()
            clearCommand()
        case "OPEN":
            engine?.fileBrowser.open(filterExtension: "dxf;eab")
            clearCommand()
        case "CLOSE":
            _ = engine?.tabManager.closeActiveTab()
            clearCommand()
        case "SAVE":
            guard let eng = engine else { clearCommand(); return }
            do {
                try eng.tabManager.saveActiveTab()
            } catch TabManager.TabError.noFileURL {
                eng.saveFileBrowser.openSave(
                    filterExtension: "dxf;eab;pdf",
                    defaultName: eng.tabManager.activeTab?.displayName ?? "untitled")
            } catch {
                print("Save failed: \(error)")
            }
            clearCommand()
        case "SAVEAS":
            engine?.saveFileBrowser.openSave(
                filterExtension: "dxf;eab;pdf",
                defaultName: engine?.tabManager.activeTab?.displayName ?? "untitled")
            clearCommand()
        case "PDFEXPORT", "EXPORTPDF":
            engine?.saveFileBrowser.openSave(
                filterExtension: "pdf",
                defaultName: (engine?.tabManager.activeTab?.displayName ?? "untitled")
                    .replacingOccurrences(of: ".dxf", with: "")
                    .replacingOccurrences(of: ".eab", with: "")
            )
            clearCommand()
        // --- Existing commands ---
        case "M", "MOVE":
            guard let engine = engine else { clearCommand(); return }
            guard engine.cadSelection.hasSelection else {
                clearCommand()
                return
            }
            startCommand("MOVE", prompt: "Select base point")
        case "R", "ROTATE":
            guard let engine = engine else { clearCommand(); return }
            guard engine.cadSelection.hasSelection else {
                clearCommand()
                return
            }
            startCommand("ROTATE", prompt: "Pick rotation angle or drag")
        case "S", "SCALE":
            guard let engine = engine else { clearCommand(); return }
            guard engine.cadSelection.hasSelection else {
                clearCommand()
                return
            }
            startCommand("SCALE", prompt: "Pick scale factor or drag")
        case "E", "ERASE":
            engine?.deleteSelected()
        case "SELALL", "SELECTALL":
            engine?.selectAll()
        case "ZOOME", "ZOOMEXTENTS":
            engine?.zoomExtents()
        case "AA", "AALINES":
            if let engine = engine {
                engine.renderer.antiAliasLines.toggle()
                print("[CAD] Anti-aliased lines: \(engine.renderer.antiAliasLines ? "ON" : "OFF")")
            }
            clearCommand()
        case "PROPS", "PROPERTIES", "PR":
            if let engine = engine, engine.cadSelection.hasSelection {
                engine.ui.showPropertiesPanel.toggle()
                print("[CAD] PROPS: showPropertiesPanel = \(engine.ui.showPropertiesPanel), hasSelection = \(engine.cadSelection.hasSelection), lastHandle = \(String(describing: engine.cadSelection.lastSelectedHandle))")
            } else {
                print("[CAD] PROPS: not toggled. engine=\(engine != nil), hasSelection=\(engine?.cadSelection.hasSelection ?? false)")
            }
            clearCommand()
        case "NAV", "RADIALNAV":
            if let engine = engine {
                engine.ui.radialNavVisible.toggle()
            }
            clearCommand()
        case "FPS":
            if let engine = engine {
                engine.ui.showFPS.toggle()
            }
            clearCommand()
        case "BEDIT", "EDITBLOCK", "BE":
            if let engine = engine {
                // Find a block reference to edit: prefer lastSelectedHandle if it has a blockID,
                // otherwise check the single selected handle.
                let editHandle: UUID?
                if let last = engine.cadSelection.lastSelectedHandle,
                   let entity = engine.document.entity(for: last),
                   entity.blockID != nil {
                    editHandle = last
                } else if engine.cadSelection.selectedHandles.count == 1,
                   let handle = engine.cadSelection.selectedHandles.first,
                   let entity = engine.document.entity(for: handle),
                   entity.blockID != nil {
                    editHandle = handle
                } else {
                    editHandle = nil
                }
                if let handle = editHandle,
                   let entity = engine.document.entity(for: handle),
                   let blockID = entity.blockID {
                    engine.tabManager.enterBlockEditor(blockID: blockID)
                    engine.cadSelection.clearSelection()
                } else {
                    print("[CAD] BEDIT requires a block reference entity to be selected.")
                }
            }
            clearCommand()
        case "BCLOSE":
            if let engine = engine {
                if engine.tabManager.activeTab?.editingBlockID != nil {
                    engine.tabManager.exitBlockEditor(saveChanges: true)
                }
            }
            clearCommand()
        case "BLOCK", "BMAKE":
            // BLOCK command: create a new block from selected entities.
            // Syntax: BLOCK <name>
            if let engine = engine {
                guard engine.cadSelection.hasSelection else {
                    print("[CAD] BLOCK requires entities to be selected.")
                    clearCommand()
                    break
                }
                // The name is the rest of the command text
                let namePart = String(text.dropFirst(upper.count)).trimmingCharacters(in: .whitespaces)
                if namePart.isEmpty {
                    // No name provided — prompt via command line
                    startCommand("BLOCK", prompt: "Enter block name")
                } else {
                    let block = engine.document.createBlockFromEntities(
                        handles: engine.cadSelection.selectedHandles, name: namePart)
                    if block != nil {
                        print("[CAD] Block '\(namePart)' created with \(engine.cadSelection.selectedHandles.count) entities.")
                        engine.cadSelection.clearSelection()
                    } else {
                        print("[CAD] Failed to create block '\(namePart)'.")
                    }
                    clearCommand()
                }
            }
        case "BLOCKS", "BLOCKPANEL":
            if let engine = engine {
                engine.ui.blockPanelVisible.toggle()
            }
            clearCommand()
        // --- Layer commands ---
        // --- Theme ---
        case "THEME", "DARKMODE", "LIGHTMODE":
            engine?.ui.toggleTheme()
            clearCommand()
        case _ where upper.hasPrefix("THEME "):
            let arg = String(upper.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            switch arg {
            case "DARK":
                if let eng = engine, !eng.ui.isDarkTheme { eng.ui.toggleTheme() }
            case "LIGHT":
                if let eng = engine, eng.ui.isDarkTheme { eng.ui.toggleTheme() }
            default:
                print("[CAD] Usage: THEME DARK|LIGHT  or  DARKMODE / LIGHTMODE")
            }
            clearCommand()
        case "LA", "LAYER":
            if let engine = engine {
                engine.ui.layersPanelVisible.toggle()
            }
            clearCommand()
        case _ where upper.hasPrefix("LAYER NEW ") || upper.hasPrefix("LA NEW "):
            guard let engine = engine else { clearCommand(); return }
            let namePart = text.dropFirst(upper.hasPrefix("LAYER ") ? 10 : 7).trimmingCharacters(in: .whitespaces)
            let name = namePart.isEmpty ? engine.document.uniqueLayerName() : namePart
            let layer = Layer(name: name)
            engine.document.addLayer(layer)
            print("[CAD] Layer '\(name)' created.")
            clearCommand()
        case _ where upper.hasPrefix("LAYER DELETE ") || upper.hasPrefix("LAYER DEL ") || upper.hasPrefix("LA DELETE ") || upper.hasPrefix("LA DEL "):
            guard let engine = engine else { clearCommand(); return }
            let prefixLen: Int
            if upper.hasPrefix("LAYER DELETE ") { prefixLen = 13 }
            else if upper.hasPrefix("LAYER DEL ") { prefixLen = 10 }
            else if upper.hasPrefix("LA DELETE ") { prefixLen = 10 }
            else { prefixLen = 7 }  // "LA DEL "
            let namePart = String(text.dropFirst(prefixLen)).trimmingCharacters(in: .whitespaces)
            guard !namePart.isEmpty else {
                print("[CAD] LAYER DELETE requires a layer name.")
                clearCommand()
                return
            }
            guard let layer = engine.document.findLayer(named: namePart) else {
                print("[CAD] Layer '\(namePart)' not found.")
                clearCommand()
                return
            }
            guard engine.document.layerCount > 1 else {
                print("[CAD] Cannot delete the last remaining layer.")
                clearCommand()
                return
            }
            engine.document.removeLayer(handle: layer.handle)
            print("[CAD] Layer '\(namePart)' deleted.")
            clearCommand()
        case _ where upper.hasPrefix("LAYER RENAME ") || upper.hasPrefix("LA RENAME "):
            guard let engine = engine else { clearCommand(); return }
            let prefixLen = upper.hasPrefix("LAYER RENAME ") ? 13 : 10
            let args = String(text.dropFirst(prefixLen)).trimmingCharacters(in: .whitespaces)
            let parts = args.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else {
                print("[CAD] LAYER RENAME <oldName> <newName>")
                clearCommand()
                return
            }
            let oldName = String(parts[0])
            let newName = String(parts[1])
            guard let layer = engine.document.findLayer(named: oldName) else {
                print("[CAD] Layer '\(oldName)' not found.")
                clearCommand()
                return
            }
            if let existing = engine.document.findLayer(named: newName), existing.handle != layer.handle {
                print("[CAD] A layer named '\(newName)' already exists.")
                clearCommand()
                return
            }
            engine.document.renameLayer(handle: layer.handle, name: newName)
            print("[CAD] Layer '\(oldName)' renamed to '\(newName)'.")
            clearCommand()
        // --- Background color ---
        case _ where upper.hasPrefix("SET-BACKGROUND ") || upper.hasPrefix("SETBG ") || upper.hasPrefix("BACKGROUND "):
            guard let engine = engine else { clearCommand(); return }
            let prefixLen: Int
            if upper.hasPrefix("SET-BACKGROUND ") { prefixLen = 15 }
            else if upper.hasPrefix("SETBG ") { prefixLen = 6 }
            else { prefixLen = 11 }  // "BACKGROUND "
            let arg = String(text.dropFirst(prefixLen)).trimmingCharacters(in: .whitespaces)
            guard !arg.isEmpty else {
                print("[CAD] Usage: SET-BACKGROUND <index|hex>")
                print("[CAD]   ACI index (1-255) or hex RRGGBB (e.g. BD20FF)")
                clearCommand()
                return
            }
            // Try parsing as hex (exactly 6 hex chars)
            if arg.count == 6, let hexVal = UInt32(arg, radix: 16) {
                let r = Float((hexVal >> 16) & 0xFF) / 255.0
                let g = Float((hexVal >> 8) & 0xFF) / 255.0
                let b = Float(hexVal & 0xFF) / 255.0
                engine.ui.backgroundColor = SDL_FColor(r: r, g: g, b: b, a: 1.0)
                print("[CAD] Background set to #\(arg.uppercased()) (RGB \(Int(r*255)),\(Int(g*255)),\(Int(b*255)))")
            }
            // Try parsing as ACI index (1-255)
            else if let aci = Int32(arg), aci >= 1, aci <= 255 {
                let rgba = DXFColorTable.aciToRGBA(aci, color24: -1)
                let r = Float(rgba.r) / 255.0
                let g = Float(rgba.g) / 255.0
                let b = Float(rgba.b) / 255.0
                engine.ui.backgroundColor = SDL_FColor(r: r, g: g, b: b, a: 1.0)
                print("[CAD] Background set to ACI \(aci) (RGB \(rgba.r),\(rgba.g),\(rgba.b))")
            } else {
                print("[CAD] Invalid color: '\(arg)'. Use ACI index (1-255) or hex RRGGBB (e.g. BD20FF).")
            }
            clearCommand()
        // --- Simplify Complex Blocks ---
        case "SIMPLIFY", "SIMP", "COMPLEX", "COMPLEXBLOCKS":
            guard let engine = engine else { clearCommand(); return }
            engine.toggleSimplifyComplexBlocks()
            clearCommand()
        case _ where upper.hasPrefix("SIMPLIFY ") || upper.hasPrefix("SIMP ") || upper.hasPrefix("COMPLEX ") || upper.hasPrefix("COMPLEXBLOCKS "):
            guard let engine = engine else { clearCommand(); return }
            let prefixLen: Int
            if upper.hasPrefix("SIMPLIFY ") { prefixLen = 9 }
            else if upper.hasPrefix("SIMP ") { prefixLen = 5 }
            else if upper.hasPrefix("COMPLEX ") { prefixLen = 8 }
            else { prefixLen = 14 } // "COMPLEXBLOCKS "
            let arg = String(upper.dropFirst(prefixLen)).trimmingCharacters(in: .whitespaces)
            switch arg {
            case "ON", "1", "TRUE":
                if !engine.simplifyComplexBlocks { engine.toggleSimplifyComplexBlocks() }
            case "OFF", "0", "FALSE":
                if engine.simplifyComplexBlocks { engine.toggleSimplifyComplexBlocks() }
            default:
                print("[CAD] Usage: SIMPLIFY ON|OFF")
            }
            clearCommand()
        // --- Simplify Dense Polylines ---
        case "SIMPLIFYPOLY", "SIMPPOLY", "COMPLEXPOLY", "SIMPLIFYPOLYLINES":
            guard let engine = engine else { clearCommand(); return }
            engine.toggleSimplifyPolylines()
            clearCommand()
        case _ where upper.hasPrefix("SIMPLIFYPOLY ") || upper.hasPrefix("SIMPPOLY ") || upper.hasPrefix("COMPLEXPOLY ") || upper.hasPrefix("SIMPLIFYPOLYLINES "):
            guard let engine = engine else { clearCommand(); return }
            let prefixLen: Int
            if upper.hasPrefix("SIMPLIFYPOLY ") { prefixLen = 13 }
            else if upper.hasPrefix("SIMPPOLY ") { prefixLen = 9 }
            else if upper.hasPrefix("COMPLEXPOLY ") { prefixLen = 12 }
            else { prefixLen = 18 } // "SIMPLIFYPOLYLINES "
            let arg = String(upper.dropFirst(prefixLen)).trimmingCharacters(in: .whitespaces)
            switch arg {
            case "ON", "1", "TRUE":
                if !engine.simplifyPolylines { engine.toggleSimplifyPolylines() }
            case "OFF", "0", "FALSE":
                if engine.simplifyPolylines { engine.toggleSimplifyPolylines() }
            default:
                print("[CAD] Usage: SIMPLIFYPOLY ON|OFF")
            }
            clearCommand()
        // --- Grid ---
        case "GRID":
            guard let engine = engine else { clearCommand(); return }
            engine.snap.gridVisible.toggle()
            print("[CAD] Grid: \(engine.snap.gridVisible ? "ON" : "OFF")")
            clearCommand()
        case "GRID SNAP":
            guard let engine = engine else { clearCommand(); return }
            engine.snap.gridSnapEnabled.toggle()
            print("[CAD] Grid Snap: \(engine.snap.gridSnapEnabled ? "ON" : "OFF")")
            clearCommand()
        case _ where upper.hasPrefix("GRID SPACING "):
            guard let engine = engine else { clearCommand(); return }
            let arg = String(text.dropFirst(13)).trimmingCharacters(in: .whitespaces)
            guard let val = Double(arg), val > 0 else {
                print("[CAD] GRID SPACING requires a positive number (e.g. 'GRID SPACING 5')")
                clearCommand()
                return
            }
            engine.snap.gridBaseSpacing = val
            print("[CAD] Grid spacing set to \(val)")
            clearCommand()
        case _ where upper.hasPrefix("GRID ORIGIN "):
            guard let engine = engine else { clearCommand(); return }
            let args = String(text.dropFirst(12)).trimmingCharacters(in: .whitespaces)
                .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard args.count == 2,
                  let x = Double(args[0]),
                  let y = Double(args[1]) else {
                print("[CAD] GRID ORIGIN requires two numbers (e.g. 'GRID ORIGIN 100 50')")
                clearCommand()
                return
            }
            engine.snap.gridOriginX = x
            engine.snap.gridOriginY = y
            print("[CAD] Grid origin set to (\(x), \(y))")
            clearCommand()
        // --- Snap Toggles ---
        case "POLAR":
            guard let engine = engine else { clearCommand(); return }
            engine.snap.polarTrackingEnabled.toggle()
            print("[CAD] Polar Tracking: \(engine.snap.polarTrackingEnabled ? "ON" : "OFF")")
            clearCommand()
        case _ where upper.hasPrefix("POLARANG "):
            guard let engine = engine else { clearCommand(); return }
            let arg = String(text.dropFirst(9)).trimmingCharacters(in: .whitespaces)
            guard let val = Double(arg), val > 0, val <= 360 else {
                print("[CAD] POLARANG requires a positive angle in degrees (e.g. 15, 30, 45, 90)")
                clearCommand()
                return
            }
            engine.snap.polarAngleIncrement = val
            print("[CAD] Polar angle increment set to \(val)°")
            clearCommand()
        case "OTRACK":
            guard let engine = engine else { clearCommand(); return }
            engine.snap.objectSnapTrackingEnabled.toggle()
            if !engine.snap.objectSnapTrackingEnabled {
                engine.snap.snapTrackingEngine.clear()
            }
            print("[CAD] Object Snap Tracking: \(engine.snap.objectSnapTrackingEnabled ? "ON" : "OFF")")
            clearCommand()
        case "EXTENSION", "EXT":
            guard let engine = engine else { clearCommand(); return }
            engine.snap.extensionSnapEnabled.toggle()
            print("[CAD] Extension Snap: \(engine.snap.extensionSnapEnabled ? "ON" : "OFF")")
            clearCommand()
        case "LM", "LAYMOVE", "LAYERMOVE":
            // Layer Move: reassign selected entities with autocomplete popup
            guard let engine = engine else { clearCommand(); return }
            if engine.cadSelection.hasSelection {
                engine.ui.layerMoveActive = true
                engine.ui.layerMoveBuffer = ""
                engine.ui.layerMoveSelectionIndex = 0
                engine.ui.layerMoveMatches = engine.document.allLayers.sorted { $0.name < $1.name }
                commandLineActive = false
            } else {
                print("[CAD] LM requires entities to be selected.")
            }
            clearCommand()
        default:
            // If a feature command is active, give it a chance to consume the text
            // (e.g. ZoomCommand receiving scale factor input).
            if let featureCmd = activeFeatureCommand, let eng = engine {
                let result = featureCmd.handleCommandText(text, engine: eng, processor: self)
                if result == .finished {
                    finishFeatureCommand(engine: eng)
                }
            }
            // Try feature command registry before giving up.
            else if let factory = featureCommandRegistry[upper], let eng = engine {
                let cmd = factory()
                activeFeatureCommand = cmd
                cmd.start(engine: eng, processor: self)
            } else {
                clearCommand()
            }
        }
    }

    private func handleDrawingViewCommand(_ text: String) -> Bool {
        guard let engine else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard let command = parts.first?.uppercased() else { return false }
        let argument = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""

        switch command {
        case "MODEL", "2DVIEW":
            if engine.tabManager.switchToView(named: "Model") {
                engine.zoomExtents()
                print("[CAD] View: \(engine.tabManager.activeViewName ?? "Model")")
            }
            return true
        case "NEXTVIEW", "VIEWNEXT":
            if engine.tabManager.cycleView(direction: 1) {
                engine.zoomExtents()
                print("[CAD] View: \(engine.tabManager.activeViewName ?? "")")
            }
            return true
        case "PREVIOUSVIEW", "PREVVIEW", "VIEWPREV":
            if engine.tabManager.cycleView(direction: -1) {
                engine.zoomExtents()
                print("[CAD] View: \(engine.tabManager.activeViewName ?? "")")
            }
            return true
        case "VIEW", "VIEWS":
            if argument.isEmpty {
                printAvailableViews(engine.tabManager)
                if engine.tabManager.cycleView(direction: 1) {
                    engine.zoomExtents()
                    print("[CAD] View: \(engine.tabManager.activeViewName ?? "")")
                }
            } else if engine.tabManager.switchToView(named: argument) {
                engine.zoomExtents()
                print("[CAD] View: \(engine.tabManager.activeViewName ?? argument)")
            } else {
                print("[CAD] Unknown view '\(argument)'.")
                printAvailableViews(engine.tabManager)
            }
            return true
        case "SHEET", "LAYOUT":
            let sheets = engine.tabManager.availableViews.enumerated().filter { $0.element.kind == .sheet }
            if argument.isEmpty {
                if engine.tabManager.cycleView(direction: 1, sheetsOnly: true) {
                    engine.zoomExtents()
                    print("[CAD] Sheet: \(engine.tabManager.activeViewName ?? "")")
                } else {
                    print("[CAD] This drawing has no sheet layouts.")
                }
            } else {
                let targetIndex: Int?
                if let sheetNumber = Int(argument),
                   sheetNumber >= 1, sheetNumber <= sheets.count {
                    targetIndex = sheets[sheetNumber - 1].offset
                } else {
                    targetIndex = sheets.first(where: {
                        $0.element.name.caseInsensitiveCompare(argument) == .orderedSame
                    })?.offset
                }
                if let targetIndex, engine.tabManager.switchToView(at: targetIndex) {
                    engine.zoomExtents()
                    print("[CAD] Sheet: \(engine.tabManager.activeViewName ?? argument)")
                } else {
                    print("[CAD] Unknown sheet '\(argument)'.")
                    printAvailableViews(engine.tabManager)
                }
            }
            return true
        default:
            return false
        }
    }

    private func printAvailableViews(_ tabManager: TabManager) {
        let descriptions = tabManager.availableViews.enumerated().map { index, view in
            "\(index + 1): \(view.name)\(view.kind == .model ? " (2D)" : " (sheet)")"
        }
        print("[CAD] Views: \(descriptions.joined(separator: ", "))")
    }

    /// Repeat the last executed command (AutoCAD-style Space/Enter repeat).
    /// Cancels any active command or feature command first.
    public func repeatLastCommand(engine: PhrostEngine) {
        guard let lastCmd = lastExecutedCommand else { return }
        if activeFeatureCommand != nil {
            finishFeatureCommand(engine: engine)
        }
        if activeCommand != nil {
            clearCommand()
        }
        executeCommand(lastCmd)
    }

    /// Cancel any active command.
    internal func clearCommand() {
        activeCommand = nil
        commandPrompt = nil
        commandRefPoint = nil
        commandLineActive = false
        commandBuffer = ""
        commandSelectionIndex = 0
        _lastMatchInput = ""
        _cachedMatches = []
        _moveGhostWorldX = 0
        _moveGhostWorldY = 0
    }

    // MARK: - Command Helpers

    private func startCommand(_ name: String, prompt: String) {
        activeCommand = name
        commandPrompt = prompt
        commandRefPoint = nil
        commandLineActive = false
        commandBuffer = ""
        commandSelectionIndex = 0
        _lastMatchInput = ""
        _cachedMatches = []
    }

    // MARK: - Autocomplete Matching

    /// Fuzzy-match commands against the given input string.
    /// Returns descriptors whose canonical name or any alias contains the input's
    /// letters **in sequence**, ranked by a scoring heuristic.
    public func matchCommands(input rawInput: String) -> [(descriptor: CommandDescriptor, matchingAlias: String)] {
        commandMatcher.matches(input: rawInput)
    }

    /// Handle a world-space click during an active command.
    /// Called from the mouse-down handler in Engine+Loop.
    internal func handleCommandClick(worldX: Double, worldY: Double) {
        guard let engine = engine, let cmd = activeCommand else { return }
        switch cmd {
        case "MOVE":
            guard engine.cadSelection.hasSelection else {
                clearCommand()
                return
            }
            if commandRefPoint == nil {
                commandRefPoint = (worldX, worldY)
                commandPrompt = "Select destination point"
            } else {
                let dx = worldX - commandRefPoint!.0
                let dy = worldY - commandRefPoint!.1
                // Update GPU geometry immediately so grips/selection update
                engine.cadBridge.movePrimitivesDirect(
                    handles: engine.cadSelection.selectedHandles,
                    by: (dx, dy), in: engine.geometryManager,
                    spriteManager: engine.spriteManager)
                engine.cadSelection.moveAllSelected(by: Vector3(x: dx, y: dy, z: 0), document: engine.document)
                engine.interaction.cachedGripGeneration = -1
                clearCommand()
            }
        case "ROTATE":
            guard engine.cadSelection.hasSelection,
                let center = engine.cadSelection.collectiveCenter(document: engine.document)
            else {
                clearCommand()
                return
            }
            if commandRefPoint == nil {
                commandRefPoint = (worldX, worldY)
                engine.interaction.dragStartAngle = atan2(worldY - center.y, worldX - center.x)
                commandPrompt = "Drag to rotate"
                engine.interaction.dragActive = true
            } else {
                engine.interaction.dragActive = false
                engine.interaction.cachedGripGeneration = -1
                clearCommand()
            }
        case "SCALE":
            guard engine.cadSelection.hasSelection,
                let center = engine.cadSelection.collectiveCenter(document: engine.document)
            else {
                clearCommand()
                return
            }
            if commandRefPoint == nil {
                commandRefPoint = (worldX, worldY)
                engine.interaction.dragStartDistance = sqrt(
                    (worldX - center.x) * (worldX - center.x) + (worldY - center.y)
                        * (worldY - center.y))
                commandPrompt = "Drag to scale"
                engine.interaction.dragActive = true
            } else {
                engine.interaction.dragActive = false
                engine.interaction.cachedGripGeneration = -1
                clearCommand()
            }
        default:
            clearCommand()
        }
    }

    /// Handle mouse motion during an active command drag.
    /// Called from the mouse-motion handler in Engine+Loop.
    internal func handleCommandMotion(worldX: Double, worldY: Double) {
        guard let engine = engine else { return }

        // Track mouse position for MOVE ghost preview
        if activeCommand == "MOVE" && commandRefPoint != nil {
            _moveGhostWorldX = worldX
            _moveGhostWorldY = worldY
        }

        guard let cmd = activeCommand, engine.interaction.dragActive else { return }
        switch cmd {
        case "ROTATE":
            guard let center = engine.cadSelection.collectiveCenter(document: engine.document) else { return }
            let currentAngle = atan2(worldY - center.y, worldX - center.x)
            let delta = (currentAngle - engine.interaction.dragStartAngle) * 180.0 / .pi
            if abs(delta) > 0.1 {
                engine.cadSelection.rotateAllSelected(
                    around: center, angleDeltaRadians: delta * .pi / 180.0, document: engine.document)
                engine.interaction.dragStartAngle = currentAngle
            }
        case "SCALE":
            guard let center = engine.cadSelection.collectiveCenter(document: engine.document) else { return }
            let currentDist = sqrt(
                (worldX - center.x) * (worldX - center.x) + (worldY - center.y)
                    * (worldY - center.y))
            if engine.interaction.dragStartDistance > 0.1 && abs(currentDist - engine.interaction.dragStartDistance) > 0.5 {
                let factor = currentDist / engine.interaction.dragStartDistance
                engine.cadSelection.scaleAllSelected(around: center, factor: factor, document: engine.document)
                engine.interaction.dragStartDistance = currentDist
            }
        default:
            break
        }
    }
}
