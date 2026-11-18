import Foundation
import CSDL3
import SwiftSDL

// =========================================================================
// MARK: - MassPropCommand (MASSPROP)
// =========================================================================
//
// AutoCAD `MASSPROP`: engineering properties of region entities.
//
// Always reports area, perimeter, bounding box, and centroid. The inertia
// suite (moments, product, radii of gyration, principal moments about the
// centroid) appears only when the regions are coplanar with the XY plane
// of the current UCS — mirroring LT. With several regions selected, only
// those coplanar with the first selected region are analyzed; the rest
// are counted as skipped. Non-region entities abort with no changes.
//
// Everything is computed in the current UCS frame. Creates no geometry,
// so there is nothing to undo. After the report, the command offers to
// write the analysis to a `.mpr` text file (path resolution mirrors
// `-EXPORTPDF`: quoted/tilde/absolute/relative-to-drawing-folder, with a
// `<drawing>.mpr` default for saved drawings).

@MainActor
public final class MassPropCommand: FeatureCommand {

    private enum Step {
        case selectObjects
        case askFile
        case askPath
    }

    private var step: Step = .selectObjects
    private var pendingLines: [String] = []
    private var pendingSummary: String = ""

    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        if engine.cadSelection.hasSelection {
            executeReport(
                handles: engine.cadSelection.selectedHandles,
                engine: engine, processor: processor)
            return
        }
        step = .selectObjects
        processor.commandPrompt = "Select objects:"
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {}

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        guard step == .selectObjects else { return .finished }
        let threshold = 8.0 / max(engine.camera.zoom, 0.001)
        guard let handle = engine.cadSelection.hitTest(
            worldX: worldX,
            worldY: worldY,
            document: engine.document,
            threshold: threshold,
            simplifyComplexBlocks: engine.simplifyComplexBlocks
        ) else {
            return .handled
        }
        let shiftHeld = engine.io?.pointee.KeyShift ?? false
        if shiftHeld {
            engine.cadSelection.removeFromSelection(handle)
        } else {
            engine.cadSelection.addToSelection(handle)
        }
        processor.commandPrompt =
            "Select objects (\(engine.cadSelection.selectedCount) selected, Enter to finish):"
        return .handled
    }

    public func handleMouseMotion(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {}

    public func handleKeyDown(
        scancode: SDL_Scancode, engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        switch scancode {
        case SDL_SCANCODE_RETURN, SDL_SCANCODE_KP_ENTER, SDL_SCANCODE_SPACE:
            return submit(text: "", engine: engine, processor: processor)
        case SDL_SCANCODE_ESCAPE:
            return .finished
        default:
            return .continue
        }
    }

    public func handleCommandText(
        _ text: String,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch step {
        case .selectObjects:
            if trimmed.isEmpty {
                return submit(text: "", engine: engine, processor: processor)
            }
            return .continue
        case .askFile, .askPath:
            return submit(text: text, engine: engine, processor: processor)
        }
    }

    public func commandTextOptions(for input: String) -> [FeatureCommandTextOption] {
        guard step == .askFile else { return [] }
        return [
            FeatureCommandTextOption(
                value: "Yes", title: "Yes", aliases: ["Y"],
                description: "Write the analysis to a .mpr file"),
            FeatureCommandTextOption(
                value: "No", title: "No", aliases: ["N"],
                description: "Skip writing a file (default)"),
        ].filter { $0.matches(input) }
    }

    public func activeOptionValues(engine: PhrostEngine) -> Set<String> {
        step == .askFile ? ["No"] : []
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}
    public var isSnappingEnabled: Bool { false }

    // MARK: - Flow

    @discardableResult
    private func submit(
        text: String, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch step {
        case .selectObjects:
            executeReport(
                handles: engine.cadSelection.selectedHandles,
                engine: engine, processor: processor)
            return .finished
        case .askFile:
            switch trimmed.uppercased() {
            case "Y", "YES":
                step = .askPath
                processor.commandPrompt = "Enter file path (.mpr):"
                return .handled
            default:
                // "N", "NO", and bare Enter all mean No.
                processor.commandPrompt = pendingSummary
                processor.finishFeatureCommand(engine: engine)
                return .finished
            }
        case .askPath:
            guard let url = Self.resolveMprURL(
                pathTail: text,
                drawingFolder: engine.tabManager.activeTab?.fileURL?
                    .deletingLastPathComponent(),
                displayName: engine.tabManager.activeTab?.displayName
            ) else {
                processor.commandPrompt =
                    "MASSPROP needs a path for an unsaved drawing: type a file path."
                return .handled
            }
            do {
                try Self.writeReport(pendingLines, to: url)
                print("[MASSPROP] Analysis written to \(url.path).")
                processor.commandPrompt = "Analysis written to \(url.lastPathComponent)."
            } catch {
                processor.commandPrompt = "Could not write \(url.lastPathComponent)."
            }
            processor.finishFeatureCommand(engine: engine)
            return .finished
        }
    }

    private func executeReport(
        handles: Set<UUID>,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) {
        let doc = engine.document
        let luprec = doc.lengthPrecision
        guard !handles.isEmpty else {
            processor.commandPrompt = "No objects selected."
            processor.finishFeatureCommand(engine: engine)
            return
        }
        let entities = handles.compactMap { doc.entity(for: $0) }
        let (solids, failures) = RegionBoolean.extractSolids(from: entities)
        guard failures.isEmpty else {
            processor.commandPrompt =
                "MASSPROP requires region entities - "
                + "\(failures.count) object(s) rejected, no analysis performed."
            processor.finishFeatureCommand(engine: engine)
            return
        }
        guard !solids.isEmpty else {
            processor.commandPrompt = "No regions selected."
            processor.finishFeatureCommand(engine: engine)
            return
        }
        let (kept, skipped) = RegionMass.partitionCoplanar(solids)
        guard !kept.isEmpty else {
            processor.commandPrompt = "No coplanar regions selected."
            processor.finishFeatureCommand(engine: engine)
            return
        }
        let ucs = doc.ucsState.definition
        let planeZ = kept[0].outer.vertices.first?.position.z ?? 0
        let coplanar = abs(planeZ - ucs.origin.z) <= RegionBuilder.planarTolerance
        let report = RegionMass.analyze(solids: kept, ucs: ucs)
        pendingLines = Self.reportLines(
            report: report, luprec: luprec,
            coplanar: coplanar, skipped: skipped)
        for line in pendingLines { print("[MASSPROP] \(line)") }
        func f(_ v: Double) -> String {
            InquiryMath.formatLength(v, precision: luprec)
        }
        pendingSummary =
            "MASSPROP: Area = \(f(report.area)), Centroid = "
            + "(\(f(report.centroid.x)), \(f(report.centroid.y)))."
        step = .askFile
        processor.commandPrompt = "\(pendingSummary) Write analysis to a file? [Yes/No] <N>:"
    }

    // MARK: - Pure report formatting and file output (unit-testable)

    /// LT-style report body shared by the console print and the .mpr file.
    public static func reportLines(
        report: RegionMassReport,
        luprec: Int,
        coplanar: Bool,
        skipped: Int
    ) -> [String] {
        func f(_ v: Double) -> String {
            InquiryMath.formatLength(v, precision: luprec)
        }
        var lines: [String] = []
        lines.append("----------------   REGIONS   ----------------")
        lines.append("              Area: \(f(report.area))")
        lines.append("         Perimeter: \(f(report.perimeter))")
        lines.append(
            "      Bounding box:  X: \(f(report.bboxMin.x)) -- \(f(report.bboxMax.x))")
        lines.append(
            "                     Y: \(f(report.bboxMin.y)) -- \(f(report.bboxMax.y))")
        lines.append(
            "          Centroid:  X: \(f(report.centroid.x))  Y: \(f(report.centroid.y))")
        if coplanar {
            lines.append(
                "Moments of inertia:  X: \(f(report.ixx))  Y: \(f(report.iyy))")
            lines.append("Product of inertia:  XY: \(f(report.ixy))")
            lines.append(
                " Radii of gyration:  X: \(f(report.rxx))  Y: \(f(report.ryy))")
            lines.append(
                "Principal moments and X-Y directions about centroid:")
            lines.append(
                "              I: \(f(report.princI)) along "
                    + "[\(f(cos(report.princAngle))) \(f(sin(report.princAngle))) 0]")
            lines.append(
                "              J: \(f(report.princJ)) along "
                    + "[\(f(-sin(report.princAngle))) \(f(cos(report.princAngle))) 0]")
        } else {
            lines.append(
                "Regions are not coplanar with the current UCS - "
                    + "moments of inertia not computed.")
        }
        if skipped > 0 {
            lines.append(
                "(\(skipped) region(s) not coplanar with the first selected "
                    + "region were ignored.)")
        }
        return lines
    }

    /// Writes report lines to `url` (UTF-8, trailing newline).
    public static func writeReport(_ lines: [String], to url: URL) throws {
        try (lines.joined(separator: "\n") + "\n").write(
            to: url, atomically: true, encoding: .utf8)
    }

    /// Resolve the `.mpr` output target: quoted/tilde/absolute/relative
    /// paths (relative anchored at the drawing's folder), defaulting to
    /// `<drawing>.mpr` for saved drawings. Nil when no path was given
    /// and the drawing was never saved.
    public static func resolveMprURL(
        pathTail: String, drawingFolder: URL?, displayName: String?
    ) -> URL? {
        var tail = pathTail.trimmingCharacters(in: .whitespacesAndNewlines)
        if tail.count >= 2,
           (tail.hasPrefix("\"") && tail.hasSuffix("\""))
            || (tail.hasPrefix("'") && tail.hasSuffix("'")) {
            tail = String(tail.dropFirst().dropLast())
        }
        if !tail.isEmpty {
            let expanded = (tail as NSString).expandingTildeInPath
            let isAbsolute = expanded.hasPrefix("/")
                || expanded.hasPrefix("\\\\")
                || (expanded.count > 2
                    && expanded[expanded.index(expanded.startIndex, offsetBy: 1)] == ":")
            let url: URL
            if isAbsolute {
                url = URL(fileURLWithPath: expanded)
            } else if let folder = drawingFolder {
                url = folder.appendingPathComponent(expanded)
            } else {
                url = URL(fileURLWithPath: expanded)
            }
            return url.pathExtension.lowercased() == "mpr"
                ? url : url.appendingPathExtension("mpr")
        }
        guard let folder = drawingFolder else { return nil }
        let base = (displayName ?? "drawing").trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = base.isEmpty ? "drawing" : base
        return folder.appendingPathComponent(stem).appendingPathExtension("mpr")
    }
}
