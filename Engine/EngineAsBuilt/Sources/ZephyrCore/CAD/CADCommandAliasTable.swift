import Foundation

// =========================================================================
// MARK: - CADCommandAliasTable
//
// Single declarative source for AutoCAD LT command/alias alignment
// (Phase 0 of plans/autocad-lt-command-alignment.md).
//
// Why this exists: command names are resolved on four surfaces that have
// already drifted apart — S1 autocomplete descriptors, the S2 legacy
// `executeCommand` switch, the S3 feature-command registry, and the S4
// scripted `(command ...)` set. `RECTANG`, `REDRAW` and `REGEN` were
// scripted-only, `TABLE` executed but was invisible to autocomplete, and
// `R` meant ROTATE in S1/S2 while S3 bound it to RAY.
//
// This table seeds S1 descriptors (via `registerFeatureCommand` synthesis
// when a registration passes no explicit descriptor) and is asserted by
// `CommandAliasParityTests`. Reserved stubs (`isReservedStub`) are known
// LT names whose commands land in a later phase; typing one reports
// "not implemented yet" instead of running a colliding Zephyr command.
// =========================================================================

/// One row of the canonical alias table.
public struct CADCommandAliasEntry: Sendable {
    public let canonicalName: String
    public let aliases: [String]
    public let category: CommandCategory
    public let syntax: String
    public let description: String
    /// True when this is a known LT name with no implementation yet.
    /// Stubs are discoverable (autocomplete) but never execute anything.
    public let isReservedStub: Bool
    public let bareEnterExecutes: Bool

    public init(
        canonicalName: String,
        aliases: [String] = [],
        category: CommandCategory,
        syntax: String = "",
        description: String = "",
        isReservedStub: Bool = false,
        bareEnterExecutes: Bool = false
    ) {
        self.canonicalName = canonicalName.uppercased()
        self.aliases = aliases.map { $0.uppercased() }
        self.category = category
        self.syntax = syntax
        self.description = description
        self.isReservedStub = isReservedStub
        self.bareEnterExecutes = bareEnterExecutes
    }

    /// Descriptor form, for seeding the S1 autocomplete registry.
    public var descriptor: CommandDescriptor {
        CommandDescriptor(
            canonicalName: canonicalName,
            aliases: aliases,
            category: category,
            syntax: syntax,
            description: description,
            bareEnterExecutes: bareEnterExecutes)
    }
}

public enum CADCommandAliasTable {
    /// Phase 0 rows: every remapped, split, flipped, or newly-aliased
    /// command, plus reserved stubs for commands landing in later phases.
    public static let entries: [CADCommandAliasEntry] = [
        CADCommandAliasEntry(
            canonicalName: "AREA", aliases: ["AA"], category: .draw,
            description: "Calculate area and perimeter of closed regions"),
        CADCommandAliasEntry(
            canonicalName: "MTEXT", aliases: ["MT", "T"], category: .draw,
            description: "Place multiline text"),
        CADCommandAliasEntry(
            canonicalName: "TEXT", aliases: ["DTEXT", "DT"], category: .draw,
            description: "Place single-line text"),
        CADCommandAliasEntry(
            canonicalName: "TEXTEDIT", aliases: ["DDEDIT", "ED", "TEDIT"],
            category: .modify,
            description: "Edit text, multiline text, and attribute values"),
        CADCommandAliasEntry(
            canonicalName: "TABLE", aliases: ["TB", "DATATABLE"],
            category: .draw,
            description: "Insert a data table"),
        CADCommandAliasEntry(
            canonicalName: "SHEETLISTTABLE", aliases: [],
            category: .draw,
            description: "Insert the current sheet set's sheet list table"),
        CADCommandAliasEntry(
            canonicalName: "REDRAW", aliases: ["R"], category: .view,
            description: "Refresh the viewport display"),
        CADCommandAliasEntry(
            canonicalName: "REGEN", category: .view,
            description: "Regenerate the drawing from its database"),
        CADCommandAliasEntry(
            canonicalName: "ROTATE", aliases: ["RO"], category: .modify,
            description: "Rotate selected entities around a base point"),
        CADCommandAliasEntry(
            canonicalName: "SCALE", aliases: ["SC"], category: .modify,
            description: "Scale selected entities from a base point"),
        CADCommandAliasEntry(
            canonicalName: "STRETCH", aliases: ["S"], category: .modify,
            description: "Stretch vertices inside a crossing window",
            isReservedStub: true),
        CADCommandAliasEntry(
            canonicalName: "DIMSTYLE", aliases: ["D", "DST"],
            category: .settings,
            description: "Manage dimension styles"),
        CADCommandAliasEntry(
            canonicalName: "-DIMSTYLE", aliases: [],
            category: .settings,
            description: "Set the current dimension style (command-line)"),
        CADCommandAliasEntry(
            canonicalName: "PAGESETUP", aliases: [],
            category: .settings,
            description: "Manage page setups for the active layout"),
        CADCommandAliasEntry(
            canonicalName: "PLOT", aliases: ["PRINT"],
            category: .draw,
            description: "Plot the active layout to PDF (page setup)"),
        CADCommandAliasEntry(
            canonicalName: "PREVIEW", aliases: [],
            category: .view,
            description: "Preview the active layout as plotted"),
        CADCommandAliasEntry(
            canonicalName: "PUBLISH", aliases: [],
            category: .draw,
            description: "Batch-publish drawing sheets to PDF"),
        CADCommandAliasEntry(
            canonicalName: "+PUBLISH", aliases: [],
            category: .draw,
            description: "Batch-publish, preloading a sheet list file"),
        CADCommandAliasEntry(
            canonicalName: "-PUBLISH", aliases: [],
            category: .draw,
            description: "Publish a sheet list file from the command line (foreground, CSV log)"),
        CADCommandAliasEntry(
            canonicalName: "NEWSHEETSET", aliases: [],
            category: .draw,
            description: "Create a new sheet set"),
        CADCommandAliasEntry(
            canonicalName: "OPENSHEETSET", aliases: [],
            category: .draw,
            description: "Open a sheet set data file"),
        CADCommandAliasEntry(
            canonicalName: "SHEETSET", aliases: ["SSM"],
            category: .draw,
            description: "Show the Sheet Set Manager"),
        CADCommandAliasEntry(
            canonicalName: "SHEETSETHIDE", aliases: [],
            category: .draw,
            description: "Hide the Sheet Set Manager"),
        CADCommandAliasEntry(
            canonicalName: "-PUBLISHSET", aliases: [],
            category: .draw,
            description: "Publish a sheet set to PDF from the command line"),
        CADCommandAliasEntry(
            canonicalName: "-PAGESETUP", aliases: [],
            category: .settings,
            description: "Assign a page setup from the command line"),
        CADCommandAliasEntry(
            canonicalName: "-PLOT", aliases: [],
            category: .draw,
            description: "Configure and run a plot from the command line"),
        CADCommandAliasEntry(
            canonicalName: "PSETUPIN", aliases: [],
            category: .settings,
            description: "Import page setups from another drawing"),
        CADCommandAliasEntry(
            canonicalName: "-PSETUPIN", aliases: [],
            category: .settings,
            description: "Import page setups from the command line"),
        CADCommandAliasEntry(
            canonicalName: "SCALELISTEDIT", aliases: [],
            category: .settings,
            description: "Edit the drawing custom scale list"),
        CADCommandAliasEntry(
            canonicalName: "-SCALELISTEDIT", aliases: [],
            category: .settings,
            description: "Edit the drawing custom scale list (command line)"),
        CADCommandAliasEntry(
            canonicalName: "STYLESMANAGER", aliases: [],
            category: .settings,
            description: "Open the plot styles folder"),
        CADCommandAliasEntry(
            canonicalName: "PLOTTERMANAGER", aliases: [],
            category: .settings,
            description: "Open the plotters folder"),
        CADCommandAliasEntry(
            canonicalName: "DRAW", aliases: ["TOOLS"], category: .draw,
            description: "Open the draw tools palette"),
        CADCommandAliasEntry(
            canonicalName: "PENSTROKE", aliases: ["PSTROKE"],
            category: .draw,
            description: "Draw with tablet pen capturing pressure and tilt per vertex"),
        CADCommandAliasEntry(
            canonicalName: "PSPACE", aliases: ["PS"], category: .view,
            description: "Switch to paper space"),
        CADCommandAliasEntry(
            canonicalName: "MSPACE", aliases: ["MS"], category: .view,
            description: "Switch to model space"),
        CADCommandAliasEntry(
            canonicalName: "MVIEW", aliases: ["MV"], category: .view,
            description: "Create or control paper-space floating viewports"),
        CADCommandAliasEntry(
            canonicalName: "CHSPACE", aliases: [], category: .modify,
            description: "Move entities between paper and model space"),
        CADCommandAliasEntry(
            canonicalName: "CLIP", category: .modify,
            description: "Clip blocks, raster images, and PDF underlays"),
        CADCommandAliasEntry(
            canonicalName: "CENTERLINE", aliases: ["CL"], category: .draw,
            description: "Draw a centerline between two lines"),
        CADCommandAliasEntry(
            canonicalName: "CENTERMARK", aliases: ["CM"], category: .draw,
            description: "Draw a center cross for a circle or arc"),
        CADCommandAliasEntry(
            canonicalName: "DIMCENTER", aliases: ["DCE"], category: .draw,
            description: "Draw a center mark for a circle or arc"),
        CADCommandAliasEntry(
            canonicalName: "DIMREASSOCIATE", aliases: ["DRE"], category: .draw,
            description: "Re-point a dimension at new extension origins and re-measure"),
        CADCommandAliasEntry(
            canonicalName: "DIMDISASSOCIATE", aliases: ["DDA"], category: .draw,
            description: "Drop associativity from dimensions (no-op: dimensions store snapshots)"),
        CADCommandAliasEntry(
            canonicalName: "DIMEDIT", aliases: ["DED"], category: .draw,
            description: "Move, replace, rotate, or oblique dimension text"),
        CADCommandAliasEntry(
            canonicalName: "DIMTEDIT", category: .draw,
            description: "Move or rotate dimension text along the dimension line"),
        CADCommandAliasEntry(
            canonicalName: "DIMBREAK", category: .draw,
            description: "Break dimension lines around crossing geometry"),
        CADCommandAliasEntry(
            canonicalName: "DIMSPACE", category: .draw,
            description: "Space dimension lines evenly or align them"),
        CADCommandAliasEntry(
            canonicalName: "FIND", category: .modify,
            description: "Find and replace text across the drawing"),
        CADCommandAliasEntry(
            canonicalName: "TEXTALIGN", aliases: ["TA"], category: .modify,
            description: "Align or distribute text along a baseline"),
        CADCommandAliasEntry(
            canonicalName: "TXT2MTXT", category: .modify,
            description: "Merge single-line texts into one mtext"),
        CADCommandAliasEntry(
            canonicalName: "FIELD", category: .draw,
            description: "Insert a live-updating field value"),
        CADCommandAliasEntry(
            canonicalName: "SELECTSIMILAR", category: .modify,
            description: "Select objects matching a reference (SELECTSIMILARMODE)"),
        CADCommandAliasEntry(
            canonicalName: "QSELECT", category: .modify,
            description: "Select objects by type, property, and operator"),
        CADCommandAliasEntry(
            canonicalName: "FILTER", aliases: ["FI"], category: .modify,
            description: "Select objects by combined property criteria"),
        CADCommandAliasEntry(
            canonicalName: "PURGE", aliases: ["PU"], category: .modify,
            description: "Remove unused definitions (confirms first)"),
        CADCommandAliasEntry(
            canonicalName: "-PURGE", category: .modify,
            description: "Remove unused definitions without confirming"),
        CADCommandAliasEntry(
            canonicalName: "SPELL", aliases: ["SP"], category: .modify,
            description: "Spell-check drawing text (unavailable: no platform checker reachable)",
            isReservedStub: true),
        CADCommandAliasEntry(
            canonicalName: "AALINES", category: .view,
            description: "Toggle anti-aliased line rendering on/off"),
        CADCommandAliasEntry(
            canonicalName: "RAY", category: .draw,
            description: "Draw a ray from a start point in a direction"),
        CADCommandAliasEntry(
            canonicalName: "PLINE", aliases: ["POLYLINE", "PL"],
            category: .draw,
            description: "Draw a multi-segment polyline"),
        CADCommandAliasEntry(
            canonicalName: "RECTANG",
            aliases: ["RECTANGLE", "REC", "RECT"], category: .draw,
            description: "Draw a rectangle by two opposite corners"),
        CADCommandAliasEntry(
            canonicalName: "SPLINEDIT", aliases: ["SPLINEEDIT", "SPE"],
            category: .modify,
            description: "Edit an existing spline (reverse, convert to polyline, etc.)"),
        CADCommandAliasEntry(
            canonicalName: "PROPERTIES",
            aliases: ["PROPS", "PR", "CH", "MO"], category: .view,
            description: "Show/hide the properties panel"),
        CADCommandAliasEntry(
            canonicalName: "EXPORTPDF", aliases: ["PDFEXPORT", "EPDF"],
            category: .draw,
            description: "Export the current drawing to a PDF file"),
        CADCommandAliasEntry(
            canonicalName: "MEASURE", aliases: ["ME"], category: .draw,
            description: "Place points or blocks at measured intervals along an object"),
        CADCommandAliasEntry(
            canonicalName: "DIMJOGGED", aliases: ["DJO", "DIMJOG", "JOG"],
            category: .draw,
            description: "Jogged radius dimension for large radii"),
        CADCommandAliasEntry(
            canonicalName: "DIMCONTINUE", aliases: ["DCO"],
            category: .draw,
            description: "Chain dimensions from the previous extension origin"),
        CADCommandAliasEntry(
            canonicalName: "DIMBASELINE", aliases: ["DBA"],
            category: .draw,
            description: "Stack dimensions from a shared base origin"),
        CADCommandAliasEntry(
            canonicalName: "DIM", aliases: [],
            category: .draw,
            description: "Dimension the selection with the matching type"),
        CADCommandAliasEntry(
            canonicalName: "BLOCK", aliases: ["B", "BMAKE"],
            category: .block,
            syntax: "<name>",
            description: "Create a new block from selected entities"),
        CADCommandAliasEntry(
            canonicalName: "XREF",
            aliases: ["XR", "ER", "EXTERNALREFERENCES"], category: .block,
            description: "Show/hide the External References palette"),
        CADCommandAliasEntry(
            canonicalName: "IMAGEATTACH", aliases: ["IAT"], category: .block,
            description: "Attach a raster image as a live reference"),
        CADCommandAliasEntry(
            canonicalName: "UNITS", aliases: ["UN", "UNIT", "DDUNITS"],
            category: .settings, syntax: "[mm|cm|m|in|ft|yd]",
            description: "Set or display the drawing base unit"),
        CADCommandAliasEntry(
            canonicalName: "VIEW", aliases: ["V", "VIEWS"], category: .view,
            syntax: "[name|index]",
            description: "List, select, or cycle model and sheet views"),
        CADCommandAliasEntry(
            canonicalName: "LAYOUT", aliases: ["SHEET", "LO", "-LAYOUT"], category: .view,
            syntax: "[Copy/Delete/New/Template/Rename/SAveas/Set/?]",
            description: "Manage sheet layouts",
            bareEnterExecutes: true),
        CADCommandAliasEntry(
            canonicalName: "INSERT", aliases: ["I", "-I", "-INSERT"],
            category: .block,
            description: "Insert a block or drawing file as a block reference"),
        CADCommandAliasEntry(
            canonicalName: "GRADIENT", aliases: ["GD"], category: .draw,
            description: "Fill a closed boundary with a gradient"),
        CADCommandAliasEntry(
            canonicalName: "XLINE", aliases: ["XL"], category: .draw,
            description: "Draw an infinite construction line through a point"),
        CADCommandAliasEntry(
            canonicalName: "POLYGON", aliases: ["POL"], category: .draw,
            description: "Draw a regular polygon (sides, center, radius or edge)"),
        CADCommandAliasEntry(
            canonicalName: "BOUNDARY", aliases: ["BO"], category: .draw,
            description: "Create a closed region from an interior pick point"),
        CADCommandAliasEntry(
            canonicalName: "POINT", aliases: ["PO"], category: .draw,
            description: "Place point entities (display follows PDMODE/PDSIZE)"),
        CADCommandAliasEntry(
            canonicalName: "PTYPE", aliases: ["DDPTYPE"], category: .settings,
            description: "Set point display style (PDMODE) and size (PDSIZE)"),
        CADCommandAliasEntry(
            canonicalName: "DONUT", aliases: ["DO"], category: .draw,
            description: "Draw a filled ring (inside/outside diameters, FILLMODE honored)"),
        CADCommandAliasEntry(
            canonicalName: "DIST", aliases: ["DI"], category: .draw,
            description: "Report distance, angles, and deltas between two points"),
        CADCommandAliasEntry(
            canonicalName: "ID", category: .draw,
            description: "Report the coordinates of a picked point"),
        CADCommandAliasEntry(
            canonicalName: "LIST", aliases: ["LI", "LS"], category: .draw,
            description: "List type, layer, and geometry of selected entities"),
        CADCommandAliasEntry(
            canonicalName: "LAYOFF", category: .layer,
            description: "Turn off the layer of a selected object (pick-driven)"),
        CADCommandAliasEntry(
            canonicalName: "LAYON", category: .layer,
            description: "Turn on the layer of a selected object (pick-driven)"),
        CADCommandAliasEntry(
            canonicalName: "LAYISO", category: .layer,
            description: "Isolate the layer of a selected object; others hidden or faded"),
        CADCommandAliasEntry(
            canonicalName: "LAYUNISO", category: .layer,
            description: "Restore layers hidden by the most recent LAYISO"),
        CADCommandAliasEntry(
            canonicalName: "LAYMCUR", aliases: ["AI_MOLC"], category: .layer,
            description: "Make the layer of a selected object current"),
        CADCommandAliasEntry(
            canonicalName: "LAYFRZ", aliases: ["LAYFREEZE"], category: .layer,
            description: "Freeze a layer by name"),
        CADCommandAliasEntry(
            canonicalName: "LAYTHW", aliases: ["LAYTHAW"], category: .layer,
            description: "Thaw a layer by name"),
        CADCommandAliasEntry(
            canonicalName: "LAYLCK", aliases: ["LAYLOCK"], category: .layer,
            description: "Lock a layer by name"),
        CADCommandAliasEntry(
            canonicalName: "LAYULK", aliases: ["LAYUNLOCK"], category: .layer,
            description: "Unlock a layer by name"),
        CADCommandAliasEntry(
            canonicalName: "LAYDEL", aliases: ["LAYDELETE"], category: .layer,
            description: "Delete a layer and its entities by name"),
        CADCommandAliasEntry(
            canonicalName: "LAYMRG", aliases: ["LAYMERGE"], category: .layer,
            description: "Merge source layers into a target layer, then delete the sources"),
        CADCommandAliasEntry(
            canonicalName: "LAYWALK", category: .layer,
            description: "List layers, or isolate one layer to inspect it"),
        CADCommandAliasEntry(
            canonicalName: "COPYTOLAYER", category: .layer,
            description: "Copy selected entities onto another layer"),
        CADCommandAliasEntry(
            canonicalName: "VPLAYER", category: .layer,
            description: "Freeze or thaw layers in one paper-space viewport"),
        CADCommandAliasEntry(
            canonicalName: "LAYMCH", category: .layer,
            description: "Change selected entities to the layer of a picked destination object"),
        CADCommandAliasEntry(
            canonicalName: "GROUP", aliases: ["G"], category: .modify,
            description: "Create a lightweight named or unnamed object group",
            isReservedStub: true),
        CADCommandAliasEntry(
            canonicalName: "WBLOCK", aliases: ["W"], category: .block,
            description: "Write a block or entities to a drawing file",
            isReservedStub: true),
        CADCommandAliasEntry(
            canonicalName: "TOOLBAR", aliases: ["TO"], category: .view,
            description: "Show or hide the toolbar (ribbon)"),
        CADCommandAliasEntry(
            canonicalName: "TORIENT", aliases: ["TOR", "TEXTO"],
            category: .modify,
            description: "Rotate text individually to an absolute or most-readable angle"),
        CADCommandAliasEntry(
            canonicalName: "OSNAP", category: .settings,
            description: "Toggle running object snaps on/off (F3)"),
        CADCommandAliasEntry(
            canonicalName: "COMMANDLINE", aliases: ["CLI"], category: .view,
            description: "Show or hide the command line"),
        CADCommandAliasEntry(
            canonicalName: "CLEANSCREENON", category: .view,
            description: "Hide ribbon and panels to maximize the canvas"),
        CADCommandAliasEntry(
            canonicalName: "CLEANSCREENOFF", category: .view,
            description: "Restore ribbon and panels hidden by CLEANSCREENON"),
        CADCommandAliasEntry(
            canonicalName: "DRAWORDER", aliases: ["DR"], category: .modify,
            syntax: "[Above/Under/Front/Back]",
            description: "Change the draw order of selected entities"),
        CADCommandAliasEntry(
            canonicalName: "HATCHEDIT", aliases: ["HE"], category: .draw,
            description: "Edit the selected hatch"),
        CADCommandAliasEntry(
            canonicalName: "-HATCH", category: .draw,
            syntax: "[pattern] [scale] [angle]",
            description: "Fill a closed boundary from the command line"),
        CADCommandAliasEntry(
            canonicalName: "-TEXT", category: .draw,
            description: "Place single-line text from the command line"),
        CADCommandAliasEntry(
            canonicalName: "-LAYER", aliases: ["-LA"], category: .layer,
            syntax: "Make/Set/New/On/Off/Color/Ltype/LWeight <args>",
            description: "Manage layers from the command line"),
        CADCommandAliasEntry(
            canonicalName: "CHPROP", category: .modify,
            description: "Change color, layer, linetype, or lineweight of selected entities"),
        CADCommandAliasEntry(
            canonicalName: "CHANGE", category: .modify,
            description: "Change properties of selected entities (legacy form)"),
        CADCommandAliasEntry(
            canonicalName: "GEOMCONSTRAINT", aliases: ["GCON"],
            category: .modify,
            description: "Apply geometric constraints to lines (horizontal, vertical, coincident, parallel, perpendicular, equal, fix)"),
        CADCommandAliasEntry(
            canonicalName: "AUTOCONSTRAIN", category: .modify,
            description: "Infer and apply constraints to loose lines, then solve"),
        CADCommandAliasEntry(
            canonicalName: "DELCONSTRAINT", category: .modify,
            description: "Remove constraints from picked objects (ALL clears every constraint)"),
        CADCommandAliasEntry(
            canonicalName: "CONSTRAINTBAR", aliases: ["CBAR"],
            category: .modify,
            description: "Show or hide the constraint badges"),
    ]

    /// Entry for a canonical name (case-insensitive), if tabled.
    public static func entry(canonicalName name: String) -> CADCommandAliasEntry? {
        let upper = name.uppercased()
        return entries.first { $0.canonicalName == upper }
    }

    /// Feedback text when `name` is a reserved stub (matched by canonical
    /// name or alias), nil otherwise. Stubs never execute.
    public static func stubMessage(for name: String) -> String? {
        let upper = name.uppercased()
        guard let row = entries.first(where: {
            $0.isReservedStub
                && ($0.canonicalName == upper || $0.aliases.contains(upper))
        }) else { return nil }
        return "[CAD] \(row.canonicalName) is not implemented yet (reserved \(upper))."
    }
}
