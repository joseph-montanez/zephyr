import Foundation
import CSDL3
import SwiftSDL

// =========================================================================
// MARK: - BoundaryCommand (BOUNDARY / BO)
// =========================================================================

/// Create a closed boundary from an interior pick point, reusing
/// the hatch engine's wall-following boundary detection
/// (`CADBoundaryDetector.findEnclosingPolygon`). Repeats so several
/// boundaries can be created per session; Esc finishes. Only the outer
/// loop is kept (island holes arrive with the hatch-style option set
/// later).
///
/// Object type (AutoCAD `BOUNDARY` dialog equivalent): `Polyline`
/// (default, existing behavior) or `Region` — a closed polyline carrying
/// the `zephyr.region` marker, validated by `RegionBuilder`. Type `R` or
/// `P` at the prompt to switch; the choice persists for later picks.
@MainActor
public final class BoundaryCommand: FeatureCommand {

    private var emitRegion = false

    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        processor.commandPrompt =
            "Pick an internal point (R = Region, P = Polyline, Esc to finish)."
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {}

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        guard let loop = CADBoundaryDetector.findEnclosingPolygon(
            seedX: worldX, seedY: worldY,
            document: engine.document
        ), loop.count >= 3 else {
            processor.commandPrompt =
                "A closed boundary cannot be determined. Pick inside a fully enclosed loop."
            return .handled
        }
        let entity = Self.makeEntity(
            loop: loop, asRegion: emitRegion,
            layerID: engine.document.activeLayerID ?? UUID())
        engine.document.addEntity(entity)
        engine.tabManager.markActiveDirty()
        let kind = CADRegion.isRegionEntity(entity) ? "Region" : "Boundary"
        processor.commandPrompt =
            "\(kind) created. Pick another point (R = Region, P = Polyline, Esc to finish)."
        return .continue
    }

    /// Builds the boundary entity for a wall-followed loop. Pure over the
    /// loop points so the Region/Polyline contract is unit-testable.
    public static func makeEntity(
        loop: [Vector3], asRegion: Bool, layerID: UUID
    ) -> CADEntity {
        let path = CADPolyline(points: loop, isClosed: true)
        var entity = CADEntity(
            layerID: layerID,
            localGeometry: [.polyline(path: path)])
        if asRegion, RegionBuilder.validate(path) == nil {
            entity.xdata[CADRegion.markerKey] = .bool(true)
        }
        return entity
    }

    public func handleCommandText(
        _ text: String,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        switch text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "R", "REGION":
            emitRegion = true
            processor.commandPrompt =
                "Object type: Region. Pick an internal point (Esc to finish)."
            return .handled
        case "P", "POLYLINE":
            emitRegion = false
            processor.commandPrompt =
                "Object type: Polyline. Pick an internal point (Esc to finish)."
            return .handled
        default:
            return .continue
        }
    }

    public func commandTextOptions(for input: String) -> [FeatureCommandTextOption] {
        [
            FeatureCommandTextOption(
                value: "Region", title: "Region", aliases: ["R"],
                description: "Create region entities"),
            FeatureCommandTextOption(
                value: "Polyline", title: "Polyline", aliases: ["P"],
                description: "Create closed polylines"),
        ].filter { $0.matches(input) }
    }

    public func activeOptionValues(engine: PhrostEngine) -> Set<String> {
        [emitRegion ? "Region" : "Polyline"]
    }

    public func handleMouseMotion(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {}

    public func handleKeyDown(
        scancode: SDL_Scancode, engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        if scancode == SDL_SCANCODE_ESCAPE { return .finished }
        return .continue
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}
}
