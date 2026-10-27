import ZephyrCore
import Foundation
import ImGui

// MARK: - AppCommandRegistration
//
// Central registry for all built-in CAD commands exposed through the
// command processor. Each command is registered with its canonical name
// and a set of shorthand aliases (e.g., "LINE" with alias "L").
//
// Commands are instantiated lazily via factory closures when the user
// invokes them from the command line, toolbar, or draw palette.
//
// Registered commands:
//   LINE, POLYLINE, CIRCLE, ARC, RECTANGLE, ELLIPSE, HATCH, SPLINE, RAY
//   DRAW (opens the draw palette)
//   CLEANSPECKLES (utility command)

@MainActor
struct AppCommandRegistration {
    static func register(on engine: PhrostEngine) {
        // Utility command for cleaning up speckle artifacts in scanned DXF imports.
        engine.commandProcessor.registerFeatureCommand(
            name: "CLEANSPECKLES",
            aliases: ["CS", "SPECKLES"],
            factory: { CleanSpecklesCommand() }
        )

        // Toggle auto-contrast for 24-bit TrueColors and gradients in viewport.
        let autoContrastDescriptor = CommandDescriptor(
            canonicalName: "AUTOCONTRAST",
            aliases: ["CONTRAST", "TRUECOLORCONTRAST"],
            category: .settings,
            syntax: "[ON|OFF]",
            description: "Toggle auto-contrast clamping for 24-bit TrueColors and gradients"
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "AUTOCONTRAST",
            aliases: ["CONTRAST", "TRUECOLORCONTRAST"],
            descriptor: autoContrastDescriptor,
            factory: { AutoContrastCommand() }
        )

        // --- Modify commands ---
        engine.commandProcessor.registerFeatureCommand(
            name: "JOIN",
            aliases: ["J"],
            factory: { JoinCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "TRIM",
            aliases: ["TR"],
            factory: { TrimCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "FILLET",
            aliases: ["F"],
            factory: { FilletCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "CHAMFER",
            aliases: ["CHA", "BEVEL"],
            factory: { ChamferCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "OFFSET",
            aliases: ["O"],
            factory: { OffsetCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "OFFSETGAPTYPE",
            factory: { OffsetGapTypeCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "ARRAY",
            aliases: ["AR"],
            factory: { ArrayCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "ARRAYRECT",
            aliases: ["ARRAYR"],
            factory: { ArrayCommand(initialKind: .rectangular) }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "ARRAYPOLAR",
            aliases: ["ARRAYP"],
            factory: { ArrayCommand(initialKind: .polar) }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "ARRAYPATH",
            aliases: ["ARRAYPA"],
            factory: { ArrayCommand(initialKind: .path) }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "ARRAYEDIT",
            factory: { ArrayEditCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "ARRAYCLOSE",
            factory: { ArrayCloseCommand(commandLineOnly: false) }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "-ARRAYCLOSE",
            factory: { ArrayCloseCommand(commandLineOnly: true) }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "ARRAYCLASSIC",
            factory: {
                ArrayCommand(
                    forceAssociative: false,
                    allowedKinds: [.rectangular, .polar])
            }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "-ARRAY",
            factory: {
                ArrayCommand(
                    forceAssociative: false,
                    allowedKinds: [.rectangular, .polar])
            }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "ARRAYASSOCIATIVITY",
            factory: { ArrayAssociativityCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "ARRAYEDITSTATE",
            factory: { ArrayEditStateCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "ARRAYTYPE",
            factory: { ArrayTypeCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "EXPLODE",
            aliases: ["X"],
            factory: { ExplodeCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "MATCHPROP",
            aliases: ["MA", "MATCH"],
            factory: { MatchPropCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "CHPROP",
            factory: { ChangePropertiesCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "CHANGE",
            factory: { ChangePropertiesCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "TORIENT",
            aliases: ["TOR", "TEXTO"],
            factory: { TextOrientCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "SPLINEDIT",
            aliases: ["SPLINEEDIT", "SPE"],
            factory: { SplineEditCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "INSERT",
            aliases: ["I", "-I", "-INSERT"],
            descriptor: CommandDescriptor(
                canonicalName: "INSERT",
                aliases: ["I", "-I", "-INSERT"],
                category: .block,
                description: "Insert a block or drawing file as a block reference"),
            factory: { InsertCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "XATTACH",
            aliases: ["XA"],
            descriptor: CommandDescriptor(
                canonicalName: "XATTACH",
                aliases: ["XA"],
                category: .block,
                description: "Attach a drawing as an external reference"),
            factory: { XAttachCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "ATTACH",
            descriptor: CommandDescriptor(
                canonicalName: "ATTACH",
                category: .block,
                description: "Attach a drawing, image, or PDF as a live reference"),
            factory: { AttachCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "IMAGEATTACH",
            aliases: ["IAT"],
            descriptor: CommandDescriptor(
                canonicalName: "IMAGEATTACH",
                category: .block,
                description: "Attach a raster image as a live reference"),
            factory: { ImageAttachCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "PDFATTACH",
            descriptor: CommandDescriptor(
                canonicalName: "PDFATTACH",
                category: .block,
                description: "Attach a PDF page as a live underlay reference"),
            factory: { PdfAttachCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "-ATTACH",
            descriptor: CommandDescriptor(
                canonicalName: "-ATTACH",
                category: .block,
                description: "Attach a reference file from the command line"),
            factory: { MinusAttachCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "-XREF",
            descriptor: CommandDescriptor(
                canonicalName: "-XREF",
                category: .block,
                description: "Manage external references from the command line"),
            factory: { MinusXrefCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "XBIND",
            descriptor: CommandDescriptor(
                canonicalName: "XBIND",
                category: .block,
                description: "Bind one xref-dependent layer into the host"),
            factory: { XBindCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "CLIP",
            aliases: [],
            descriptor: CommandDescriptor(
                canonicalName: "CLIP",
                aliases: [],
                category: .modify,
                description: "Clip blocks, raster images, and PDF underlays"),
            factory: { ClipCommand() }
        )
        for variable in ["FRAME", "XCLIPFRAME", "IMAGEFRAME", "PDFFRAME"] {
            engine.commandProcessor.registerFeatureCommand(
                name: variable,
                descriptor: CommandDescriptor(
                    canonicalName: variable,
                    category: .settings,
                    syntax: "<0|1|2>",
                    description: "Control clipping boundary frame visibility"),
                factory: { ClipFrameVariableCommand(variable) }
            )
        }

        // --- Drawing commands ---
        // Each is a "feature command" that stays active for multi-step input
        // (e.g., LINE requires two clicks: start point then end point).
        engine.commandProcessor.registerFeatureCommand(
            name: "LINE",
            aliases: ["L"],
            factory: { LineCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "PLINE",
            aliases: ["POLYLINE", "PL"],
            factory: { PolylineCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "CIRCLE",
            aliases: ["C"],
            factory: { CircleCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "ARC",
            aliases: ["A"],
            factory: { ArcCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "RECTANG",
            aliases: ["RECTANGLE", "REC", "RECT"],
            factory: { RectangleCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "ELLIPSE",
            aliases: ["EL"],
            factory: { EllipseCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "HATCH",
            aliases: ["H", "BH"],
            factory: { HatchCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "REVCLOUD",
            aliases: ["REVC"],
            descriptor: CommandDescriptor(
                canonicalName: "REVCLOUD",
                aliases: ["REVC"],
                category: .draw,
                description: "Create or modify revision-cloud polylines"),
            factory: { RevCloudCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "REVCLOUDPROPERTIES",
            aliases: ["REVCLOUDPROP"],
            descriptor: CommandDescriptor(
                canonicalName: "REVCLOUDPROPERTIES",
                aliases: ["REVCLOUDPROP"],
                category: .modify,
                description: "Change the arc chord length of revision clouds"),
            factory: { RevCloudPropertiesCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "SPLINE",
            aliases: ["SPL"],
            factory: { SplineCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "PENSTROKE",
            aliases: ["PSTROKE"],
            factory: { PenStrokeCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "RAY",
            aliases: [],
            factory: { RayCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "XLINE",
            aliases: ["XL"],
            factory: { XlineCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "POLYGON",
            aliases: ["POL"],
            factory: { PolygonCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "BOUNDARY",
            aliases: ["BO"],
            factory: { BoundaryCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "-BOUNDARY",
            aliases: [],
            factory: { BoundaryCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "POINT",
            aliases: ["PO"],
            factory: { PointCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "PTYPE",
            aliases: ["DDPTYPE"],
            factory: { PTypeCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "DONUT",
            aliases: ["DO"],
            factory: { DonutCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "DRAW",
            aliases: ["TOOLS"],
            factory: { DrawPaletteCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "LEADER",
            aliases: ["LEAD"],
            factory: { LeaderCreateCommand(mode: .leader) }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "QLEADER",
            aliases: ["LE"],
            factory: { LeaderCreateCommand(mode: .qleader) }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "MLEADER",
            aliases: ["MLD"],
            factory: { LeaderCreateCommand(mode: .mleader) }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "MLEADEREDIT",
            aliases: ["MLE"],
            factory: { MLeaderEditCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "MLEADERALIGN",
            aliases: ["MLA"],
            factory: { MLeaderAlignCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "MLEADERCOLLECT",
            aliases: ["MLC"],
            factory: { MLeaderCollectCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "MLEADERSTYLE",
            aliases: ["MLS"],
            factory: { MLeaderStyleCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "MTEXT",
            aliases: ["MT", "T"],
            factory: { TextCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "TEXT",
            aliases: ["DTEXT", "DT"],
            factory: { TextCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "-TEXT",
            factory: { DashTextCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "IMAGE",
            aliases: ["IMG", "IM"],
            factory: { ImageCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "TEXTEDIT",
            aliases: ["DDEDIT", "ED", "TEDIT"],
            factory: { DDEditCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "STYLE",
            aliases: ["ST"],
            factory: { StyleCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "TABLE",
            aliases: ["TB", "DATATABLE"],
            factory: { DataTableCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "AREA",
            aliases: ["AA"],
            factory: { AreaCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "DIST",
            aliases: ["DI"],
            factory: { DistanceCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "ID",
            factory: { IdCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "LIST",
            aliases: ["LI", "LS"],
            factory: { ListCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "LAYOFF",
            factory: { LayerPickCommand(mode: .off) }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "LAYON",
            factory: { LayerPickCommand(mode: .on) }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "LAYISO",
            factory: { LayerPickCommand(mode: .isolate) }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "LAYUNISO",
            factory: { LayerPickCommand(mode: .unisolate) }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "LAYMCUR",
            aliases: ["AI_MOLC"],
            factory: { LayerPickCommand(mode: .makeCurrent) }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "GRADIENT",
            aliases: ["GD"],
            factory: { HatchCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "MEASURE",
            aliases: ["ME"],
            factory: { MeasureDivideCommand(operation: .measure) }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "DIVIDE",
            aliases: ["DIV"],
            factory: { MeasureDivideCommand(operation: .divide) }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "MEASUREGEOM",
            aliases: ["MEASUREGEOMETRY", "MEA", "MG"],
            factory: { MeasureGeomTool() }
        )

        // PDF import (cross-platform: PDFKit on Apple, PDFium on Windows/Linux).
        engine.commandProcessor.registerFeatureCommand(
            name: "PDFIMPORT",
            aliases: ["PDFI", "PDF"],
            factory: { PDFImportCommand() }
        )

        let revCloudVariables: [(String, RevCloudVariableCommand.Variable, String)] = [
            ("REVCLOUDCREATEMODE", .createMode, "Set the default revision-cloud creation mode"),
            ("REVCLOUDAPPROXARCLEN", .approximateArcLength, "Set the target revision-cloud arc chord length"),
            ("REVCLOUDMINARCLENGTH", .minimumArcLength, "Set the minimum revision-cloud arc chord length"),
            ("REVCLOUDMAXARCLENGTH", .maximumArcLength, "Set the maximum revision-cloud arc chord length"),
            ("REVCLOUDARCVARIANCE", .arcVariance, "Toggle varied revision-cloud arc chord lengths"),
            ("REVCLOUDGRIPS", .grips, "Toggle simplified revision-cloud grips"),
            ("REVCLOUDLAYER", .layer, "Set the layer used for new revision clouds"),
            ("DELOBJ", .deleteObject, "Control deletion of source objects during conversion")
        ]
        for (name, variable, description) in revCloudVariables {
            engine.commandProcessor.registerFeatureCommand(
                name: name,
                descriptor: CommandDescriptor(
                    canonicalName: name,
                    category: .settings,
                    syntax: "<value>",
                    description: description),
                factory: { RevCloudVariableCommand(variable) }
            )
        }

        // --- View commands ---
        engine.commandProcessor.registerFeatureCommand(
            name: "PAN",
            aliases: ["P"],
            factory: { PanCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "DVIEW",
            aliases: ["DV"],
            factory: { DViewCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "ZOOM",
            aliases: ["Z"],
            factory: { ZoomCommand() }
        )
        
        // --- Dimension commands ---
        engine.commandProcessor.registerFeatureCommand(
            name: "DIMLINEAR",
            aliases: ["DLI", "DIMLIN"],
            factory: { DimLinearCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "DIMALIGNED",
            aliases: ["DAL", "DIMALIGN"],
            factory: { DimAlignedCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "DIMRADIUS",
            aliases: ["DRA", "DIMRAD"],
            factory: { DimRadiusCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "DIMDIAMETER",
            aliases: ["DDI", "DIMDIA"],
            factory: { DimDiameterCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "DIMANGULAR",
            aliases: ["DAN", "DIMANG"],
            factory: { DimAngularCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "DIMARC",
            aliases: ["DAR", "DIMARCLENGTH"],
            factory: { DimArcLengthCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "DIMORDINATE",
            aliases: ["DOR", "DIMORD"],
            factory: { DimOrdinateCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "DIMJOGGED",
            aliases: ["DJO", "DIMJOG", "JOG"],
            factory: { DimJoggedCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "DIMSTYLE",
            aliases: ["D", "DST"],
            factory: { DimStyleCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "DIMCONTINUE",
            aliases: ["DCO"],
            factory: { DimChainCommand(mode: .cont) }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "DIMBASELINE",
            aliases: ["DBA"],
            factory: { DimChainCommand(mode: .base) }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "DIM",
            aliases: [],
            factory: { DimSmartCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "CENTERMARK",
            aliases: ["CM"],
            factory: { CenterMarkCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "DIMCENTER",
            aliases: ["DCE"],
            factory: { CenterMarkCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "CENTERLINE",
            aliases: ["CL"],
            factory: { CenterLineCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "DIMREASSOCIATE",
            aliases: ["DRE"],
            factory: { DimReassociateCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "DIMDISASSOCIATE",
            aliases: ["DDA"],
            factory: { DimDisassociateCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "DIMEDIT",
            aliases: ["DED"],
            factory: { DimEditCommand(mode: .dimedit) }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "DIMTEDIT",
            aliases: [],
            factory: { DimEditCommand(mode: .dimtedit) }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "DIMBREAK",
            aliases: [],
            factory: { DimBreakCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "DIMSPACE",
            aliases: [],
            factory: { DimSpaceCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "FIND",
            aliases: [],
            factory: { FindCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "TEXTALIGN",
            aliases: ["TA"],
            factory: { TextAlignCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "TXT2MTXT",
            aliases: [],
            factory: { Txt2MtxtCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "FIELD",
            aliases: [],
            factory: { FieldCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "SELECTSIMILAR",
            aliases: [],
            factory: { SelectSimilarCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "QSELECT",
            aliases: [],
            factory: { SelectFilterCommand(mode: .qselect) }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "FILTER",
            aliases: ["FI"],
            factory: { SelectFilterCommand(mode: .filter) }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "PURGE",
            aliases: ["PU"],
            factory: { PurgeCommand(mode: .confirm) }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "-PURGE",
            aliases: [],
            factory: { PurgeCommand(mode: .scripted) }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "AUDIT",
            aliases: [],
            factory: { AuditCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "RECOVER",
            aliases: [],
            factory: { RecoverCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "ISOLATEOBJECTS",
            aliases: [],
            factory: { IsolateCommand(mode: .isolate) }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "HIDEOBJECTS",
            aliases: [],
            factory: { IsolateCommand(mode: .hide) }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "UNISOLATEOBJECTS",
            aliases: [],
            factory: { IsolateCommand(mode: .unisolate) }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "GROUP",
            aliases: ["G"],
            factory: { GroupCommand(mode: .group) }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "UNGROUP",
            aliases: [],
            factory: { GroupCommand(mode: .ungroup) }
        )
        // PICKSTYLE group selection: one member in, whole selectable
        // group in. Resolves the active document per call (tabs switch).
        engine.cadSelection.groupExpansionProvider = { [weak engine] handle in
            guard let document = engine?.document else { return [handle] }
            return document.selectionExpansion(for: handle)
        }

        // ODA FileConverter installation (for DWG support).
        engine.commandProcessor.registerFeatureCommand(
            name: "INSTALLODA",
            aliases: ["ODAINSTALL"],
            factory: { InstallODACommand() }
        )

        // --- ALIGN (Move + Rotate + optional Scale) ---
        engine.commandProcessor.registerFeatureCommand(
            name: "ALIGN",
            aliases: ["AL"],
            factory: { AlignCommand() }
        )

        // Note: tool-mode commands (SELECT, MOVE, ROTATE, SCALE, PAN, ZOOM)
        // are registered inside PhrostEngine itself.
    }
}
