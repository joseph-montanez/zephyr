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

    public init(
        canonicalName: String,
        aliases: [String] = [],
        category: CommandCategory,
        syntax: String = "",
        description: String = "",
        isReservedStub: Bool = false
    ) {
        self.canonicalName = canonicalName.uppercased()
        self.aliases = aliases.map { $0.uppercased() }
        self.category = category
        self.syntax = syntax
        self.description = description
        self.isReservedStub = isReservedStub
    }

    /// Descriptor form, for seeding the S1 autocomplete registry.
    public var descriptor: CommandDescriptor {
        CommandDescriptor(
            canonicalName: canonicalName,
            aliases: aliases,
            category: category,
            syntax: syntax,
            description: description)
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
            description: "Manage dimension styles",
            isReservedStub: true),
        CADCommandAliasEntry(
            canonicalName: "DRAW", aliases: ["TOOLS"], category: .draw,
            description: "Open the draw tools palette"),
        CADCommandAliasEntry(
            canonicalName: "PENSTROKE", aliases: ["PSTROKE"],
            category: .draw,
            description: "Draw with tablet pen capturing pressure and tilt per vertex"),
        CADCommandAliasEntry(
            canonicalName: "PSPACE", aliases: ["PS"], category: .view,
            description: "Switch to paper space",
            isReservedStub: true),
        CADCommandAliasEntry(
            canonicalName: "CLIP", category: .modify,
            description: "Clip blocks, raster images, and PDF underlays"),
        CADCommandAliasEntry(
            canonicalName: "CENTERLINE", aliases: ["CL"], category: .draw,
            description: "Draw a centerline between two lines",
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
            canonicalName: "LAYOUT", aliases: ["SHEET", "LO"], category: .view,
            syntax: "[name|index]",
            description: "Select or cycle imported DXF sheet layouts"),
        CADCommandAliasEntry(
            canonicalName: "INSERT", aliases: ["I", "-I", "-INSERT"],
            category: .block,
            description: "Insert a block or drawing file as a block reference"),
        CADCommandAliasEntry(
            canonicalName: "GRADIENT", aliases: ["GD"], category: .draw,
            description: "Fill a closed boundary with a gradient"),
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
