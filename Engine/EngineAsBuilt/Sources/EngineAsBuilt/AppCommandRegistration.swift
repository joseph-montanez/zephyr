import EngineAsBuiltCore
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
            name: "SPLINEEDIT",
            aliases: ["SPE"],
            factory: { SplineEditCommand() }
        )

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
            name: "MEASUREGEOM",
            aliases: ["MEASURE", "MEA", "MG"],
            factory: { MeasureGeomTool() }
        )

        // PDF import (cross-platform: PDFKit on Apple, PDFium on Windows/Linux).
        engine.commandProcessor.registerFeatureCommand(
            name: "PDFIMPORT",
            aliases: ["PDFI", "PDF"],
            factory: { PDFImportCommand() }
        )

        // --- View commands ---
        engine.commandProcessor.registerFeatureCommand(
            name: "ZOOM",
            aliases: ["Z"],
            factory: { ZoomCommand() }
        )

        // Note: tool-mode commands (SELECT, MOVE, ROTATE, SCALE, PAN, ZOOM)
        // are registered inside PhrostEngine itself.
    }
}
