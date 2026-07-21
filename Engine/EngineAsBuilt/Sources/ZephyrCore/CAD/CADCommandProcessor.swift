import Foundation
import SwiftSDL

// =========================================================================
// MARK: - CADCommandProcessor
//
// The central command dispatcher for the Zephyr CAD application.
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
    /// The event was NOT consumed — the engine should fall through to its default behavior.
    case `continue`
    /// The event was consumed by the command — the engine should NOT run its default behavior.
    case handled
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
        CommandDescriptor(canonicalName: "OPEN",       aliases: [],                category: .draw,    syntax: "", description: "Open a DXF, DWG or EAB file in a new tab"),
        CommandDescriptor(canonicalName: "CLOSE",      aliases: [],                category: .draw,    syntax: "", description: "Close the active drawing tab"),
        CommandDescriptor(canonicalName: "CLOSEALL",   aliases: [],                category: .draw,    syntax: "", description: "Close all open drawing tabs"),
        CommandDescriptor(canonicalName: "CLOSEALLOTHERS", aliases: [],            category: .draw,    syntax: "", description: "Close all tabs except the active one"),
        CommandDescriptor(canonicalName: "SAVE",       aliases: ["QSAVE"],          category: .draw,    syntax: "", description: "Save the current drawing to its file"),
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
        CommandDescriptor(canonicalName: "DIMLINEAR",  aliases: ["DLI", "DIMLIN"], category: .draw, syntax: "", description: "Horizontal or vertical dimension between two points"),
        CommandDescriptor(canonicalName: "DIMALIGNED", aliases: ["DAL", "DIMALIGN"], category: .draw, syntax: "", description: "Dimension parallel to measured distance"),
        CommandDescriptor(canonicalName: "DIMRADIUS",  aliases: ["DRA", "DIMRAD"], category: .draw, syntax: "", description: "Radius dimension for arcs/circles"),
        CommandDescriptor(canonicalName: "DIMDIAMETER",aliases: ["DDI", "DIMDIA"], category: .draw, syntax: "", description: "Diameter dimension for arcs/circles"),
        CommandDescriptor(canonicalName: "DIMANGULAR", aliases: ["DAN", "DIMANG"], category: .draw, syntax: "", description: "Angle dimension between two lines or an arc"),
        CommandDescriptor(canonicalName: "DIMARC",     aliases: ["DAR", "DIMARCLENGTH"], category: .draw, syntax: "", description: "Arc length dimension along a curve"),
        CommandDescriptor(canonicalName: "DIMORDINATE",aliases: ["DOR", "DIMORD"], category: .draw, syntax: "", description: "X or Y ordinate dimension from origin"),
        CommandDescriptor(canonicalName: "DIMJOGGED",  aliases: ["DJO", "DIMJOG"], category: .draw, syntax: "", description: "Jogged radius dimension for large radii"),
        // --- Modify ---
        CommandDescriptor(canonicalName: "MOVE",       aliases: ["M"],             category: .modify,  syntax: "", description: "Move selected entities by picking two points"),
        CommandDescriptor(canonicalName: "ROTATE",     aliases: ["R"],             category: .modify,  syntax: "", description: "Rotate selected entities around their collective center"),
        CommandDescriptor(canonicalName: "SCALE",      aliases: ["S"],             category: .modify,  syntax: "", description: "Scale selected entities around their collective center"),
        CommandDescriptor(canonicalName: "ALIGN",      aliases: ["AL"],             category: .modify,  syntax: "", description: "Align objects by matching two pairs of points (move, rotate, optionally scale)"),
        CommandDescriptor(canonicalName: "ERASE",      aliases: ["E"],             category: .modify,  syntax: "", description: "Delete all currently selected entities"),
        CommandDescriptor(canonicalName: "COPY",       aliases: ["CO", "CP"],      category: .modify,  syntax: "", description: "Duplicate selected entities within the drawing"),
        CommandDescriptor(canonicalName: "COPYCLIP",   aliases: [],                category: .modify,  syntax: "", description: "Copy selected entities to clipboard"),
        CommandDescriptor(canonicalName: "COPYBASE",   aliases: [],                category: .modify,  syntax: "", description: "Copy selected entities to clipboard with a base point"),
        CommandDescriptor(canonicalName: "PASTECLIP",  aliases: [],                category: .modify,  syntax: "", description: "Paste clipboard entities at viewport center"),
        CommandDescriptor(canonicalName: "PASTEORIG",  aliases: [],                category: .modify,  syntax: "", description: "Paste clipboard entities at original coordinates"),
        CommandDescriptor(canonicalName: "PASTEBLOCK", aliases: [],                category: .modify,  syntax: "", description: "Paste clipboard entities as a new block"),
        CommandDescriptor(canonicalName: "CLEANSPECKLES", aliases: ["CS", "SPECKLES"], category: .modify, syntax: "", description: "Remove tiny/speckle entities from the drawing"),
        CommandDescriptor(canonicalName: "DDEDIT",     aliases: ["ED"],            category: .modify,  syntax: "", description: "Edit the selected text entity"),
        CommandDescriptor(canonicalName: "JOIN",       aliases: ["J"],             category: .modify,  syntax: "", description: "Join selected line entities into polylines"),
        CommandDescriptor(canonicalName: "TRIM",       aliases: ["TR"],            category: .modify,  syntax: "", description: "Trim lines at intersections — click the side to remove"),
        CommandDescriptor(canonicalName: "FILLET",     aliases: ["F"],            category: .modify,  syntax: "", description: "Round corners between objects using an exact tangent arc"),
        CommandDescriptor(canonicalName: "CHAMFER",    aliases: ["CHA", "BEVEL"], category: .modify,  syntax: "", description: "Bevel corners using distances or a distance and angle"),
        CommandDescriptor(canonicalName: "MATCHPROP",   aliases: ["MA", "MATCH"],  category: .modify,  syntax: "", description: "Copy properties from one entity to others"),
        CommandDescriptor(canonicalName: "TORIENT",    aliases: ["TO", "TEXTO"], category: .modify, syntax: "", description: "Rotate text individually to an absolute or most-readable angle"),
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
        CommandDescriptor(canonicalName: "PAN",        aliases: ["P"],             category: .view,    syntax: "", description: "Pan the view by clicking and dragging"),
        CommandDescriptor(canonicalName: "-PAN",       aliases: [],                category: .view,    syntax: "", description: "Pan the view by specifying a displacement vector"),
        CommandDescriptor(canonicalName: "PLAN",       aliases: [],                category: .view,    syntax: "", description: "Reset view rotation to standard orientation"),
        CommandDescriptor(canonicalName: "DVIEW",      aliases: ["DV"],            category: .view,    syntax: "", description: "Dynamic view: twist the 2D view angle"),
        CommandDescriptor(canonicalName: "SNAPANG",    aliases: [],                category: .settings, syntax: "<degrees>", description: "Set the crosshair and ortho rotation angle"),
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
        CommandDescriptor(canonicalName: "STYLE",      aliases: ["ST"], category: .settings, syntax: "", description: "Create and edit text styles"),
        CommandDescriptor(canonicalName: "THEME",      aliases: ["DARKMODE", "LIGHTMODE"], category: .settings, syntax: "[DARK|LIGHT]", description: "Toggle or set the UI theme (dark/light mode)"),
        CommandDescriptor(canonicalName: "FPS",        aliases: [],                        category: .settings, syntax: "", description: "Toggle FPS counter in the title bar"),
        CommandDescriptor(canonicalName: "SET-BACKGROUND", aliases: ["SETBG", "BACKGROUND"], category: .settings, syntax: "<index|hex>", description: "Set viewport background color (ACI index 1-255 or hex RRGGBB)"),
        CommandDescriptor(canonicalName: "GRID",            aliases: [],                category: .settings, syntax: "", description: "Toggle the background grid on/off"),
        CommandDescriptor(canonicalName: "GRID SNAP",       aliases: [],                category: .settings, syntax: "", description: "Toggle snapping to grid intersections on/off"),
        CommandDescriptor(canonicalName: "GRID SPACING",    aliases: [],                category: .settings, syntax: "<value>", description: "Set the base grid spacing in world units"),
        CommandDescriptor(canonicalName: "GRID ORIGIN",     aliases: [],                category: .settings, syntax: "<x> <y>", description: "Set the grid origin in world coordinates"),
        CommandDescriptor(canonicalName: "SPLINETESS",  aliases: ["SPLINESEGS"],   category: .settings, syntax: "[value]", description: "Set or show spline tessellation quality divisor (lower = smoother, default 5000)"),
        CommandDescriptor(canonicalName: "SIMPLIFY",        aliases: ["SIMP", "COMPLEX", "COMPLEXBLOCKS"], category: .settings, syntax: "[ON|OFF]", description: "Toggle or set the simplification of complex block references to bounding boxes on/off"),
        CommandDescriptor(canonicalName: "SIMPLIFYPOLY",    aliases: ["SIMPPOLY", "COMPLEXPOLY", "SIMPLIFYPOLYLINES"], category: .settings, syntax: "[ON|OFF]", description: "Toggle or set the simplification of dense polylines on/off"),
        // --- Snap Toggles ---
        CommandDescriptor(canonicalName: "POLAR",           aliases: [],                category: .settings, syntax: "", description: "Toggle polar tracking on/off"),
        CommandDescriptor(canonicalName: "POLARANG",        aliases: [],                category: .settings, syntax: "<degrees>", description: "Set polar angle increment (e.g. 15, 30, 45, 90)"),
        CommandDescriptor(canonicalName: "OTRACK",          aliases: [],                category: .settings, syntax: "", description: "Toggle object snap tracking on/off"),
        CommandDescriptor(canonicalName: "EXTENSION",       aliases: ["EXT"],           category: .settings, syntax: "", description: "Toggle extension snapping on/off"),
        CommandDescriptor(canonicalName: "ORTHO",          aliases: [],                category: .settings, syntax: "", description: "Toggle ortho mode (F8) — constrain cursor to cardinal axes"),
        CommandDescriptor(canonicalName: "UNITS",          aliases: ["UNIT", "DDUNITS"], category: .settings, syntax: "[mm|cm|m|in|ft|yd]", description: "Set or display the drawing base unit"),
        CommandDescriptor(canonicalName: "SETUISCALE",     aliases: ["ZOOMUI", "UISCALE"], category: .settings, syntax: "[scale|AUTO]", description: "Override UI zoom (1.0=100%, 1.5=150%, AUTO=system DPI)"),
        CommandDescriptor(canonicalName: "LANGUAGE",       aliases: ["LANG", "UILANGUAGE", "FONTLANG"], category: .settings, syntax: "<profile>", description: "Set the UI font glyph profile without translating UI text"),

        // --- System ---
        CommandDescriptor(canonicalName: "INSTALLODA",  aliases: ["ODAINSTALL"],   category: .settings, syntax: "", description: "Download and install ODA FileConverter for DWG support"),
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

    /// Internal clipboard for CAD entity copy/paste (COPYCLIP, COPYBASE, PASTECLIP, etc.).
    public var clipboard = CADClipboard()

    // MARK: Move Ghost Preview State
    /// World-space mouse position during MOVE command (for ghost preview).
    public internal(set) var _moveGhostWorldX: Double = 0
    public internal(set) var _moveGhostWorldY: Double = 0
    private var _moveCursorWorldX: Double = 0
    private var _moveCursorWorldY: Double = 0

    // MARK: Direct Distance Entry State
    /// Buffer accumulating digit keystrokes during MOVE for direct distance entry.
    /// When non-empty, the renderer displays the value near the cursor and
    /// Enter applies the distance without opening the command line.
    public var pendingDistanceBuffer: String = "" {
        didSet {
            if activeCommand == "MOVE", commandRefPoint != nil {
                updateMoveGhostPreview()
            }
        }
    }

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

        // Direct distance entry: during MOVE (after base point), a number = distance along current direction.
        if let engine = engine,
           activeCommand == "MOVE",
           commandRefPoint != nil,
           let distance = Double(upper),
           distance != 0 {
            updateMoveGhostPreview(directDistanceOverride: distance)
            let (refX, refY) = commandRefPoint!
            let offsetX = _moveGhostWorldX - refX
            let offsetY = _moveGhostWorldY - refY
            let dist = sqrt(offsetX * offsetX + offsetY * offsetY)
            let ux = dist > 1e-9 ? offsetX / dist : 1.0
            let uy = dist > 1e-9 ? offsetY / dist : 0.0
            print("[CAD] MOVE direct distance: \(distance) units along (\(String(format: "%.4f", ux)), \(String(format: "%.4f", uy)))")
            engine.cadBridge.movePrimitivesDirect(
                handles: engine.cadSelection.selectedHandles,
                by: (offsetX, offsetY), in: engine.geometryManager,
                spriteManager: engine.spriteManager)
            engine.cadSelection.moveAllSelected(by: Vector3(x: offsetX, y: offsetY, z: 0), document: engine.document)
            engine.interaction.cachedGripGeneration = -1
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
        case "CLOSEALL":
            guard let engine = engine else { clearCommand(); return }
            // Create a fresh blank tab first, then close all others.
            // This avoids the "can't close last tab" restriction.
            engine.tabManager.newTab()
            engine.zoomExtents()
            let keepIndex = engine.tabManager.activeIndex
            var idx = engine.tabManager.tabs.count - 1
            while idx >= 0 {
                if idx != keepIndex {
                    _ = engine.tabManager.closeTab(at: idx)
                }
                idx -= 1
            }
            clearCommand()
        case "CLOSEALLOTHERS":
            guard let engine = engine else { clearCommand(); return }
            let activeIdx = engine.tabManager.activeIndex
            // Close all tabs except the active one (iterate from end to avoid index shifts)
            var idx = engine.tabManager.tabs.count - 1
            while idx >= 0 {
                if idx != activeIdx {
                    _ = engine.tabManager.closeTab(at: idx)
                }
                idx -= 1
            }
            clearCommand()
        case "SAVE", "QSAVE": 
            guard let eng = engine else { clearCommand(); return }
            do {
                try eng.tabManager.saveActiveTab()
            } catch TabManager.TabError.noFileURL {
                eng.saveFileBrowser.openSave(
                    filterExtension: "dxf;dwg;eab;pdf",
                    defaultName: eng.tabManager.activeTab?.displayName ?? "untitled",
                    defaultDXFVersion: eng.tabManager.activeTab?.dxfVersion ?? .defaultExport)
            } catch {
                print("Save failed: \(error)")
            }
            clearCommand()
        case "SAVEAS":
            engine?.saveFileBrowser.openSave(
                filterExtension: "dxf;dwg;eab;pdf",
                defaultName: engine?.tabManager.activeTab?.displayName ?? "untitled",
                defaultDXFVersion: engine?.tabManager.activeTab?.dxfVersion ?? .defaultExport)
            clearCommand()
        case "PDFEXPORT", "EXPORTPDF":
            engine?.saveFileBrowser.openSave(
                filterExtension: "pdf",
                defaultName: (engine?.tabManager.activeTab?.displayName ?? "untitled")
                    .replacingOccurrences(of: ".dxf", with: "")
                    .replacingOccurrences(of: ".dwg", with: "")
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
        case "AL", "ALIGN":
            guard let engine = engine else { clearCommand(); return }
            let cmd = AlignCommand()
            activeFeatureCommand = cmd
            cmd.start(engine: engine, processor: self)
        case "E", "ERASE":
            engine?.deleteSelected()

        // --- Copy / Paste (Modify) ---
        case "COPYCLIP":
            guard let engine = engine else { clearCommand(); return }
            guard engine.cadSelection.hasSelection else {
                print("[CAD] COPYCLIP requires entities to be selected.")
                clearCommand()
                break
            }
            captureToClipboard(engine: engine)
            print("[CAD] Copied \(engine.cadSelection.selectedHandles.count) entities to clipboard.")
            clearCommand()

        case "COPYBASE":
            guard let engine = engine else { clearCommand(); return }
            guard engine.cadSelection.hasSelection else {
                print("[CAD] COPYBASE requires entities to be selected.")
                clearCommand()
                break
            }
            startCommand("COPYBASE", prompt: "Specify base point")

        case "COPY", "CO", "CP":
            guard let engine = engine else { clearCommand(); return }
            guard engine.cadSelection.hasSelection else {
                print("[CAD] COPY requires entities to be selected.")
                clearCommand()
                break
            }
            // Duplicate selected entities in-place
            let result = engine.document.duplicateEntities(
                handles: engine.cadSelection.selectedHandles)
            // Add new blocks (create copies of originals with remapped UUIDs)
            for (origBlockID, newBlockID) in result.blockRemap {
                if let origBlock = engine.document.block(for: origBlockID) {
                    let newBlock = CADBlock(
                        handle: newBlockID,
                        name: origBlock.name,
                        geometry: origBlock.geometry)
                    engine.document.addBlock(newBlock)
                }
            }
            // Add new entities
            var newHandles = Set<UUID>()
            for entity in result.entities {
                engine.document.addEntity(entity)
                newHandles.insert(entity.handle)
            }
            // Select the new entities and start MOVE to reposition them
            engine.cadSelection.clearSelection()
            for h in newHandles {
                engine.cadSelection.addToSelection(h)
            }
            startCommand("MOVE", prompt: "Select base point")
            print("[CAD] Copied \(newHandles.count) entities. Specify destination.")

        case "PASTECLIP":
            guard let engine = engine else { clearCommand(); return }
            guard let entry = clipboard.entry else {
                print("[CAD] Clipboard is empty. Use COPYCLIP or COPYBASE first.")
                clearCommand()
                break
            }
            pasteFromClipboard(engine: engine, at: .center, basePoint: entry.basePoint)
            clearCommand()

        case "PASTEORIG":
            guard let engine = engine else { clearCommand(); return }
            guard clipboard.entry != nil else {
                print("[CAD] Clipboard is empty. Use COPYCLIP or COPYBASE first.")
                clearCommand()
                break
            }
            pasteFromClipboard(engine: engine, at: .original, basePoint: nil)
            clearCommand()

        case "PASTEBLOCK":
            guard let engine = engine else { clearCommand(); return }
            guard clipboard.entry != nil else {
                print("[CAD] Clipboard is empty. Use COPYCLIP or COPYBASE first.")
                clearCommand()
                break
            }
            pasteFromClipboardAsBlock(engine: engine)
            clearCommand()

        case "SELALL", "SELECTALL":
            engine?.selectAll()
        case "PAN", "P":
            guard let engine = engine else { clearCommand(); return }
            let cmd = PanCommand()
            activeFeatureCommand = cmd
            cmd.start(engine: engine, processor: self)

        case "-PAN":
            guard engine != nil else { clearCommand(); return }
            startCommand("-PAN", prompt: "Specify base point")

        case "PLAN":
            guard let engine = engine else { clearCommand(); return }
            engine.camera.rotation = 0
            engine.zoomExtents()
            print("[CAD] View reset to PLAN (standard orientation).")
            clearCommand()

        case "DVIEW", "DV":
            guard let engine = engine else { clearCommand(); return }
            let cmd = DViewCommand()
            activeFeatureCommand = cmd
            cmd.start(engine: engine, processor: self)

        case _ where upper.hasPrefix("SNAPANG "):
            guard let engine = engine else { clearCommand(); return }
            let arg = String(text.dropFirst(8)).trimmingCharacters(in: .whitespaces)
            guard let val = Double(arg) else {
                print("[CAD] SNAPANG requires an angle in degrees (e.g. SNAPANG 45)")
                clearCommand()
                break
            }
            var normalizedAngle = val.truncatingRemainder(dividingBy: 360.0)
            if normalizedAngle < 0 { normalizedAngle += 360.0 }
            engine.snap.snapAngle = normalizedAngle
            engine.snap.orthoLastWasHorizontal = false
            engine.snap.orthoLastWasVertical = false
            print("[CAD] Snap angle set to \(engine.snap.snapAngle)°")
            clearCommand()

        case "SNAPANG":
            guard let engine = engine else { clearCommand(); return }
            print("[CAD] Current snap angle: \(engine.snap.snapAngle)°")
            print("[CAD] Usage: SNAPANG <degrees>")
            clearCommand()

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
                    engine.ui.blockClosePending = true
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
        case "LANGUAGE", "LANG", "UILANGUAGE", "FONTLANG":
            if let engine = engine {
                let profiles = UIFontLanguageProfile.allCases.map(\.rawValue).joined(separator: ", ")
                print("[CAD] UI font language profile: \(engine.uiFontLanguageProfile.rawValue)")
                print("[CAD] Available profiles: \(profiles)")
            }
            clearCommand()
        case _ where upper.hasPrefix("LANGUAGE ")
            || upper.hasPrefix("LANG ")
            || upper.hasPrefix("UILANGUAGE ")
            || upper.hasPrefix("FONTLANG "):
            guard let engine = engine else { clearCommand(); return }
            let argument = upper.split(separator: " ", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
            guard let profile = UIFontLanguageProfile.parse(argument) else {
                let profiles = UIFontLanguageProfile.allCases.map(\.rawValue).joined(separator: "|")
                print("[CAD] Usage: LANGUAGE <\(profiles)>")
                clearCommand()
                return
            }

            if engine.applyUIFontLanguageProfile(profile) {
                print("[CAD] UI font language profile changed to \(profile.rawValue).")
            } else {
                print("[CAD] UI font language profile is already \(profile.rawValue).")
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
        // --- Grip Settings ---
        case "SETTINGSGRIPOBJECTMAX", "GRIPOBJECTMAX", "GRIPOBJLIMIT":
            guard let engine = engine else { clearCommand(); return }
            print("[CAD] Grip object max: \(engine.gripObjectMax) (entities)")
            clearCommand()
        case _ where upper.hasPrefix("SETTINGSGRIPOBJECTMAX ") || upper.hasPrefix("GRIPOBJECTMAX ") || upper.hasPrefix("GRIPOBJLIMIT "):
            guard let engine = engine else { clearCommand(); return }
            let prefixLen: Int
            if upper.hasPrefix("SETTINGSGRIPOBJECTMAX ") { prefixLen = 22 }
            else if upper.hasPrefix("GRIPOBJECTMAX ") { prefixLen = 14 }
            else { prefixLen = 13 } // "GRIPOBJLIMIT "
            let arg = String(text.dropFirst(prefixLen)).trimmingCharacters(in: .whitespaces)
            guard let val = Int(arg), val >= 1 else {
                print("[CAD] SETTINGSGRIPOBJECTMAX requires a positive integer.")
                clearCommand()
                return
            }
            engine.gripObjectMax = val
            print("[CAD] Grip object max set to \(val) (grips suppressed when selection exceeds \(val))")
            // Invalidate cached grips so the new limit takes effect immediately.
            engine.interaction.cachedGripGeneration = -1
            clearCommand()
        case "SETTINGSGRIPMAX", "GRIPMAX":
            guard let engine = engine else { clearCommand(); return }
            print("[CAD] Grip max: \(engine.gripMax) (total grip squares drawn)")
            clearCommand()
        case _ where upper.hasPrefix("SETTINGSGRIPMAX ") || upper.hasPrefix("GRIPMAX "):
            guard let engine = engine else { clearCommand(); return }
            let prefixLen = upper.hasPrefix("SETTINGSGRIPMAX ") ? 16 : 8
            let arg = String(text.dropFirst(prefixLen)).trimmingCharacters(in: .whitespaces)
            guard let val = Int(arg), val >= 1 else {
                print("[CAD] SETTINGSGRIPMAX requires a positive integer.")
                clearCommand()
                return
            }
            engine.gripMax = val
            print("[CAD] Grip max set to \(val) (total grip squares drawn)")
            engine.interaction.cachedGripGeneration = -1
            clearCommand()
        // --- Spline Tessellation ---
        case "SPLINETESS", "SPLINESEGS":
            guard let engine = engine else { clearCommand(); return }
            print("[CAD] Spline tessellation divisor: \(engine.splineTessellationDivisor) (lower = smoother, default 5000)")
            clearCommand()
        case _ where upper.hasPrefix("SPLINETESS ") || upper.hasPrefix("SPLINESEGS "):
            guard let engine = engine else { clearCommand(); return }
            let prefixLen = upper.hasPrefix("SPLINETESS ") ? 12 : 11  // "SPLINESEGS "
            let arg = String(text.dropFirst(prefixLen)).trimmingCharacters(in: .whitespaces)
            guard let val = Double(arg), val >= 10 else {
                print("[CAD] SPLINETESS requires a positive number >= 10 (e.g. SPLINETESS 5000)")
                clearCommand()
                return
            }
            engine.splineTessellationDivisor = val
            engine._regenerationGeneration &+= 1
            print("[CAD] Spline tessellation divisor set to \(val)")
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
        case "ORTHO":
            guard let engine = engine else { clearCommand(); return }
            engine.snap.orthoEnabled.toggle()
            print("[CAD] Ortho: \(engine.snap.orthoEnabled ? "ON" : "OFF")")
            clearCommand()
        // --- Drawing Units ---
        case "UNITS", "UNIT", "DDUNITS":
            guard let engine = engine else { clearCommand(); return }
            let unitLabel = switch engine.document.unit {
            case .millimeter: "millimeters"
            case .centimeter: "centimeters"
            case .meter: "meters"
            case .inch: "inches"
            case .foot: "feet"
            case .yard: "yards"
            }
            print("[CAD] Current drawing unit: \(engine.document.unit.description) (\(unitLabel))")
            print("[CAD] Available units: mm, cm, m, in, ft, yd")
            print("[CAD] Usage: UNITS <unit>")
            clearCommand()
        // --- UI Scale ---
        case "SETUISCALE", "ZOOMUI", "UISCALE":
            guard let engine = engine else { clearCommand(); return }
            if let override = engine.uiScaleOverride {
                print("[CAD] Current UI scale: \(String(format: "%.1f", override))x (override)")
            } else {
                print("[CAD] Current UI scale: \(String(format: "%.1f", engine.currentUiScale))x (auto — system DPI)")
            }
            print("[CAD] Usage: SETUISCALE <scale|AUTO> — e.g. SETUISCALE 1.5, SETUISCALE AUTO")
            clearCommand()
        case _ where upper.hasPrefix("SETUISCALE ") || upper.hasPrefix("ZOOMUI ") || upper.hasPrefix("UISCALE "):
            guard let engine = engine else { clearCommand(); return }
            let prefixLen: Int
            if upper.hasPrefix("SETUISCALE ") { prefixLen = 11 }
            else if upper.hasPrefix("ZOOMUI ") { prefixLen = 7 }
            else { prefixLen = 8 }  // "UISCALE "
            let arg = String(upper.dropFirst(prefixLen)).trimmingCharacters(in: .whitespaces)
            if arg == "AUTO" || arg == "0" || arg == "RESET" {
                engine.applyUiScaleOverride(nil)
                print("[CAD] UI scale reset to auto (system DPI): \(String(format: "%.1f", engine.currentUiScale))x")
            } else if let scale = Float(arg), scale >= 0.5, scale <= 4.0 {
                engine.applyUiScaleOverride(scale)
                print("[CAD] UI scale set to \(String(format: "%.1f", scale))x (override)")
            } else {
                print("[CAD] Invalid scale '\(arg)'. Use a number from 0.5 to 4.0, or AUTO to reset.")
            }
            clearCommand()
        case _ where upper.hasPrefix("UNITS ") || upper.hasPrefix("UNIT ") || upper.hasPrefix("DDUNITS "):
            guard let engine = engine else { clearCommand(); return }
            let prefixLen: Int
            if upper.hasPrefix("UNITS ") { prefixLen = 6 }
            else if upper.hasPrefix("DDUNITS ") { prefixLen = 8 }
            else { prefixLen = 5 }  // "UNIT "
            let arg = String(upper.dropFirst(prefixLen)).trimmingCharacters(in: .whitespaces)
            guard let unit = parseUnit(arg) else {
                print("[CAD] Unknown unit '\(arg)'. Available: mm, cm, m, in, ft, yd")
                clearCommand()
                break
            }
            if engine.document.unit != unit {
                engine.document.unit = unit
                engine.document.markEdited(regenerate: false)
                print("[CAD] Drawing unit set to \(unit.description) (\(arg))")
            } else {
                print("[CAD] Drawing unit is already \(unit.description)")
            }
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

    /// Parse a unit string (case-insensitive) to a CADUnit, or nil if unrecognized.
    private func parseUnit(_ raw: String) -> CADUnit? {
        switch raw {
        case "MM", "MILLIMETER", "MILLIMETERS", "MILLIMETRE", "MILLIMETRES":
            return .millimeter
        case "CM", "CENTIMETER", "CENTIMETERS", "CENTIMETRE", "CENTIMETRES":
            return .centimeter
        case "M", "METER", "METERS", "METRE", "METRES":
            return .meter
        case "IN", "INCH", "INCHES":
            return .inch
        case "FT", "FOOT", "FEET":
            return .foot
        case "YD", "YARD", "YARDS":
            return .yard
        default:
            return nil
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
        pendingDistanceBuffer = ""
        commandSelectionIndex = 0
        _lastMatchInput = ""
        _cachedMatches = []
        _moveGhostWorldX = 0
        _moveGhostWorldY = 0
        _moveCursorWorldX = 0
        _moveCursorWorldY = 0
    }

    // MARK: - Command Helpers

    private func startCommand(_ name: String, prompt: String) {
        activeCommand = name
        commandPrompt = prompt
        commandRefPoint = nil
        commandLineActive = false
        commandBuffer = ""
        pendingDistanceBuffer = ""
        commandSelectionIndex = 0
        _lastMatchInput = ""
        _cachedMatches = []
        _moveGhostWorldX = 0
        _moveGhostWorldY = 0
        _moveCursorWorldX = 0
        _moveCursorWorldY = 0
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
        case "-PAN":
            if commandRefPoint == nil {
                commandRefPoint = (worldX, worldY)
                commandPrompt = "Specify destination point"
            } else {
                let dx = worldX - commandRefPoint!.0
                let dy = worldY - commandRefPoint!.1
                engine.camera.offset.x -= dx
                engine.camera.offset.y -= dy
                clearCommand()
            }

        case "COPYBASE":
            guard engine.cadSelection.hasSelection else {
                clearCommand()
                return
            }
            captureToClipboard(engine: engine, basePoint: Vector3(x: worldX, y: worldY, z: 0))
            print("[CAD] Copied \(engine.cadSelection.selectedHandles.count) entities to clipboard with base point.")
            clearCommand()

        case "MOVE":
            guard engine.cadSelection.hasSelection else {
                clearCommand()
                return
            }
            if commandRefPoint == nil {
                commandRefPoint = (worldX, worldY)
                _moveCursorWorldX = worldX
                _moveCursorWorldY = worldY
                _moveGhostWorldX = worldX
                _moveGhostWorldY = worldY
                commandPrompt = "Select destination point"
            } else {
                updateMoveGhostPreview(cursorWorldX: worldX, cursorWorldY: worldY)
                let dx = _moveGhostWorldX - commandRefPoint!.0
                let dy = _moveGhostWorldY - commandRefPoint!.1
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

        if activeCommand == "MOVE" && commandRefPoint != nil {
            updateMoveGhostPreview(cursorWorldX: worldX, cursorWorldY: worldY)
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

    private func updateMoveGhostPreview(
        cursorWorldX: Double? = nil,
        cursorWorldY: Double? = nil,
        directDistanceOverride: Double? = nil
    ) {
        guard activeCommand == "MOVE", let base = commandRefPoint else { return }

        if let cursorWorldX {
            _moveCursorWorldX = cursorWorldX
        }
        if let cursorWorldY {
            _moveCursorWorldY = cursorWorldY
        }

        var targetX = _moveCursorWorldX
        var targetY = _moveCursorWorldY

        if let engine = engine,
           !engine.snap.orthoEnabled {
            if let snap = engine.snap.currentSnapResult,
               snap.entityHandle != PhrostEngine.drawingSnapSentinel {
                targetX = snap.worldPos.x
                targetY = snap.worldPos.y
            } else if let polar = engine.snap.lastPolarResult {
                targetX = polar.worldPos.x
                targetY = polar.worldPos.y
            }
        }

        var dx = targetX - base.0
        var dy = targetY - base.1

        if engine?.snap.orthoEnabled == true {
            let absDx = abs(dx)
            let absDy = abs(dy)
            if absDx < 1e-9 && absDy < 1e-9 {
                dx = 1.0
                dy = 0.0
            } else if absDx >= absDy {
                dx = dx >= 0 ? absDx : -absDx
                dy = 0.0
                engine?.snap.orthoLastWasHorizontal = true
                engine?.snap.orthoLastWasVertical = false
            } else {
                dx = 0.0
                dy = dy >= 0 ? absDy : -absDy
                engine?.snap.orthoLastWasHorizontal = false
                engine?.snap.orthoLastWasVertical = true
            }
        }

        let directDistance = directDistanceOverride ?? Double(pendingDistanceBuffer)
        if let directDistance {
            let length = sqrt(dx * dx + dy * dy)
            let ux = length > 1e-9 ? dx / length : 1.0
            let uy = length > 1e-9 ? dy / length : 0.0
            dx = ux * directDistance
            dy = uy * directDistance
        }

        _moveGhostWorldX = base.0 + dx
        _moveGhostWorldY = base.1 + dy
    }

    // MARK: - Clipboard Helpers

    /// Paste location mode.
    private enum PasteLocation {
        /// Place at viewport center (PASTECLIP).
        case center
        /// Place at original world coordinates (PASTEORIG).
        case original
    }

    /// Capture selected entities plus their block definitions into the internal clipboard.
    private func captureToClipboard(engine: PhrostEngine, basePoint: Vector3? = nil) {
        let handles = engine.cadSelection.selectedHandles
        var entities: [CADEntity] = []
        var blocks: [UUID: CADBlock] = [:]

        for handle in handles {
            guard let entity = engine.document.entity(for: handle) else { continue }
            entities.append(entity)

            // Collect referenced block definitions
            if let bid = entity.blockID, let block = engine.document.block(for: bid) {
                blocks[bid] = block
            }
        }

        clipboard.entry = CADClipboardEntry(
            entities: entities,
            blocks: blocks,
            basePoint: basePoint
        )
    }

    /// Paste clipboard entities into the current document.
    private func pasteFromClipboard(
        engine: PhrostEngine,
        at location: PasteLocation,
        basePoint: Vector3?
    ) {
        guard let entry = clipboard.entry else { return }

        // Determine the offset: for PASTECLIP, offset so the content lands at viewport center.
        // For PASTEORIG, no offset (entities keep original world coords).
        let offset: Vector3
        if location == .center {
            let vp = engine.camera.worldViewportRect(
                windowWidth: engine.windowWidth,
                windowHeight: engine.windowHeight)
            let viewCenter = Vector3(
                x: (vp.minX + vp.maxX) / 2,
                y: (vp.minY + vp.maxY) / 2,
                z: 0)
            let contentCenter: Vector3
            if let bp = basePoint {
                contentCenter = bp
            } else {
                // Compute bounding center of clipboard entities
                var minX = Double.infinity, minY = Double.infinity
                var maxX = -Double.infinity, maxY = -Double.infinity
                for entity in entry.entities {
                    if let bb = entity.worldBoundingBox {
                        minX = min(minX, bb.min.x)
                        minY = min(minY, bb.min.y)
                        maxX = max(maxX, bb.max.x)
                        maxY = max(maxY, bb.max.y)
                    }
                }
                if minX.isFinite {
                    contentCenter = Vector3(x: (minX + maxX) / 2, y: (minY + maxY) / 2, z: 0)
                } else {
                    contentCenter = .zero
                }
            }
            offset = Vector3(
                x: viewCenter.x - contentCenter.x,
                y: viewCenter.y - contentCenter.y,
                z: 0)
        } else {
            offset = .zero
        }

        // Add blocks first (deduplicated by UUID)
        for (_, block) in entry.blocks {
            if engine.document.block(for: block.handle) == nil {
                engine.document.addBlock(block)
            }
        }

        // Duplicate entities with offset (generate new UUIDs for each pasted entity)
        // We directly create copies from clipboard entries (not from document)
        var newHandles = Set<UUID>()
        for entity in entry.entities {
            var e = entity
            // Generate new handle
            e = CADEntity(
                handle: UUID(),
                layerID: entity.layerID,
                blockID: entity.blockID,
                localGeometry: entity.localGeometry,
                transform: entity.transform,
                xdata: entity.xdata,
                drawOrder: entity.drawOrder
            )
            // Apply offset
            var t = e.transform
            t.position = Vector3(
                x: t.position.x + offset.x,
                y: t.position.y + offset.y,
                z: t.position.z + offset.z
            )
            e.transform = t
            engine.document.addEntity(e)
            newHandles.insert(e.handle)
        }

        // Select the new entities
        engine.cadSelection.clearSelection()
        for h in newHandles {
            engine.cadSelection.addToSelection(h)
        }

        let mode = location == .original ? "at original coordinates" : "from clipboard"
        print("[CAD] Pasted \(newHandles.count) entities \(mode).")
    }

    /// Paste clipboard entities as a new block reference at viewport center.
    private func pasteFromClipboardAsBlock(engine: PhrostEngine) {
        guard let entry = clipboard.entry else { return }

        // Collect world-space geometry from clipboard entities
        var worldGeom: [CADPrimitive] = []
        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity

        for entity in entry.entities {
            if let bb = entity.worldBoundingBox {
                minX = min(minX, bb.min.x)
                minY = min(minY, bb.min.y)
                maxX = max(maxX, bb.max.x)
                maxY = max(maxY, bb.max.y)
            }

            let prims: [CADPrimitive]
            if let bid = entity.blockID, let block = entry.blocks[bid] {
                prims = block.geometry
            } else if let local = entity.localGeometry {
                prims = local
            } else {
                continue
            }
            let transformed = CADGeometryMath.transformPrimitives(prims, by: entity.transform)
            worldGeom.append(contentsOf: transformed)
        }

        guard !worldGeom.isEmpty else {
            print("[CAD] PASTEBLOCK: no geometry on clipboard.")
            return
        }

        // Compute center of clipboard content
        let contentCenter = Vector3(
            x: minX.isFinite ? (minX + maxX) / 2 : 0,
            y: minY.isFinite ? (minY + maxY) / 2 : 0,
            z: 0)

        // Transform to block-local space (relative to content center)
        let invTransform = Transform3D.translated(
            by: Vector3(x: -contentCenter.x, y: -contentCenter.y, z: -contentCenter.z))
        let localGeom = CADGeometryMath.transformPrimitives(worldGeom, by: invTransform)

        // Create block definition with a unique name
        var blockName = "PasteBlock"
        var suffix = 1
        let existingNames = Set(engine.document.allBlocks.map { $0.name })
        while existingNames.contains(blockName) {
            suffix += 1
            blockName = "PasteBlock_\(suffix)"
            if suffix > 999 { break }
        }
        var block = CADBlock(name: blockName, geometry: localGeom)
        block.updateBoundingBox()
        engine.document.addBlock(block)

        // Determine insertion point: viewport center
        let vp = engine.camera.worldViewportRect(
            windowWidth: engine.windowWidth,
            windowHeight: engine.windowHeight)
        let viewCenter = Vector3(
            x: (vp.minX + vp.maxX) / 2,
            y: (vp.minY + vp.maxY) / 2,
            z: 0)

        // Create block instance
        let layerID = engine.document.activeLayerID
            ?? engine.document.allLayers.first?.handle
            ?? UUID()
        let instance = CADEntity(
            layerID: layerID,
            blockID: block.handle,
            localGeometry: nil,
            transform: Transform3D.translated(by: viewCenter)
        )
        engine.document.addEntity(instance)
        engine.cadSelection.select(instance.handle)

        print("[CAD] Pasted \(entry.entities.count) entities as block '\(blockName)'.")
    }
}
