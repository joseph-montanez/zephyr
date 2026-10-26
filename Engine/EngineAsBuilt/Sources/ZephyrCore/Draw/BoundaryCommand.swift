import Foundation
import CSDL3
import SwiftSDL

// =========================================================================
// MARK: - BoundaryCommand (BOUNDARY / BO)
// =========================================================================

/// Create a `.polygon` region from an interior pick point, reusing the
/// hatch engine's wall-following boundary detection
/// (`CADBoundaryDetector.findEnclosingPolygon`). Repeats so several
/// regions can be created per session; Esc finishes. Only the outer loop
/// is kept in this slice (island holes arrive with the hatch-style
/// option set later).
@MainActor
public final class BoundaryCommand: FeatureCommand {

    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        processor.commandPrompt = "Pick an internal point (Esc to finish)."
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
        let entity = CADEntity(
            layerID: engine.document.activeLayerID ?? UUID(),
            localGeometry: [.polygon(points: loop)])
        engine.document.addEntity(entity)
        engine.tabManager.markActiveDirty()
        processor.commandPrompt = "Boundary created. Pick another point (Esc to finish)."
        return .continue
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
