import Foundation
import SwiftSDL
import ZephyrLisp

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
public struct FeatureCommandTextOption: Sendable, Hashable {
    public let value: String
    public let title: String
    public let aliases: [String]
    public let description: String

    public init(
        value: String,
        title: String,
        aliases: [String] = [],
        description: String = ""
    ) {
        self.value = value
        self.title = title
        self.aliases = aliases
        self.description = description
    }

    public func matches(_ input: String) -> Bool {
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return true }
        return title.lowercased().hasPrefix(query)
            || value.lowercased().hasPrefix(query)
            || aliases.contains { $0.lowercased().hasPrefix(query) }
    }
}

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

    /// Context-sensitive command-line options shown while this feature command
    /// owns the input field.
    func commandTextOptions(for input: String) -> [FeatureCommandTextOption]
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

    func commandTextOptions(for input: String) -> [FeatureCommandTextOption] { [] }
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
    case lisp    = "Lisp"
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
    /// Bare Enter executes the command even though `syntax` is non-empty:
    /// parameters are optional (LOAD/SCRIPT open a file picker instead).
    /// Without this, Enter on a parameterized command waits for arguments.
    public let bareEnterExecutes: Bool

    /// All strings that match this command (canonical name + all aliases).
    public var allMatches: [String] {
        [canonicalName] + aliases
    }

    public init(
        canonicalName: String,
        aliases: [String] = [],
        category: CommandCategory,
        syntax: String = "",
        description: String = "",
        bareEnterExecutes: Bool = false
    ) {
        self.canonicalName = canonicalName.uppercased()
        self.aliases = aliases.map { $0.uppercased() }
        self.category = category
        self.syntax = syntax
        self.description = description
        self.bareEnterExecutes = bareEnterExecutes
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
        CommandDescriptor(canonicalName: "DXFVERSION", aliases: ["DXFVER"],        category: .settings, syntax: "[2018|2013|2010|2007|2004|2000|R14|R13|R12|R10]", description: "Set the DXF version used by Save and Save As"),
        CommandDescriptor(canonicalName: "EXPORTPDF",  aliases: ["PDFEXPORT", "EPDF"], category: .draw, syntax: "", description: "Export the current drawing to a PDF file"),
        CommandDescriptor(canonicalName: "PDFIMPORT",  aliases: ["PDFI", "PDF"],   category: .draw,    syntax: "", description: "Import a PDF page as an image underlay"),
        CommandDescriptor(canonicalName: "TABLEFT",    aliases: ["TABL"],          category: .draw,    syntax: "", description: "Move the active drawing tab one position left"),
        CommandDescriptor(canonicalName: "TABRIGHT",   aliases: ["TABR"],          category: .draw,    syntax: "", description: "Move the active drawing tab one position right"),
        CommandDescriptor(canonicalName: "FILETAB",    aliases: [],                category: .draw,    syntax: "", description: "Show the file tabs at the top of the drawing area"),
        CommandDescriptor(canonicalName: "FILETABCLOSE", aliases: [],              category: .draw,    syntax: "", description: "Hide the file tabs at the top of the drawing area"),
        // --- Ribbon (AutoLISP-defined command chrome) ---
        CommandDescriptor(canonicalName: "RIBBON",      aliases: [],               category: .view,    syntax: "", description: "Show or hide the ribbon"),
        CommandDescriptor(canonicalName: "RIBBONCLOSE", aliases: [],               category: .view,    syntax: "", description: "Hide the ribbon"),
        CommandDescriptor(canonicalName: "RIBBONMODE",  aliases: [],               category: .view,    syntax: "[menu|labels|full]", description: "Switch the ribbon between the classic menu bar, labels, and icons + labels", bareEnterExecutes: true),
        CommandDescriptor(canonicalName: "RIBBONRELOAD", aliases: [],              category: .settings, syntax: "", description: "Re-read the AutoLISP ribbon definition (lisp/ribbon.lsp)"),
        CommandDescriptor(canonicalName: "TABWINDOW",  aliases: ["TABW", "FLOAT"], category: .draw,    syntax: "", description: "Move the active drawing tab into its own window"),
        CommandDescriptor(canonicalName: "TABDOCK",    aliases: ["TABD", "DOCK"],  category: .draw,    syntax: "", description: "Dock the active floating tab back into the main window"),
        CommandDescriptor(canonicalName: "VPORTS",     aliases: [],                category: .view,    syntax: "2V|2H|SINGLE|JOIN|TOGGLE|?", description: "Split the main view into tiled panes showing different tabs"),
        CommandDescriptor(canonicalName: "VSPLIT",     aliases: [],                category: .view,    syntax: "", description: "Split the focused pane side-by-side (VPORTS 2 Vertical)"),
        CommandDescriptor(canonicalName: "HSPLIT",     aliases: [],                category: .view,    syntax: "", description: "Split the focused pane stacked (VPORTS 2 Horizontal)"),
        CommandDescriptor(canonicalName: "UNSPLIT",    aliases: ["CLOSESPLIT"],    category: .view,    syntax: "", description: "Remove all splits, keeping the focused pane (VPORTS SINGLE)"),
        CommandDescriptor(canonicalName: "CLOSEPANE",  aliases: [],                category: .view,    syntax: "", description: "Close the focused pane (VPORTS JOIN)"),
        CommandDescriptor(canonicalName: "VPMAX",      aliases: [],                category: .view,    syntax: "", description: "Maximize the focused pane"),
        CommandDescriptor(canonicalName: "VPMIN",      aliases: [],                category: .view,    syntax: "", description: "Restore the split arrangement saved by VPMAX"),
        CommandDescriptor(canonicalName: "VPEQUAL",    aliases: ["EQUALIZE"],      category: .view,    syntax: "", description: "Resize all split panes to equal sizes"),
        CommandDescriptor(canonicalName: "VPRESIZE",   aliases: [],                category: .view,    syntax: "[+|-]percent", description: "Grow (+) or shrink (-) the focused pane by a percentage of its parent split", bareEnterExecutes: true),
        // --- Draw ---
        CommandDescriptor(canonicalName: "LINE",       aliases: ["L"],             category: .draw,    syntax: "", description: "Draw a line segment by picking two points"),
        CommandDescriptor(canonicalName: "PLINE",      aliases: ["POLYLINE", "PL"], category: .draw, syntax: "", description: "Draw a multi-segment polyline"),
        CommandDescriptor(canonicalName: "AREA",       aliases: ["AA"],            category: .draw,    syntax: "", description: "Calculate area and perimeter of closed regions"),
        CommandDescriptor(canonicalName: "DIST",       aliases: ["DI"],            category: .draw,    syntax: "", description: "Report distance, angles, and deltas between two points"),
        CommandDescriptor(canonicalName: "ID",         aliases: [],                category: .draw,    syntax: "", description: "Report the coordinates of a picked point"),
        CommandDescriptor(canonicalName: "LIST",       aliases: ["LI", "LS"],      category: .draw,    syntax: "", description: "List type, layer, and geometry of selected entities"),
        CommandDescriptor(canonicalName: "GRADIENT",   aliases: ["GD"],            category: .draw,    syntax: "", description: "Fill a closed boundary with a gradient"),
        CommandDescriptor(canonicalName: "CIRCLE",     aliases: ["C"],             category: .draw,    syntax: "", description: "Draw a circle by center and radius"),
        CommandDescriptor(canonicalName: "ARC",        aliases: ["A"],             category: .draw,    syntax: "", description: "Draw an arc by center, radius, and angles"),
        CommandDescriptor(canonicalName: "RECTANG",    aliases: ["RECTANGLE", "REC", "RECT"], category: .draw, syntax: "", description: "Draw a rectangle by two opposite corners"),
        CommandDescriptor(canonicalName: "ELLIPSE",    aliases: ["EL"],            category: .draw,    syntax: "", description: "Draw an ellipse by center and axes"),
        CommandDescriptor(canonicalName: "HATCH",      aliases: ["H", "BH"],       category: .draw,    syntax: "", description: "Fill a closed boundary with a hatch pattern"),
        CommandDescriptor(canonicalName: "HATCHEDIT",  aliases: ["HE"],            category: .draw,    syntax: "", description: "Edit the selected hatch"),
        CommandDescriptor(canonicalName: "-HATCH",     aliases: [],                category: .draw,    syntax: "[pattern] [scale] [angle]", description: "Fill a closed boundary from the command line"),
        CommandDescriptor(canonicalName: "-TEXT",      aliases: [],                category: .draw,    syntax: "", description: "Place single-line text from the command line"),
        CommandDescriptor(canonicalName: "SPLINE",     aliases: ["SPL"],           category: .draw,    syntax: "", description: "Draw a smooth spline curve through control points"),
        CommandDescriptor(canonicalName: "PENSTROKE",  aliases: ["PSTROKE"],      category: .draw,    syntax: "", description: "Draw with tablet pen capturing pressure and tilt per vertex"),
        CommandDescriptor(canonicalName: "RAY",        aliases: [],                category: .draw,    syntax: "", description: "Draw a ray from a start point in a direction"),
        CommandDescriptor(canonicalName: "XLINE",      aliases: ["XL"],            category: .draw,    syntax: "", description: "Draw an infinite construction line through a point"),
        CommandDescriptor(canonicalName: "POLYGON",    aliases: ["POL"],           category: .draw,    syntax: "[Inscribed/Circumscribed/Edge]", description: "Draw a regular polygon (sides, center, radius or edge)"),
        CommandDescriptor(canonicalName: "BOUNDARY",   aliases: ["BO"],            category: .draw,    syntax: "", description: "Create a closed region from an interior pick point"),
        CommandDescriptor(canonicalName: "DRAW",       aliases: ["TOOLS"],         category: .draw,    syntax: "", description: "Open the draw tools palette"),
        CommandDescriptor(canonicalName: "MTEXT",      aliases: ["MT", "T"],       category: .draw,    syntax: "", description: "Place multiline text"),
        CommandDescriptor(canonicalName: "TEXT",       aliases: ["DTEXT", "DT"],   category: .draw,    syntax: "", description: "Place single-line text"),
        CommandDescriptor(canonicalName: "LEADER",     aliases: ["LEAD"], category: .draw, syntax: "", description: "Create a classic leader with text or block content"),
        CommandDescriptor(canonicalName: "QLEADER",    aliases: ["LE"], category: .draw, syntax: "", description: "Create a prompted quick leader"),
        CommandDescriptor(canonicalName: "MLEADER",    aliases: ["MLD"], category: .draw, syntax: "", description: "Create an associative multileader"),
        CommandDescriptor(canonicalName: "MEASURE",    aliases: ["ME"], category: .draw, syntax: "", description: "Place points or blocks at measured intervals along an object"),
        CommandDescriptor(canonicalName: "TABLE",      aliases: ["TB", "DATATABLE"], category: .draw, syntax: "", description: "Insert a data table"),
        CommandDescriptor(canonicalName: "CLIP",       aliases: [], category: .modify, syntax: "", description: "Clip blocks, raster images, and PDF underlays"),
        CommandDescriptor(canonicalName: "DIVIDE",     aliases: ["DIV"], category: .draw, syntax: "", description: "Place points or blocks at equal divisions along an object"),
        CommandDescriptor(canonicalName: "MEASUREGEOM", aliases: ["MEASUREGEOMETRY", "MEA", "MG"], category: .draw, syntax: "", description: "Measure geometry: quick measure, distance, area, and angle"),
        CommandDescriptor(canonicalName: "DIMLINEAR",  aliases: ["DLI", "DIMLIN"], category: .draw, syntax: "", description: "Horizontal or vertical dimension between two points"),
        CommandDescriptor(canonicalName: "DIMALIGNED", aliases: ["DAL", "DIMALIGN"], category: .draw, syntax: "", description: "Dimension parallel to measured distance"),
        CommandDescriptor(canonicalName: "DIMRADIUS",  aliases: ["DRA", "DIMRAD"], category: .draw, syntax: "", description: "Radius dimension for arcs/circles"),
        CommandDescriptor(canonicalName: "DIMDIAMETER",aliases: ["DDI", "DIMDIA"], category: .draw, syntax: "", description: "Diameter dimension for arcs/circles"),
        CommandDescriptor(canonicalName: "DIMANGULAR", aliases: ["DAN", "DIMANG"], category: .draw, syntax: "", description: "Angle dimension between two lines or an arc"),
        CommandDescriptor(canonicalName: "DIMARC",     aliases: ["DAR", "DIMARCLENGTH"], category: .draw, syntax: "", description: "Arc length dimension along a curve"),
        CommandDescriptor(canonicalName: "DIMORDINATE",aliases: ["DOR", "DIMORD"], category: .draw, syntax: "", description: "X or Y ordinate dimension from origin"),
        CommandDescriptor(canonicalName: "DIMJOGGED",  aliases: ["DJO", "DIMJOG", "JOG"], category: .draw, syntax: "", description: "Jogged radius dimension for large radii"),
        CommandDescriptor(canonicalName: "CENTERLINE", aliases: ["CL"], category: .draw, syntax: "", description: "Draw a centerline between two lines"),
        // --- History ---
        CommandDescriptor(canonicalName: "UNDO",       aliases: ["U"],             category: .modify,  syntax: "[<count>]", description: "Undo the last drawing change (Cmd/Ctrl+Z)", bareEnterExecutes: true),
        CommandDescriptor(canonicalName: "REDO",       aliases: [],                category: .modify,  syntax: "[<count>]", description: "Re-apply the last undone change (Cmd/Ctrl+Y)", bareEnterExecutes: true),
        // --- Modify ---
        CommandDescriptor(canonicalName: "MOVE",       aliases: ["M"],             category: .modify,  syntax: "", description: "Move selected entities by picking two points"),
        CommandDescriptor(canonicalName: "ROTATE",     aliases: ["RO"],            category: .modify,  syntax: "", description: "Rotate selected entities around their collective center"),
        CommandDescriptor(canonicalName: "SCALE",      aliases: ["SC"],            category: .modify,  syntax: "", description: "Scale selected entities around their collective center"),
        CommandDescriptor(canonicalName: "STRETCH",    aliases: ["S"],             category: .modify,  syntax: "", description: "Stretch vertices inside a crossing window"),
        CommandDescriptor(canonicalName: "ALIGN",      aliases: ["AL"],             category: .modify,  syntax: "", description: "Align objects by matching two pairs of points (move, rotate, optionally scale)"),
        CommandDescriptor(canonicalName: "ERASE",      aliases: ["E"],             category: .modify,  syntax: "", description: "Delete all currently selected entities"),
        CommandDescriptor(canonicalName: "COPY",       aliases: ["CO", "CP"],      category: .modify,  syntax: "", description: "Duplicate selected entities within the drawing"),
        CommandDescriptor(canonicalName: "COPYCLIP",   aliases: [],                category: .modify,  syntax: "", description: "Copy selected entities to clipboard"),
        CommandDescriptor(canonicalName: "COPYBASE",   aliases: [],                category: .modify,  syntax: "", description: "Copy selected entities to clipboard with a base point"),
        CommandDescriptor(canonicalName: "PASTECLIP",  aliases: [],                category: .modify,  syntax: "", description: "Paste clipboard entities at viewport center"),
        CommandDescriptor(canonicalName: "PASTEORIG",  aliases: [],                category: .modify,  syntax: "", description: "Paste clipboard entities at original coordinates"),
        CommandDescriptor(canonicalName: "PASTEBLOCK", aliases: [],                category: .modify,  syntax: "", description: "Paste clipboard entities as a new block"),
        CommandDescriptor(canonicalName: "CLEANSPECKLES", aliases: ["CS", "SPECKLES"], category: .modify, syntax: "", description: "Remove tiny/speckle entities from the drawing"),
        CommandDescriptor(canonicalName: "TEXTEDIT",   aliases: ["DDEDIT", "ED", "TEDIT"], category: .modify, syntax: "", description: "Edit text, multiline text, and attribute values"),
        CommandDescriptor(canonicalName: "DRAWORDER",  aliases: ["DR"],            category: .modify,  syntax: "[Above/Under/Front/Back]", description: "Change the draw order of selected entities"),
        CommandDescriptor(canonicalName: "CHPROP",     aliases: [],                category: .modify,  syntax: "", description: "Change color, layer, linetype, or lineweight of selected entities"),
        CommandDescriptor(canonicalName: "CHANGE",     aliases: [],                category: .modify,  syntax: "", description: "Change properties of selected entities (legacy form)"),
        CommandDescriptor(canonicalName: "JOIN",       aliases: ["J"],             category: .modify,  syntax: "", description: "Join selected line entities into polylines"),
        CommandDescriptor(canonicalName: "TRIM",       aliases: ["TR"],            category: .modify,  syntax: "", description: "Trim lines at intersections — click the side to remove"),
        CommandDescriptor(canonicalName: "FILLET",     aliases: ["F"],            category: .modify,  syntax: "", description: "Round corners between objects using an exact tangent arc"),
        CommandDescriptor(canonicalName: "CHAMFER",    aliases: ["CHA", "BEVEL"], category: .modify,  syntax: "", description: "Bevel corners using distances or a distance and angle"),
        CommandDescriptor(canonicalName: "OFFSET",     aliases: ["O"],            category: .modify,  syntax: "", description: "Create a parallel copy at a distance or through a point"),
        CommandDescriptor(canonicalName: "OFFSETGAPTYPE", aliases: [],            category: .settings, syntax: "[0|1|2]", description: "Polyline offset corner style: 0 extend, 1 fillet, 2 chamfer"),
        CommandDescriptor(canonicalName: "ARRAY", aliases: ["AR"], category: .modify, syntax: "", description: "Create a rectangular, polar, or path array"),
        CommandDescriptor(canonicalName: "ARRAYRECT", aliases: ["ARRAYR"], category: .modify, syntax: "", description: "Create an associative rectangular array"),
        CommandDescriptor(canonicalName: "ARRAYPOLAR", aliases: ["ARRAYP"], category: .modify, syntax: "", description: "Create an associative polar array"),
        CommandDescriptor(canonicalName: "ARRAYPATH", aliases: ["ARRAYPA"], category: .modify, syntax: "", description: "Create an associative path array"),
        CommandDescriptor(canonicalName: "ARRAYEDIT", aliases: [], category: .modify, syntax: "", description: "Select and edit an associative array"),
        CommandDescriptor(canonicalName: "ARRAYCLOSE", aliases: [], category: .modify, syntax: "", description: "Close array editing or source-edit mode"),
        CommandDescriptor(canonicalName: "-ARRAYCLOSE", aliases: [], category: .modify, syntax: "[Yes|No]", description: "Close array source editing from the command line"),
        CommandDescriptor(canonicalName: "ARRAYCLASSIC", aliases: [], category: .modify, syntax: "", description: "Create a legacy non-associative rectangular or polar array"),
        CommandDescriptor(canonicalName: "-ARRAY", aliases: [], category: .modify, syntax: "", description: "Create a non-associative rectangular or polar array from prompts"),
        CommandDescriptor(canonicalName: "ARRAYASSOCIATIVITY", aliases: [], category: .settings, syntax: "[0|1]", description: "Set whether new arrays are associative"),
        CommandDescriptor(canonicalName: "ARRAYEDITSTATE", aliases: [], category: .settings, syntax: "", description: "Display whether array source editing is active"),
        CommandDescriptor(canonicalName: "ARRAYTYPE", aliases: [], category: .settings, syntax: "[0|1|2]", description: "Set the default array type: rectangular, path, or polar"),
        CommandDescriptor(canonicalName: "EXPLODE", aliases: ["X"], category: .modify, syntax: "", description: "Break a compound object into its component elements"),
        CommandDescriptor(canonicalName: "MATCHPROP",   aliases: ["MA", "MATCH"],  category: .modify,  syntax: "", description: "Copy properties from one entity to others"),
        CommandDescriptor(canonicalName: "TORIENT",    aliases: ["TOR", "TEXTO"], category: .modify, syntax: "", description: "Rotate text individually to an absolute or most-readable angle"),
        CommandDescriptor(canonicalName: "SPLINEDIT",  aliases: ["SPLINEEDIT", "SPE"], category: .modify, syntax: "", description: "Edit an existing spline (reverse, convert to polyline, etc.)"),
        CommandDescriptor(canonicalName: "MLEADEREDIT", aliases: ["MLE"], category: .modify, syntax: "", description: "Add or remove leader branches and edit multileader content"),
        CommandDescriptor(canonicalName: "MLEADERALIGN", aliases: ["MLA"], category: .modify, syntax: "", description: "Align and distribute selected multileader content"),
        CommandDescriptor(canonicalName: "MLEADERCOLLECT", aliases: ["MLC"], category: .modify, syntax: "", description: "Collect selected block multileaders into one multileader"),
        // --- View ---
        CommandDescriptor(canonicalName: "SELECTALL",  aliases: ["SELALL"],        category: .view,    syntax: "", description: "Select all entities in the active layer"),
        CommandDescriptor(canonicalName: "ZOOM",        aliases: ["Z"],             category: .view,    syntax: "", description: "Zoom: All/Center/Dynamic/Extents/Left/Previous/Right/Scale/Object/Window"),
        CommandDescriptor(canonicalName: "ZOOMEXTENTS",aliases: ["ZOOME"],         category: .view,    syntax: "", description: "Zoom to fit all entities in the viewport"),
        CommandDescriptor(canonicalName: "VIEW",       aliases: ["V", "VIEWS"],     category: .view,    syntax: "[name|index]", description: "List, select, or cycle model and sheet views"),
        CommandDescriptor(canonicalName: "LAYOUT",     aliases: ["SHEET", "LO"],   category: .view,    syntax: "[name|index]", description: "Select or cycle imported DXF sheet layouts"),
        CommandDescriptor(canonicalName: "MODEL",      aliases: ["2DVIEW"],        category: .view,    syntax: "", description: "Switch to the DXF 2D model-space view"),
        CommandDescriptor(canonicalName: "NEXTVIEW",   aliases: ["VIEWNEXT"],      category: .view,    syntax: "", description: "Switch to the next model or sheet view"),
        CommandDescriptor(canonicalName: "PREVIOUSVIEW", aliases: ["PREVVIEW", "VIEWPREV"], category: .view, syntax: "", description: "Switch to the previous model or sheet view"),
        CommandDescriptor(canonicalName: "AALINES",    aliases: [],                category: .view,    syntax: "", description: "Toggle anti-aliased line rendering on/off"),
        CommandDescriptor(canonicalName: "REDRAW",     aliases: ["R"],             category: .view,    syntax: "", description: "Refresh the viewport display"),
        CommandDescriptor(canonicalName: "REGEN",      aliases: [],                category: .view,    syntax: "", description: "Regenerate the drawing from its database"),
        CommandDescriptor(canonicalName: "TOOLBAR",    aliases: ["TO"],            category: .view,    syntax: "", description: "Show or hide the toolbar (ribbon)"),
        CommandDescriptor(canonicalName: "PSPACE",     aliases: ["PS"],            category: .view,    syntax: "", description: "Switch to paper space"),
        CommandDescriptor(canonicalName: "PROPERTIES", aliases: ["PROPS", "PR", "CH", "MO"], category: .view, syntax: "", description: "Show/hide the properties panel"),
        CommandDescriptor(canonicalName: "GROUP",      aliases: ["G"],             category: .modify,  syntax: "", description: "Create a lightweight named or unnamed object group"),
        CommandDescriptor(canonicalName: "NAV",        aliases: ["RADIALNAV"],     category: .view,    syntax: "", description: "Show/hide the radial navigation tool"),
        CommandDescriptor(canonicalName: "PAN",        aliases: ["P"],             category: .view,    syntax: "", description: "Pan the view by clicking and dragging"),
        CommandDescriptor(canonicalName: "-PAN",       aliases: [],                category: .view,    syntax: "", description: "Pan the view by specifying a displacement vector"),
        CommandDescriptor(canonicalName: "PLAN",       aliases: [],                category: .view,    syntax: "", description: "Reset view rotation to standard orientation"),
        CommandDescriptor(canonicalName: "DVIEW",      aliases: ["DV"],            category: .view,    syntax: "", description: "Dynamic view: twist the 2D view angle"),
        CommandDescriptor(canonicalName: "SNAPANG",    aliases: [],                category: .settings, syntax: "<degrees>", description: "Set the crosshair and ortho rotation angle"),
        // --- Layer ---
        CommandDescriptor(canonicalName: "LAYER",      aliases: ["LA"],            category: .layer,   syntax: "", description: "Show/hide the layer panel"),
        CommandDescriptor(canonicalName: "-LAYER",     aliases: ["-LA"],           category: .layer,   syntax: "Make/Set/New/On/Off/Color/Ltype/LWeight <args>", description: "Manage layers from the command line"),
        CommandDescriptor(canonicalName: "LAYER NEW",  aliases: ["LA NEW"],        category: .layer,   syntax: "<name>", description: "Create a new layer with an optional name"),
        CommandDescriptor(canonicalName: "LAYER DELETE", aliases: ["LAYER DEL", "LA DELETE", "LA DEL"], category: .layer, syntax: "<name>", description: "Delete a layer by name"),
        CommandDescriptor(canonicalName: "LAYER RENAME", aliases: ["LA RENAME"],   category: .layer,   syntax: "<oldName> <newName>", description: "Rename an existing layer"),
        CommandDescriptor(canonicalName: "LAYERSORT", aliases: ["LASORT", "LAYER SORT", "LA SORT"], category: .layer, syntax: "[Name|On|Color|Linetype|Lineweight|Opacity|Plot|Used] [Asc|Desc]", description: "Sort layers in the Layers panel by property; repeat a key to toggle direction"),
        CommandDescriptor(canonicalName: "LAYERMOVE",    aliases: ["LM", "LAYMOVE"], category: .layer, syntax: "", description: "Move selected entities to a different layer (autocomplete prompt)"),
        CommandDescriptor(canonicalName: "LAYOFF",     aliases: [],                category: .layer,   syntax: "", description: "Turn off the layer of a selected object (pick-driven)"),
        CommandDescriptor(canonicalName: "LAYON",      aliases: [],                category: .layer,   syntax: "", description: "Turn on the layer of a selected object (pick-driven)"),
        CommandDescriptor(canonicalName: "LAYISO",     aliases: [],                category: .layer,   syntax: "[Settings]", description: "Isolate the layer of a selected object; others hidden or faded"),
        CommandDescriptor(canonicalName: "LAYUNISO",   aliases: [],                category: .layer,   syntax: "", description: "Restore layers hidden by the most recent LAYISO"),
        CommandDescriptor(canonicalName: "LAYMCUR",    aliases: ["AI_MOLC"],        category: .layer,   syntax: "", description: "Make the layer of a selected object current"),
        CommandDescriptor(canonicalName: "LAYMCH",     aliases: [],                category: .layer,   syntax: "", description: "Change selected entities to the layer of a picked destination object"),
        // --- Block ---
        CommandDescriptor(canonicalName: "BLOCK",      aliases: ["B", "BMAKE"],     category: .block,   syntax: "<name>", description: "Create a new block from selected entities"),
        CommandDescriptor(canonicalName: "WBLOCK",     aliases: ["W"],             category: .block,   syntax: "", description: "Write a block or entities to a drawing file"),
        CommandDescriptor(canonicalName: "BEDIT",      aliases: ["EDITBLOCK", "BE"], category: .block,  syntax: "", description: "Edit the selected block reference in-place"),
        CommandDescriptor(canonicalName: "BCLOSE",     aliases: [],                category: .block,   syntax: "", description: "Close the block editor and save changes"),
        CommandDescriptor(canonicalName: "BLOCKS",     aliases: ["BLOCKPANEL"],    category: .block,   syntax: "", description: "Show/hide the block panel"),
        CommandDescriptor(canonicalName: "INSERT",     aliases: ["I", "-I", "-INSERT"], category: .block, syntax: "", description: "Insert a block or drawing file as a block reference"),
        CommandDescriptor(canonicalName: "XATTACH",    aliases: ["XA"],            category: .block,   syntax: "", description: "Attach a drawing as an external reference"),
        CommandDescriptor(canonicalName: "XREF",       aliases: ["XR", "ER", "EXTERNALREFERENCES"], category: .block, syntax: "", description: "Show/hide the External References palette"),
        CommandDescriptor(canonicalName: "ATTACH",     aliases: [],                category: .block,   syntax: "", description: "Attach a drawing, image, or PDF as a live reference"),
        CommandDescriptor(canonicalName: "IMAGEATTACH", aliases: ["IAT"],          category: .block,   syntax: "", description: "Attach a raster image as a live reference"),
        CommandDescriptor(canonicalName: "PDFATTACH",  aliases: [],                category: .block,   syntax: "", description: "Attach a PDF page as a live underlay reference"),
        CommandDescriptor(canonicalName: "-ATTACH",    aliases: [],                category: .block,   syntax: "", description: "Attach a reference file from the command line"),
        CommandDescriptor(canonicalName: "-XREF",      aliases: [],                category: .block,   syntax: "", description: "Manage external references from the command line"),
        CommandDescriptor(canonicalName: "XBIND",      aliases: [],                category: .block,   syntax: "", description: "Bind one xref-dependent layer into the host"),
        // --- Settings ---
        CommandDescriptor(canonicalName: "STYLE",      aliases: ["ST"], category: .settings, syntax: "", description: "Create and edit text styles"),
        CommandDescriptor(canonicalName: "MLEADERSTYLE", aliases: ["MLS"], category: .settings, syntax: "", description: "Create and edit multileader styles"),
        CommandDescriptor(canonicalName: "THEME",      aliases: ["DARKMODE", "LIGHTMODE"], category: .settings, syntax: "[DARK|LIGHT]", description: "Toggle or set the UI theme (dark/light mode)"),
        CommandDescriptor(canonicalName: "FPS",        aliases: [],                        category: .settings, syntax: "", description: "Toggle FPS counter in the title bar"),
        CommandDescriptor(canonicalName: "AUTOCONTRAST", aliases: ["CONTRAST", "TRUECOLORCONTRAST"], category: .settings, syntax: "[ON|OFF]", description: "Toggle auto-contrast clamping for 24-bit TrueColors and gradients"),
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
        CommandDescriptor(canonicalName: "OSNAP",           aliases: [],                category: .settings, syntax: "", description: "Toggle running object snaps on/off (F3)"),
        CommandDescriptor(canonicalName: "COMMANDLINE",     aliases: ["CLI"],           category: .view,     syntax: "", description: "Show or hide the command line"),
        CommandDescriptor(canonicalName: "CLEANSCREENON",   aliases: [],                category: .view,     syntax: "", description: "Hide ribbon and panels to maximize the canvas"),
        CommandDescriptor(canonicalName: "CLEANSCREENOFF",  aliases: [],                category: .view,     syntax: "", description: "Restore ribbon and panels hidden by CLEANSCREENON"),
        CommandDescriptor(canonicalName: "EXTENSION",       aliases: ["EXT"],           category: .settings, syntax: "", description: "Toggle extension snapping on/off"),
        CommandDescriptor(canonicalName: "ORTHO",          aliases: [],                category: .settings, syntax: "", description: "Toggle ortho mode (F8) — constrain cursor to cardinal axes"),
        CommandDescriptor(canonicalName: "UNITS",          aliases: ["UN", "UNIT", "DDUNITS"], category: .settings, syntax: "[mm|cm|m|in|ft|yd]", description: "Set or display the drawing base unit"),
        CommandDescriptor(canonicalName: "DIMSTYLE",       aliases: ["D", "DST"], category: .settings, syntax: "", description: "Manage dimension styles"),
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
    /// True when an active command (e.g. MOVE, ROTATE, SCALE, COPY) was
    /// invoked without a pre-existing selection and is currently waiting
    /// for the user to select objects before proceeding.
    public internal(set) var isSelectingObjects: Bool = false
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
    /// Canonical command owning each registry key. Two different canonicals
    /// must never share one key (the `R` → ROTATE-vs-RAY class of bug);
    /// registration asserts in debug and the parity tests pin the table.
    private var featureCommandCanonicalByKey: [String: String] = [:]

    /// Key → canonical-name map of the feature registry (parity-test seam).
    public var featureCommandKeys: [String: String] {
        featureCommandCanonicalByKey
    }

    /// Backing store for `lispInvocationDepth` (see LispInvocationContext.swift).
    var _lispInvocationDepth: Int = 0

    /// Returns true when an AutoLISP routine is actively executing off-thread
    /// and not suspended waiting on user prompt input.
    public var isLispActivelyEvaluating: Bool {
        if _lispInvocationDepth > 0, let lispCmd = activeFeatureCommand as? LispCommand {
            return lispCmd.isActivelyEvaluating
        }
        return false
    }

    /// Persistent AutoLISP session: defuns and setq globals survive across
    /// LOAD/EVAL/c: runs (one session per app; AutoCAD scopes per-document).
    /// Each run checks a copy in/out; the depth guard keeps runs single-flight.
    public var lispSession = LispEnvironment()

    /// App-wide system-variable store, shared by every `LispCADHost` this
    /// processor creates (LOAD/EVAL/c: runs and the ribbon definition load).
    /// One store per app matches AutoCAD: memory sysvars set by one routine
    /// are visible to the next, and the ribbon can read them per frame.
    var lispVars = LispVarStore()

    public var arrayAssociativity: Bool =
        UserDefaults.standard.object(forKey: "Zephyr.ArrayAssociativity") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(arrayAssociativity, forKey: "Zephyr.ArrayAssociativity")
        }
    }
    public var arrayDefaultType: CADArrayKind = {
        let raw = UserDefaults.standard.integer(forKey: "Zephyr.ArrayType")
        switch raw {
        case 1: return .path
        case 2: return .polar
        default: return .rectangular
        }
    }() {
        didSet {
            let raw: Int
            switch arrayDefaultType {
            case .rectangular: raw = 0
            case .path: raw = 1
            case .polar: raw = 2
            }
            UserDefaults.standard.set(raw, forKey: "Zephyr.ArrayType")
        }
    }

    // MARK: Engine Reference

    /// Weak reference to the owning engine, used to access document, selection, and drag state.
    /// Set via `configure(engine:)` during `PhrostEngine.init?` after all stored properties are initialized.
    private weak var engine: PhrostEngine?

    // MARK: Initialization

    public init() {}

    // MARK: - Chrome support (ribbon)

    /// Best-effort canonical name of the running command, for UI predicates
    /// such as the ribbon's `(zr-cmd "TRIM")`.
    ///
    /// Legacy interactive commands set `activeCommand`; feature commands do
    /// not carry a name, so the type name minus the `Command` suffix is the
    /// best available answer (`TrimCommand` -> `TRIM`).
    public var activeCommandDisplayName: String? {
        if let activeCommand { return activeCommand }
        guard let feature = activeFeatureCommand else { return nil }
        let typeName = String(describing: type(of: feature)).uppercased()
        return typeName.hasSuffix("COMMAND")
            ? String(typeName.dropLast("COMMAND".count))
            : typeName
    }

    /// Keeps a toggle sysvar in step with the state a command just changed,
    /// so `(zr-check (zr-var "GRIDMODE" 1))` follows the actual grid state.
    private func syncToggleSysvar(
        _ name: String, on: Bool, engine: PhrostEngine
    ) {
        _ = lispVars.set(
            name, .int(on ? 1 : 0), document: engine.document)
    }

    /// Publishes the engine's current toggle states into the sysvar store,
    /// so chrome that reads them (ribbon `check` predicates) agrees with the
    /// viewport from the first frame. Called once at startup.
    public func synchronizeToggleSysvars(engine: PhrostEngine) {
        syncToggleSysvar("GRIDMODE", on: engine.snap.gridVisible, engine: engine)
        syncToggleSysvar(
            "ORTHOMODE", on: engine.snap.orthoEnabled, engine: engine)
        syncToggleSysvar(
            "POLARMODE", on: engine.snap.polarTrackingEnabled, engine: engine)
    }

    /// Every command a ribbon entry may reference: descriptor names and
    /// aliases (the legacy dispatch surface plus documented commands), the
    /// registered feature commands, and the loaded AutoLISP `c:` routines.
    ///
    /// Descriptors alone are not enough: several feature commands register
    /// without one (`PENSTROKE`, `REVCLOUD`, `TABLE`, …), so the registry is
    /// consulted too — otherwise the definition would silently drop them.
    public var ribbonCommandCatalog: RibbonCommandCatalog {
        var known = Set<String>()
        for descriptor in CommandDescriptor.allCommands {
            known.insert(descriptor.canonicalName.uppercased())
            for alias in descriptor.aliases {
                known.insert(alias.uppercased())
            }
        }
        for name in featureCommandRegistry.keys {
            known.insert(name.uppercased())
        }
        for name in lispSession.functions.keys where name.hasPrefix("C:") {
            known.insert(String(name.dropFirst(2)).uppercased())
        }
        return RibbonCommandCatalog(known: known)
    }

    /// Read-only sysvar access for UI chrome (`%CLAYER%` labels and
    /// `(zr-var …)` predicates). Reads the same app-wide store AutoLISP uses,
    /// so a `(setvar …)` from a routine is reflected immediately.
    public func systemVariable(_ name: String) -> LispValue? {
        guard let engine else { return nil }
        return lispVars.get(
            name.uppercased(),
            document: engine.document,
            activeCommand: activeCommand)
    }

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
        let canonical = name.uppercased()
        featureCommandRegistry[canonical] = factory
        assert(
            featureCommandCanonicalByKey[canonical] == nil
                || featureCommandCanonicalByKey[canonical] == canonical,
            "Feature command key '\(canonical)' claimed by two canonicals")
        featureCommandCanonicalByKey[canonical] = canonical
        for alias in aliases {
            let key = alias.uppercased()
            assert(
                featureCommandCanonicalByKey[key] == nil
                    || featureCommandCanonicalByKey[key] == canonical,
                "Feature command alias '\(key)' claimed by "
                    + "'\(featureCommandCanonicalByKey[key] ?? "?")' and '\(canonical)'")
            featureCommandRegistry[key] = factory
            featureCommandCanonicalByKey[key] = canonical
        }
        // Register in the autocomplete descriptor list if not already present.
        // When no explicit descriptor is passed, synthesize one from the
        // canonical alias table so executable commands stay discoverable
        // (TABLE, MEASURE, and CLIP were invisible to autocomplete).
        let desc = descriptor ?? CADCommandAliasTable.entry(canonicalName: canonical)?.descriptor
        if let desc {
            if !CommandDescriptor.allCommands.contains(where: { $0.canonicalName == desc.canonicalName }) {
                CommandDescriptor.allCommands.append(desc)
            }
        }
    }

    /// Activate a specific feature-command instance (used by panels that
    /// start a command with pre-seeded state, e.g. Insert-with-block).
    public func activateFeatureCommand(_ command: any FeatureCommand) {
        guard let engine else { return }
        activeFeatureCommand = command
        command.start(engine: engine, processor: self)
    }

    /// Clean up the active feature command (calls `cancel()`, nils the reference,
    /// and resets the prompt).
    internal func finishFeatureCommand(engine: PhrostEngine) {
        guard let cmd = activeFeatureCommand else { return }
        cmd.cancel(engine: engine, processor: self)
        activeFeatureCommand = nil
        commandPrompt = nil
    }

    /// Run a loaded AutoLISP `c:` function by bare command name (already
    /// uppercased). Returns false when no such function is defined — the
    /// caller treats the input as an unknown command.
    internal func startLispCall(_ name: String, engine: PhrostEngine) -> Bool {
        guard activeFeatureCommand == nil,
              lispSession.functions["C:\(name)"] != nil
        else { return false }
        print("[Lisp] c: dispatch \(name)")
        let cmd = LispCommand(mode: .call, source: "(C:\(name))")
        activeFeatureCommand = cmd
        cmd.start(engine: engine, processor: self)
        return true
    }

    @discardableResult
    public func submitTextToActiveFeatureCommand(
        _ text: String,
        engine: PhrostEngine
    ) -> Bool {
        guard let command = activeFeatureCommand else { return false }
        let result = command.handleCommandText(text, engine: engine, processor: self)
        if result == .finished, activeFeatureCommand != nil {
            finishFeatureCommand(engine: engine)
        }
        return true
    }

    // MARK: - Command Execution

    /// Execute a command string (e.g. "MOVE", "M", "ERASE").
    public func executeCommand(_ text: String) {
        // Reject-nested-interactive gate: while a Lisp routine runs, no
        // other command may start. Must precede lastExecutedCommand so a
        // rejected command never poisons spacebar repeat.
        if rejectCommandIfLispActive(text) { return }
        let upper = text.uppercased().trimmingCharacters(in: .whitespaces)
        if upper.isEmpty {
            if isSelectingObjects {
                confirmObjectSelection()
            }
            return
        }
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
        // --- History (UNDO / REDO) ---
        // Registered so the shortcuts are discoverable: typing the name works
        // exactly like Cmd/Ctrl+Z and Cmd/Ctrl+Y (see EngineInputHandler).
        // An optional count undoes/redoes several steps in one command.
        case _ where upper.hasPrefix("UNDO ") || upper.hasPrefix("U "):
            guard let engine = engine else { clearCommand(); return }
            let prefixLength = upper.hasPrefix("UNDO ") ? 5 : 2
            let argument = String(upper.dropFirst(prefixLength))
                .trimmingCharacters(in: .whitespaces)
            guard let steps = Int(argument), steps > 0 else {
                print("[CAD] Invalid step count '\(argument)'. Usage: UNDO [<count>]")
                clearCommand()
                return
            }
            performUndo(engine: engine, steps: steps)
            clearCommand()
        case _ where upper.hasPrefix("REDO "):
            guard let engine = engine else { clearCommand(); return }
            let argument = String(upper.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            guard let steps = Int(argument), steps > 0 else {
                print("[CAD] Invalid step count '\(argument)'. Usage: REDO [<count>]")
                clearCommand()
                return
            }
            performRedo(engine: engine, steps: steps)
            clearCommand()
        case "UNDO", "U":
            guard let engine = engine else { clearCommand(); return }
            performUndo(engine: engine, steps: 1)
            clearCommand()
        case "REDO":
            guard let engine = engine else { clearCommand(); return }
            performRedo(engine: engine, steps: 1)
            clearCommand()
        case "REDRAW", "R":
            engine?.document.markEdited(regenerate: false)
            print("[CAD] View redrawn.")
            clearCommand()
        case "REGEN", "REGENALL":
            engine?.document.markEdited(regenerate: true)
            print("[CAD] Drawing regenerated.")
            clearCommand()
        case "HATCHEDIT", "HE":
            guard let engine = engine else { clearCommand(); return }
            guard let handle = engine.cadSelection.lastSelectedHandle,
                  let entity = engine.document.entity(for: handle),
                  let geometry = engine.document.resolvedGeometry(for: entity),
                  geometry.contains(where: { prim in
                      switch prim {
                      case .hatch, .hatchPath, .fillPolygon, .fillComplexPolygon, .gradient:
                          return true
                      default:
                          return false
                      }
                  }) else {
                print("[CAD] HATCHEDIT requires a single selected hatch.")
                clearCommand()
                return
            }
            // HatchCommand.start() picks up the selected hatch (pattern,
            // scale, angle) via initFromEntity, so editing starts in place.
            let hatchCmd = HatchCommand()
            activeFeatureCommand = hatchCmd
            hatchCmd.start(engine: engine, processor: self)
        case "-HATCH":
            guard let engine = engine else { clearCommand(); return }
            startDashHatchCommand(text: text, upper: upper, engine: engine)
        case _ where upper.hasPrefix("-HATCH "):
            guard let engine = engine else { clearCommand(); return }
            startDashHatchCommand(text: text, upper: upper, engine: engine)
        // --- File Commands ---
        case "N", "NEW":
            _ = engine?.tabManager.newTab()
            engine?.zoomExtents()
            clearCommand()
        case "OPEN":
            guard let eng = engine else { clearCommand(); return }
            clearCommand()
            NativeFileDialog.showOpenDialog(
                window: eng.dialogParentWindow,
                filters: [
                    NativeFileDialog.Filter(label: "Drawings", extensions: ["dxf", "dwg", "eab"])
                ],
                allowMultiple: true
            ) { [weak eng] urls in
                guard let eng else { return }
                for url in urls {
                    do {
                        try eng.tabManager.openTab(url: url)
                    } catch {
                        print("Failed to open \(url.lastPathComponent): \(error)")
                    }
                }
                if !urls.isEmpty {
                    eng.zoomExtents()
                }
            }
        case "PDFI", "PDFIMPORT", "PDF":
            guard let eng = engine else { clearCommand(); return }
            clearCommand()
            NativeFileDialog.showOpenDialog(
                window: eng.dialogParentWindow,
                filters: [
                    NativeFileDialog.Filter(label: "PDF Documents", extensions: ["pdf"])
                ]
            ) { [weak eng] urls in
                guard let eng, let url = urls.first else { return }
                // Re-use the existing PDFImportCommand flow by executing it as
                // a feature command and immediately feeding it the selected URL.
                let cmd = PDFImportCommand()
                eng.commandProcessor.activeFeatureCommand = cmd
                cmd.start(engine: eng, processor: eng.commandProcessor)
                cmd.handlePDFSelected(url: url, engine: eng, processor: eng.commandProcessor)
            }
        case "CLOSE":
            _ = engine?.tabManager.requestCloseActiveTab()
            clearCommand()
        case "TABL", "TABLEFT":
            _ = engine?.tabManager.moveActiveTabLeft()
            clearCommand()
        case "TABR", "TABRIGHT":
            _ = engine?.tabManager.moveActiveTabRight()
            clearCommand()
        case "FILETAB":
            engine?.ui.fileTabsVisible = true
            clearCommand()
        case "FILETABCLOSE":
            engine?.ui.fileTabsVisible = false
            clearCommand()
        // --- Ribbon (defined in AutoLISP: lisp/ribbon.lsp) ---
        case "RIBBON", "TOOLBAR", "TO":
            guard let eng = engine else { clearCommand(); return }
            eng.ui.ribbonVisible.toggle()
            clearCommand()
        case "RIBBONCLOSE":
            engine?.ui.ribbonVisible = false
            clearCommand()
        case "RIBBONRELOAD":
            guard let eng = engine else { clearCommand(); return }
            if eng.ribbonLoader == nil {
                print("[CAD] Ribbon support is not available in this build.")
            } else {
                eng.ribbonLoader?.reload()
            }
            clearCommand()
        case _ where upper.hasPrefix("RIBBONMODE "):
            guard let eng = engine else { clearCommand(); return }
            let argument = String(upper.dropFirst("RIBBONMODE ".count))
                .trimmingCharacters(in: .whitespaces)
            switch argument {
            case "MENU", "MENUBAR", "M":
                eng.ui.ribbonMode = .menu
            case "LABELS", "LABEL", "TEXT", "L":
                eng.ui.ribbonMode = .labels
            case "FULL", "ICONS", "F":
                eng.ui.ribbonMode = .full
            default:
                print("[CAD] RIBBONMODE expects menu, labels or full (got '\(argument)').")
            }
            clearCommand()
        case "RIBBONMODE":
            if let eng = engine {
                print("[CAD] Ribbon mode is '\(eng.ui.ribbonMode.rawValue)'. "
                    + "Usage: RIBBONMODE [menu|labels|full]")
            }
            clearCommand()
        case "TABW", "TABWINDOW", "FLOAT":
            if let id = engine?.tabManager.activeTab?.id {
                _ = engine?.floatTab(id: id)
            }
            clearCommand()
        case "TABD", "TABDOCK", "DOCK":
            if let id = engine?.tabManager.activeTab?.id {
                if engine?.dockTab(id: id) == false {
                    print("[CAD] Active tab is not floated.")
                }
            }
            clearCommand()
        case "VSPLIT":
            engine?.splitMainPane(axis: .sideBySide)
            clearCommand()
        case "HSPLIT":
            engine?.splitMainPane(axis: .stacked)
            clearCommand()
        case "UNSPLIT", "CLOSESPLIT":
            if engine?.unsplitMainPane() == false {
                print("[CAD] The main view is not split.")
            }
            clearCommand()
        case "CLOSEPANE":
            if engine?.joinMainPane() == false {
                print("[CAD] The main view is not split.")
            }
            clearCommand()
        case "VPMAX":
            if engine?.unsplitMainPane() == false {
                print("[CAD] The main view is not split.")
            }
            clearCommand()
        case "VPMIN":
            if engine?.vpMinRestore() == false {
                print("[CAD] No saved split arrangement to restore.")
            }
            clearCommand()
        case "VPEQUAL", "EQUALIZE":
            if engine?.equalizeMainPanes() == false {
                print("[CAD] The main view is not split.")
            }
            clearCommand()
        case _ where upper == "VPRESIZE" || upper.hasPrefix("VPRESIZE "):
            let argument = String(upper.dropFirst("VPRESIZE".count))
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "%", with: "")
            if argument.isEmpty {
                print("[CAD] Usage: VPRESIZE <+N|-N>  (percent of the focused pane's parent split, e.g. VPRESIZE +10)")
            } else if let percent = Float(argument.hasPrefix("+") ? String(argument.dropFirst()) : argument) {
                if engine?.resizeFocusedPane(by: percent / 100) == false {
                    print("[CAD] The main view is not split.")
                }
            } else {
                print("[CAD] VPRESIZE expects a signed percentage (got '\(argument)').")
            }
            clearCommand()
        case _ where upper == "VPORTS" || upper.hasPrefix("VPORTS "):
            if let engine {
                let arg = String(upper.dropFirst("VPORTS".count))
                    .trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: " ", with: "")
                handleVPortsCommand(engine: engine, arg: arg)
            }
            clearCommand()
        case "CLOSEALL":
            guard let engine = engine else { clearCommand(); return }
            // Create a fresh blank tab first, then close all others.
            // This avoids the "can't close last tab" restriction.
            _ = engine.tabManager.newTab()
            engine.zoomExtents()
            let keepIndex = engine.tabManager.activeIndex
            var idx = engine.tabManager.tabs.count - 1
            while idx >= 0 {
                if idx != keepIndex {
                    _ = engine.tabManager.requestCloseTab(at: idx)
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
                    _ = engine.tabManager.requestCloseTab(at: idx)
                }
                idx -= 1
            }
            clearCommand()
        case "SAVE", "QSAVE": 
            guard let eng = engine else { clearCommand(); return }
            clearCommand()
            do {
                try eng.tabManager.saveActiveTab()
            } catch TabManager.TabError.noFileURL {
                showNativeSaveDialog(engine: eng)
            } catch {
                print("Save failed: \(error)")
            }
        case "SAVEAS":
            guard let eng = engine else { clearCommand(); return }
            clearCommand()
            showNativeSaveDialog(engine: eng)
        case "DXFVERSION", "DXFVER":
            guard let eng = engine else { clearCommand(); return }
            let version = eng.tabManager.activeTab?.dxfVersion ?? .preferredExport
            print("[CAD] DXF export version: \(version.displayName) (\(version.rawValue))")
            print("[CAD] Usage: DXFVERSION <2018|2013|2010|2007|2004|2000|R14|R13|R12|R10>")
            clearCommand()
        case _ where upper.hasPrefix("DXFVERSION ") || upper.hasPrefix("DXFVER "):
            guard let eng = engine else { clearCommand(); return }
            let prefixLength = upper.hasPrefix("DXFVERSION ") ? 11 : 7
            let argument = String(upper.dropFirst(prefixLength))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let version = DXFVersion.parseExportArgument(argument) else {
                print("[CAD] Unknown DXF version '\(argument)'.")
                print("[CAD] Available: 2018, 2013, 2010, 2007, 2004, 2000, R14, R13, R12, R10")
                clearCommand()
                return
            }
            _ = eng.tabManager.setActiveDXFVersion(version)
            print("[CAD] DXF export version set to \(version.displayName) (\(version.rawValue)).")
            print("[CAD] Save and Save As will use this version for DXF and DWG output.")
            clearCommand()
        case "EXPORTPDF", "PDFEXPORT", "EPDF":
            guard let eng = engine else { clearCommand(); return }
            clearCommand()
            let pdfName = Self.pdfExportDefaultName(
                for: eng.tabManager.activeTab?.displayName)
            NativeFileDialog.showSaveDialog(
                window: eng.dialogParentWindow,
                filters: [
                    NativeFileDialog.Filter(label: "PDF Document", extensions: ["pdf"])
                ],
                defaultName: pdfName
            ) { [weak eng] url in
                guard let eng, let url else { return }
                eng.tabManager.startSaveActiveTabAs(
                    url: Self.pdfExportTargetURL(from: url),
                    dxfVersion: eng.tabManager.activeTab?.dxfVersion ?? .r2018
                )
            }
        // --- Existing commands ---
        case "M", "MOVE":
            guard let engine = engine else { clearCommand(); return }
            if !engine.cadSelection.hasSelection {
                startCommand("MOVE", prompt: "Select objects to move, then press Enter", selectingObjects: true)
                return
            }
            startCommand("MOVE", prompt: "Select base point")
        case "ROTATE", "RO":
            guard let engine = engine else { clearCommand(); return }
            if !engine.cadSelection.hasSelection {
                startCommand("ROTATE", prompt: "Select objects to rotate, then press Enter", selectingObjects: true)
                return
            }
            startCommand("ROTATE", prompt: "Pick rotation angle or drag")
        case "SCALE", "SC":
            guard let engine = engine else { clearCommand(); return }
            if !engine.cadSelection.hasSelection {
                startCommand("SCALE", prompt: "Select objects to scale, then press Enter", selectingObjects: true)
                return
            }
            startCommand("SCALE", prompt: "Pick scale factor or drag")
        case "AL", "ALIGN":
            guard let engine = engine else { clearCommand(); return }
            let cmd = AlignCommand()
            activeFeatureCommand = cmd
            cmd.start(engine: engine, processor: self)
        case "E", "ERASE":
            guard let engine = engine else { clearCommand(); return }
            if !engine.cadSelection.hasSelection {
                startCommand("ERASE", prompt: "Select objects to erase, then press Enter", selectingObjects: true)
                return
            }
            engine.deleteSelected()

        // --- Copy / Paste (Modify) ---
        case "COPYCLIP":
            guard let engine = engine else { clearCommand(); return }
            if !engine.cadSelection.hasSelection {
                startCommand("COPYCLIP", prompt: "Select objects to copy to clipboard, then press Enter", selectingObjects: true)
                return
            }
            captureToClipboard(engine: engine)
            print("[CAD] Copied \(engine.cadSelection.selectedHandles.count) entities to clipboard.")
            clearCommand()

        case "COPYBASE":
            guard let engine = engine else { clearCommand(); return }
            if !engine.cadSelection.hasSelection {
                startCommand("COPYBASE", prompt: "Select objects to copy with base point, then press Enter", selectingObjects: true)
                return
            }
            startCommand("COPYBASE", prompt: "Specify base point")

        case "COPY", "CO", "CP":
            guard let engine = engine else { clearCommand(); return }
            if !engine.cadSelection.hasSelection {
                startCommand("COPY", prompt: "Select objects to copy, then press Enter", selectingObjects: true)
                return
            }
            // Duplicate selected entities in-place
            let result = engine.document.duplicateEntities(
                handles: engine.cadSelection.selectedHandles)
            // Add cloned anonymous blocks (named blocks are shared in place)
            for newBlock in result.clonedBlocks {
                engine.document.addBlock(newBlock)
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
        case "AALINES":
            if let engine = engine {
                engine.renderer.antiAliasLines.toggle()
                print("[CAD] Anti-aliased lines: \(engine.renderer.antiAliasLines ? "ON" : "OFF")")
            }
            clearCommand()
        case "PROPERTIES", "PROPS", "PR", "CH", "MO":
            // Like BLOCKS/LAYER, toggles regardless of selection: an open
            // panel with nothing selected shows its empty state.
            if let engine = engine {
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
        case "BLOCK", "B", "BMAKE":
            guard let engine = engine else {
                clearCommand()
                break
            }
            guard engine.cadSelection.hasSelection else {
                print("[CAD] BLOCK requires entities to be selected.")
                clearCommand()
                break
            }
            startCommand("BLOCK", prompt: "Enter block name")

        case _ where upper.hasPrefix("BLOCK ") || upper.hasPrefix("BMAKE ") || upper.hasPrefix("B "):
            guard let engine = engine else {
                clearCommand()
                break
            }
            guard engine.cadSelection.hasSelection else {
                print("[CAD] BLOCK requires entities to be selected.")
                clearCommand()
                break
            }

            let parts = text.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            let namePart = parts.count > 1
                ? String(parts[1]).trimmingCharacters(in: .whitespaces)
                : ""
            guard !namePart.isEmpty else {
                startCommand("BLOCK", prompt: "Enter block name")
                break
            }

            let selectedCount = engine.cadSelection.selectedHandles.count
            let block = engine.document.createBlockFromEntities(
                handles: engine.cadSelection.selectedHandles,
                name: namePart)
            if block != nil {
                print("[CAD] Block '\(namePart)' created with \(selectedCount) entities.")
                engine.cadSelection.clearSelection()
            } else {
                print("[CAD] Failed to create block '\(namePart)'.")
            }
            clearCommand()
        case "BLOCKS", "BLOCKPANEL":
            if let engine = engine {
                engine.ui.blockPanelVisible.toggle()
            }
            clearCommand()
        case "XREF", "XR", "ER", "EXTERNALREFERENCES":
            if let engine = engine {
                engine.ui.xrefPanelVisible.toggle()
            }
            clearCommand()
        // --- Layer commands ---
        // --- Theme ---
        case "THEME":
            engine?.ui.cycleTheme()
            if let eng = engine {
                let themes = AppTheme.allPresets.map(\.displayName).joined(separator: ", ")
                print("[CAD] Theme set to: \(eng.ui.theme.name). Available themes: \(themes)")
            }
            clearCommand()
        case "DARKMODE":
            engine?.ui.setTheme(AppTheme.dark)
            clearCommand()
        case "LIGHTMODE":
            engine?.ui.setTheme(AppTheme.light)
            clearCommand()
        case _ where upper.hasPrefix("THEME "):
            let arg = String(upper.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            if let eng = engine {
                if eng.ui.setTheme(named: arg) {
                    print("[CAD] Theme set to: \(eng.ui.theme.name)")
                } else {
                    let available = AppTheme.allPresets.map(\.displayName).joined(separator: ", ")
                    print("[CAD] Unknown theme '\(arg)'. Available themes: \(available)")
                }
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
        case _ where upper == "LAYERSORT" || upper == "LASORT" || upper == "LAYER SORT" || upper == "LA SORT"
            || upper.hasPrefix("LAYERSORT ") || upper.hasPrefix("LASORT ")
            || upper.hasPrefix("LAYER SORT ") || upper.hasPrefix("LA SORT "):
            let tokens = upper.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            let argTokens: [String]
            if tokens.count >= 2, tokens[0] == "LAYER" || tokens[0] == "LA", tokens[1] == "SORT" {
                argTokens = Array(tokens.dropFirst(2))
            } else {
                argTokens = Array(tokens.dropFirst())
            }
            let current = LayerSortSettings.load()
            let usage = "LAYERSORT [Name|On|Color|Linetype|Lineweight|Opacity|Plot|Used] [Asc|Desc|Reverse]"
            if argTokens.isEmpty || argTokens.contains("?") {
                print("[CAD] Layer sort: \(current.key.displayName) \(current.ascending ? "ascending" : "descending"). Usage: \(usage)")
            } else if let updated = current.applyingCommandTokens(argTokens) {
                updated.save()
                print("[CAD] Layer sort: \(updated.key.displayName) \(updated.ascending ? "ascending" : "descending").")
            } else {
                print("[CAD] Invalid LAYERSORT option. Usage: \(usage)")
            }
            // Make the result visible immediately, like opening AutoCAD's
            // Layer Properties Manager to apply a column sort.
            engine?.ui.layersPanelVisible = true
            clearCommand()
        case _ where upper == "LAYER ?" || upper == "-LAYER ?" || upper == "LA ?" || upper == "-LA ?":
            guard let engine = engine else { clearCommand(); return }
            let doc = engine.document
            let counts = LayerSortPolicy.entityCounts(in: doc)
            print("[CAD] Layers (alphabetical):")
            for layer in doc.allLayers.sorted(by: { $0.name < $1.name }) {
                let state = layer.isVisible ? "On" : "Off"
                let current = doc.activeLayerID == layer.handle ? " (current)" : ""
                print("[CAD]   \(layer.name)\(current) — \(state), color \(DXFColorTable.rgbaToACI(layer.color)), lt \(layer.lineType), \(counts[layer.handle] ?? 0) ent")
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
        case "-LAYER", "-LA":
            print("[CAD] -LAYER Make/Set/New/On/Off/Color/Ltype/LWeight <args>")
            clearCommand()
        case _ where upper.hasPrefix("-LAYER ") || upper.hasPrefix("-LA "):
            guard let engine = engine else { clearCommand(); return }
            runDashLayerCommand(text: text, upper: upper, engine: engine)
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
                print("[CAD]   ACI index (0-255) or hex RRGGBB (e.g. BD20FF)")
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
            // Try parsing as ACI index (0-255)
            else if let aci = Int32(arg), aci >= 0, aci <= 255 {
                let r: Float
                let g: Float
                let b: Float
                if aci == 0 {
                    // ACI 0 = BYBLOCK, but for background purposes use pure black
                    r = 0; g = 0; b = 0
                } else {
                    let rgba = DXFColorTable.aciToRGBA(aci, color24: -1)
                    r = Float(rgba.r) / 255.0
                    g = Float(rgba.g) / 255.0
                    b = Float(rgba.b) / 255.0
                }
                engine.ui.backgroundColor = SDL_FColor(r: r, g: g, b: b, a: 1.0)
                print("[CAD] Background set to ACI \(aci) (RGB \(Int(r*255)),\(Int(g*255)),\(Int(b*255)))")
            } else {
                print("[CAD] Invalid color: '\(arg)'. Use ACI index (0-255) or hex RRGGBB (e.g. BD20FF).")
            }
            clearCommand()
        // --- Auto-Contrast ---
        case "AUTOCONTRAST", "TRUECOLORCONTRAST", "CONTRAST":
            guard let engine = engine else { clearCommand(); return }
            let doc = engine.tabManager.activeDocument
            doc.autoContrastTrueColor.toggle()
            doc.markNeedsRegeneration()
            print("[CAD] TrueColor auto-contrast: \(doc.autoContrastTrueColor ? "ON" : "OFF")")
            clearCommand()
        case _ where upper.hasPrefix("AUTOCONTRAST ") || upper.hasPrefix("TRUECOLORCONTRAST ") || upper.hasPrefix("CONTRAST "):
            guard let engine = engine else { clearCommand(); return }
            let prefixLen: Int
            if upper.hasPrefix("AUTOCONTRAST ") { prefixLen = 13 }
            else if upper.hasPrefix("TRUECOLORCONTRAST ") { prefixLen = 18 }
            else { prefixLen = 9 } // "CONTRAST "
            let arg = String(upper.dropFirst(prefixLen)).trimmingCharacters(in: .whitespaces)
            let doc = engine.tabManager.activeDocument
            switch arg {
            case "ON", "1", "TRUE":
                doc.autoContrastTrueColor = true
                doc.markNeedsRegeneration()
                print("[CAD] TrueColor auto-contrast: ON")
            case "OFF", "0", "FALSE":
                doc.autoContrastTrueColor = false
                doc.markNeedsRegeneration()
                print("[CAD] TrueColor auto-contrast: OFF")
            case "TOGGLE":
                doc.autoContrastTrueColor.toggle()
                doc.markNeedsRegeneration()
                print("[CAD] TrueColor auto-contrast: \(doc.autoContrastTrueColor ? "ON" : "OFF")")
            default:
                print("[CAD] Usage: AUTOCONTRAST [ON|OFF]")
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
        case "SELECTIONPREVIEWLIMIT":
            guard let engine = engine else { clearCommand(); return }
            print("[CAD] Selection preview limit: \(engine.selectionPreviewLimit) (entities)")
            clearCommand()
        case _ where upper.hasPrefix("SELECTIONPREVIEWLIMIT "):
            guard let engine = engine else { clearCommand(); return }
            let arg = String(text.dropFirst(22)).trimmingCharacters(in: .whitespaces) // "SELECTIONPREVIEWLIMIT "
            guard let val = Int(arg), val >= 1 else {
                print("[CAD] SELECTIONPREVIEWLIMIT requires a positive integer.")
                clearCommand()
                return
            }
            engine.selectionPreviewLimit = val
            print("[CAD] Selection preview limit set to \(val) (preview highlight disabled when a drag preview exceeds \(val))")
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
            engine.renderer.bumpAllContextGenerations()
            print("[CAD] Spline tessellation divisor set to \(val)")
            clearCommand()
        // --- Grid ---
        case "GRID":
            guard let engine = engine else { clearCommand(); return }
            engine.snap.gridVisible.toggle()
            syncToggleSysvar(
                "GRIDMODE", on: engine.snap.gridVisible, engine: engine)
            print("[CAD] Grid: \(engine.snap.gridVisible ? "ON" : "OFF")")
            clearCommand()
        case "GRID SNAP":
            guard let engine = engine else { clearCommand(); return }
            engine.snap.gridSnapEnabled.toggle()
            syncToggleSysvar(
                "SNAPMODE", on: engine.snap.gridSnapEnabled, engine: engine)
            print("[CAD] Grid Snap: \(engine.snap.gridSnapEnabled ? "ON" : "OFF")")
            clearCommand()
        case "OSNAP":
            guard let engine = engine else { clearCommand(); return }
            // Master running-osnap switch (F3). OSMODE is untouched: it
            // selects which modes run; this selects whether any run.
            engine.snap.objectSnapEnabled.toggle()
            if !engine.snap.objectSnapEnabled {
                engine.snap.lockedSnap = nil
                engine.snap.currentSnapResult = nil
            }
            print("[CAD] Object Snap: \(engine.snap.objectSnapEnabled ? "ON" : "OFF")")
            clearCommand()
        case "COMMANDLINE", "CLI":
            guard let engine = engine else { clearCommand(); return }
            // clearCommand() closes the command line, so set visibility after.
            if engine.commandProcessor.commandLineActive {
                clearCommand()
                print("[CAD] Command line hidden.")
            } else {
                clearCommand()
                engine.commandProcessor.commandLineActive = true
                print("[CAD] Type a command.")
            }
        case "CLEANSCREENON":
            guard let engine = engine else { clearCommand(); return }
            engine.ui.enterCleanScreen()
            print("[CAD] Clean screen on (Ctrl+0 toggles).")
            clearCommand()
        case "CLEANSCREENOFF":
            guard let engine = engine else { clearCommand(); return }
            engine.ui.exitCleanScreen()
            print("[CAD] Clean screen off.")
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
            syncToggleSysvar(
                "POLARMODE", on: engine.snap.polarTrackingEnabled,
                engine: engine)
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
            syncToggleSysvar(
                "ORTHOMODE", on: engine.snap.orthoEnabled, engine: engine)
            print("[CAD] Ortho: \(engine.snap.orthoEnabled ? "ON" : "OFF")")
            clearCommand()
        // --- Drawing Units ---
        case "UNITS", "UN", "UNIT", "DDUNITS":
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
        case "LAYMCH":
            // Same destination popup as LAYERMOVE: requires a selection,
            // then Enter applies the highlighted layer to it.
            guard let engine = engine else { clearCommand(); return }
            if engine.cadSelection.hasSelection {
                engine.ui.layerMoveActive = true
                engine.ui.layerMoveBuffer = ""
                engine.ui.layerMoveSelectionIndex = 0
                engine.ui.layerMoveMatches = engine.document.allLayers.sorted { $0.name < $1.name }
                commandLineActive = false
            } else {
                print("[CAD] LAYMCH requires entities to be selected.")
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
            else if let eng = engine {
                let parts = upper.split(maxSplits: 1, whereSeparator: \.isWhitespace)
                let commandName = parts.first.map(String.init) ?? upper
                guard let factory = featureCommandRegistry[commandName] else {
                    // Reserved LT names land here until their phase ships:
                    // report honestly instead of "unknown command".
                    if parts.count == 1,
                       let stub = CADCommandAliasTable.stubMessage(for: commandName) {
                        print(stub)
                        clearCommand()
                        return
                    }
                    // AutoLISP c: dispatch: a bare name matching a loaded
                    // (defun c:NAME ...) runs it. Built-ins and feature
                    // commands win; anything with arguments stays unknown.
                    if parts.count == 1, startLispCall(commandName, engine: eng) {
                        return
                    }
                    clearCommand()
                    return
                }
                let cmd = factory()
                activeFeatureCommand = cmd
                cmd.start(engine: eng, processor: self)
                if parts.count > 1, activeFeatureCommand != nil {
                    let argument = String(parts[1])
                    let result = cmd.handleCommandText(argument, engine: eng, processor: self)
                    if result == .finished, activeFeatureCommand != nil {
                        finishFeatureCommand(engine: eng)
                    }
                }
            } else {
                clearCommand()
            }
        }
    }

    /// Single-shot `VPORTS` options (AutoCAD-aligned names; Zephyr panes show
    /// different tabs instead of multiple views of one drawing).
    private func handleVPortsCommand(engine: PhrostEngine, arg: String) {
        switch arg {
        case "2V":
            engine.splitMainPane(axis: .sideBySide)
        case "2H":
            engine.splitMainPane(axis: .stacked)
        case "SINGLE":
            if !engine.unsplitMainPane() {
                print("[CAD] The main view is not split.")
            }
        case "JOIN":
            if !engine.joinMainPane() {
                print("[CAD] The main view is not split.")
            }
        case "TOGGLE":
            if !engine.toggleMainPanes() {
                print("[CAD] Nothing to toggle: single view with no saved arrangement.")
            }
        case "?":
            printVPortsConfig(engine: engine)
        case "3", "3V", "3H", "4", "SAVE", "RESTORE", "DELETE":
            print("[CAD] VPORTS \(arg) is not supported yet (2V/2H/SINGLE/JOIN/TOGGLE only).")
        default:
            print("[CAD] VPORTS options: 2V  2H  SINGLE  JOIN  TOGGLE  ?")
            printVPortsConfig(engine: engine)
        }
    }

    private func printVPortsConfig(engine: PhrostEngine) {
        let leaves = engine.mainPanes.leaves()
        if !engine.mainPanes.isSplit {
            print("[CAD] Single viewport.")
            return
        }
        print("[CAD] \(leaves.count) viewports:")
        for (i, leaf) in leaves.enumerated() {
            guard case .leaf(let id, let tabID) = leaf else { continue }
            let name = tabID.flatMap { engine.tabManager.tab(for: $0)?.displayName } ?? "(empty)"
            let mark = id == engine.mainPanes.focusedLeafID ? "*" : " "
            print("[CAD]  [\(i + 1)]\(mark) \(name)")
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
        case "VIEW", "V", "VIEWS":
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
        case "LAYOUT", "SHEET", "LO":
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
        isSelectingObjects = false
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

    // MARK: - Dash-command helpers (-HATCH / -LAYER)

    /// Interactive `-HATCH [pattern] [scale] [angle]`: bare starts the
    /// hatch picker; with args the values are validated, preset on a fresh
    /// `HatchCommand`, and the same pick flow starts.
    private func startDashHatchCommand(text: String, upper: String, engine: PhrostEngine) {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var pattern: String? = nil
        var scale: Float? = nil
        var angle: Float? = nil
        if tokens.count > 1 {
            pattern = tokens[1]
            let key = pattern!.uppercased()
            let known = key == "SOLID"
                || DXFHatchGenerator.patternDefinition(for: key) != nil
            guard known else {
                print("[CAD] Unknown hatch pattern '\(tokens[1])'.")
                clearCommand()
                return
            }
        }
        if tokens.count > 2 {
            guard let s = Float(tokens[2]), s > 0 else {
                print("[CAD] -HATCH scale must be a positive number.")
                clearCommand()
                return
            }
            scale = s
        }
        if tokens.count > 3 {
            guard let a = Float(tokens[3]) else {
                print("[CAD] -HATCH angle must be a number.")
                clearCommand()
                return
            }
            angle = a
        }
        if tokens.count > 4 {
            print("[CAD] Usage: -HATCH [pattern] [scale] [angle]")
            clearCommand()
            return
        }
        let cmd = HatchCommand()
        cmd.preset(pattern: pattern, scale: scale, angle: angle)
        activeFeatureCommand = cmd
        cmd.start(engine: engine, processor: self)
    }

    /// Interactive `-LAYER` sub-keywords over the document layer APIs.
    /// Lock/Freeze/Thaw/Unlock wait for the 1C layer model (reported, not silent).
    private func runDashLayerCommand(text: String, upper: String, engine: PhrostEngine) {
        let args = String(text.dropFirst(upper.hasPrefix("-LAYER ") ? 7 : 4))
            .trimmingCharacters(in: .whitespaces)
        let tokens = args.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let verb = tokens.first?.uppercased() else {
            print("[CAD] -LAYER Make/Set/New/On/Off/Color/Ltype/LWeight <args>")
            clearCommand()
            return
        }
        let doc = engine.document
        func needName(_ i: Int) -> String? {
            guard tokens.count > i, !tokens[i].isEmpty else {
                print("[CAD] -LAYER \(verb) requires a layer name.")
                clearCommand()
                return nil
            }
            return tokens[i]
        }
        switch verb {
        case "M", "MAKE":
            guard let name = needName(1) else { return }
            guard doc.findLayer(named: name) == nil else {
                print("[CAD] A layer named '\(name)' already exists.")
                clearCommand()
                return
            }
            let layer = Layer(name: name)
            doc.addLayer(layer)
            doc.activeLayerID = layer.handle
            print("[CAD] Layer '\(name)' created and set current.")
            clearCommand()
        case "S", "SET":
            guard let name = needName(1) else { return }
            guard let layer = doc.findLayer(named: name) else {
                print("[CAD] Layer '\(name)' not found.")
                clearCommand()
                return
            }
            doc.activeLayerID = layer.handle
            print("[CAD] Current layer set to '\(layer.name)'.")
            clearCommand()
        case "N", "NEW":
            guard let name = needName(1) else { return }
            guard doc.findLayer(named: name) == nil else {
                print("[CAD] A layer named '\(name)' already exists.")
                clearCommand()
                return
            }
            doc.addLayer(Layer(name: name))
            print("[CAD] Layer '\(name)' created.")
            clearCommand()
        case "ON":
            guard let name = needName(1) else { return }
            guard let layer = doc.findLayer(named: name) else {
                print("[CAD] Layer '\(name)' not found.")
                clearCommand()
                return
            }
            doc.setLayerVisible(layer.handle, visible: true)
            print("[CAD] Layer '\(layer.name)' turned on.")
            clearCommand()
        case "OFF":
            guard let name = needName(1) else { return }
            guard let layer = doc.findLayer(named: name) else {
                print("[CAD] Layer '\(name)' not found.")
                clearCommand()
                return
            }
            doc.setLayerVisible(layer.handle, visible: false)
            print("[CAD] Layer '\(layer.name)' turned off.")
            clearCommand()
        case "C", "COLOR":
            guard tokens.count >= 3 else {
                print("[CAD] -LAYER Color <aci|r,g,b> <name>")
                clearCommand()
                return
            }
            guard let layer = doc.findLayer(named: tokens[2]) else {
                print("[CAD] Layer '\(tokens[2])' not found.")
                clearCommand()
                return
            }
            let spec = tokens[1].uppercased()
            let color: ColorRGBA
            if spec.contains(",") {
                let parts = spec.split(separator: ",").compactMap {
                    UInt8($0.trimmingCharacters(in: .whitespaces))
                }
                guard parts.count == 3 else {
                    print("[CAD] Color must be ACI 1-255 or R,G,B.")
                    clearCommand()
                    return
                }
                color = ColorRGBA(r: parts[0], g: parts[1], b: parts[2])
            } else if let aci = Int32(spec), aci >= 1, aci <= 255 {
                color = DXFColorTable.aciToRGBA(aci, color24: -1)
            } else {
                print("[CAD] Color must be ACI 1-255 or R,G,B.")
                clearCommand()
                return
            }
            doc.setLayerColor(layer.handle, color: color)
            print("[CAD] Layer '\(layer.name)' color updated.")
            clearCommand()
        case "LT", "LTYPE":
            guard tokens.count >= 3 else {
                print("[CAD] -LAYER Ltype <linetype> <name>")
                clearCommand()
                return
            }
            guard let layer = doc.findLayer(named: tokens[2]) else {
                print("[CAD] Layer '\(tokens[2])' not found.")
                clearCommand()
                return
            }
            doc.setLayerLineType(layer.handle, lineType: tokens[1].uppercased())
            print("[CAD] Layer '\(layer.name)' linetype set to '\(tokens[1].uppercased())'.")
            clearCommand()
        case "LW", "LWEIGHT":
            guard tokens.count >= 3, let weight = Double(tokens[1]), weight >= 0 else {
                print("[CAD] -LAYER LWeight <mm> <name>")
                clearCommand()
                return
            }
            guard let layer = doc.findLayer(named: tokens[2]) else {
                print("[CAD] Layer '\(tokens[2])' not found.")
                clearCommand()
                return
            }
            doc.setLayerLineWeight(layer.handle, lineWeight: weight)
            print("[CAD] Layer '\(layer.name)' lineweight set to \(weight) mm.")
            clearCommand()
        case "LCK", "ULK", "LOCK", "UNLOCK", "FRZ", "THW", "FREEZE", "THAW":
            print("[CAD] -LAYER \(verb) needs layer lock/freeze (Phase 1C).")
            clearCommand()
        default:
            print("[CAD] -LAYER Make/Set/New/On/Off/Color/Ltype/LWeight <args>")
            clearCommand()
        }
    }

    // MARK: - Command Helpers

    /// `UNDO`/`U` command path. Identical to the Cmd/Ctrl+Z shortcut, which
    /// goes straight to `document.undo()`; kept here so the behaviour (and the
    /// user feedback) can never drift between the two entry points.
    private func performUndo(engine: PhrostEngine, steps: Int) {
        let available = engine.document.undoManager.undoDepth
        guard available > 0 else {
            print("[CAD] Nothing to undo.")
            return
        }
        let count = min(steps, available)
        for _ in 0..<count { engine.document.undo() }
        print("[CAD] Undo \(count == 1 ? "1 step" : "\(count) steps")"
            + (available > count ? " (\(available - count) more available)" : ""))
    }

    /// `REDO` command path. Mirror of `performUndo(engine:steps:)`.
    private func performRedo(engine: PhrostEngine, steps: Int) {
        let available = engine.document.undoManager.redoDepth
        guard available > 0 else {
            print("[CAD] Nothing to redo.")
            return
        }
        let count = min(steps, available)
        for _ in 0..<count { engine.document.redo() }
        print("[CAD] Redo \(count == 1 ? "1 step" : "\(count) steps")"
            + (available > count ? " (\(available - count) more available)" : ""))
    }

    // MARK: - PDF export file names

    /// Default file name offered by the PDFEXPORT save dialog.
    ///
    /// SDL's save dialog does not append the selected filter's extension, so
    /// the name must already carry `.pdf`: an extensionless URL falls through
    /// to the DXF branch in `TabManager` and writes DXF bytes to what the
    /// user believes is a PDF. Matching is case-insensitive and already-suffixed
    /// names are not doubled.
    static func pdfExportDefaultName(for displayName: String?) -> String {
        var base = (displayName ?? "untitled").trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = "untitled" }
        for ext in [".dxf", ".dwg", ".eab", ".pdf"] {
            if base.lowercased().hasSuffix(ext) {
                base = String(base.dropLast(ext.count))
                break
            }
        }
        return base + ".pdf"
    }

    /// Normalize a raw save-dialog URL from the PDFEXPORT flow. If SDL returned
    /// the name without an extension (or with a non-PDF one), append `.pdf` so
    /// the save pipeline routes to `PDFExporter` instead of `DXFExporter`.
    static func pdfExportTargetURL(from url: URL) -> URL {
        url.pathExtension.lowercased() == "pdf" ? url : url.appendingPathExtension("pdf")
    }

    /// Show the native file-save dialog and, on confirmation, save the active tab.
    private func showNativeSaveDialog(engine eng: PhrostEngine) {
        let defaultName = eng.tabManager.activeTab?.displayName ?? "untitled"
        let dxfVersion = eng.tabManager.activeTab?.dxfVersion ?? .r2018
        NativeFileDialog.showSaveDialog(
            window: eng.dialogParentWindow,
            filters: [
                NativeFileDialog.Filter(label: "DXF Drawing", extensions: ["dxf"]),
                NativeFileDialog.Filter(label: "Zephyr Drawing", extensions: ["eab"]),
                NativeFileDialog.Filter(label: "PDF Document", extensions: ["pdf"]),
                NativeFileDialog.Filter(label: "All Files", extensions: ["*"])
            ],
            defaultName: defaultName
        ) { [weak eng] url in
            guard let eng, let url else { return }
            eng.tabManager.startSaveActiveTabAs(url: url, dxfVersion: dxfVersion)
        }
    }

    internal func startCommand(_ name: String, prompt: String, selectingObjects: Bool = false) {
        activeCommand = name
        commandPrompt = prompt
        commandRefPoint = nil
        isSelectingObjects = selectingObjects
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

    internal func handleObjectSelectionClick(worldX: Double, worldY: Double) {
        guard let engine = engine else { return }
        let threshold = 8.0 / max(engine.camera.zoom, 0.001)
        guard let handle = engine.cadSelection.hitTest(
            worldX: worldX,
            worldY: worldY,
            document: engine.document,
            threshold: threshold,
            simplifyComplexBlocks: engine.simplifyComplexBlocks
        ) else {
            return
        }

        let shiftHeld = (engine.io != nil) ? engine.io.pointee.KeyShift : false
        if shiftHeld {
            engine.cadSelection.removeFromSelection(handle)
        } else {
            engine.cadSelection.addToSelection(handle)
        }
        updateObjectSelectionPrompt()
    }

    internal func updateObjectSelectionPrompt() {
        guard let cmd = activeCommand else { return }
        let count = engine?.cadSelection.selectedCount ?? 0
        let countSuffix = count > 0 ? " (\(count) selected)" : ""
        let action: String
        switch cmd {
        case "MOVE": action = "move"
        case "ROTATE": action = "rotate"
        case "SCALE": action = "scale"
        case "COPY": action = "copy"
        case "ERASE": action = "erase"
        case "COPYCLIP": action = "copy to clipboard"
        case "COPYBASE": action = "copy with base point"
        default: action = cmd.lowercased()
        }
        commandPrompt = "Select objects to \(action), then press Enter\(countSuffix)"
    }

    public func confirmObjectSelection() {
        guard isSelectingObjects else { return }
        guard let engine = engine, engine.cadSelection.hasSelection else {
            print("[CAD] No objects selected.")
            clearCommand()
            return
        }
        isSelectingObjects = false
        switch activeCommand {
        case "MOVE":
            commandPrompt = "Select base point"
        case "ROTATE":
            commandPrompt = "Pick rotation angle or drag"
        case "SCALE":
            commandPrompt = "Pick scale factor or drag"
        case "COPY":
            let result = engine.document.duplicateEntities(
                handles: engine.cadSelection.selectedHandles)
            for newBlock in result.clonedBlocks {
                engine.document.addBlock(newBlock)
            }
            var newHandles = Set<UUID>()
            for entity in result.entities {
                engine.document.addEntity(entity)
                newHandles.insert(entity.handle)
            }
            engine.cadSelection.clearSelection()
            for h in newHandles {
                engine.cadSelection.addToSelection(h)
            }
            activeCommand = "MOVE"
            commandPrompt = "Select base point"
            print("[CAD] Copied \(newHandles.count) entities. Specify destination.")
        case "ERASE":
            engine.deleteSelected()
            clearCommand()
        case "COPYCLIP":
            captureToClipboard(engine: engine)
            print("[CAD] Copied \(engine.cadSelection.selectedHandles.count) entities to clipboard.")
            clearCommand()
        case "COPYBASE":
            commandPrompt = "Specify base point"
        default:
            clearCommand()
        }
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
                dimensionMetadata: entity.dimensionMetadata,
                leaderData: entity.leaderData,
                arrayData: entity.arrayData,
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
