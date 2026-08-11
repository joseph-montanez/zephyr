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
            factory: { ExplodeArrayCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "MATCHPROP",
            aliases: ["MA", "MATCH"],
            factory: { MatchPropCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "TORIENT",
            aliases: ["TO", "TEXTO"],
            factory: { TextOrientCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "SPLINEEDIT",
            aliases: ["SPE"],
            factory: { SplineEditCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "CLIP",
            aliases: ["CL"],
            descriptor: CommandDescriptor(
                canonicalName: "CLIP",
                aliases: ["CL"],
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
            name: "POLYLINE",
            aliases: ["PL", "PLINE"],
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
            name: "RECTANGLE",
            aliases: ["REC", "RECT"],
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
            name: "RAY",
            aliases: ["R"],
            factory: { RayCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "DRAW",
            aliases: ["D", "TOOLS"],
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
            name: "TEXT",
            aliases: ["T", "DTEXT", "MTEXT"],
            factory: { TextCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "IMAGE",
            aliases: ["IMG", "IM"],
            factory: { ImageCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "DDEDIT",
            aliases: ["ED"],
            factory: { DDEditCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "STYLE",
            aliases: ["ST"],
            factory: { StyleCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "TABLE",
            aliases: ["DT", "DATATABLE"],
            factory: { DataTableCommand() }
        )
        engine.commandProcessor.registerFeatureCommand(
            name: "MEASURE",
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
            aliases: ["DJO", "DIMJOG"],
            factory: { DimJoggedCommand() }
        )

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
