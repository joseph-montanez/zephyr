import Foundation
import CSDL3
import SwiftSDL

// =========================================================================
// MARK: - PointCommand (POINT / PO)
// =========================================================================

/// Place `.point` entities. Repeats until Esc so several points can be
/// created per session. Rendering follows the live PDMODE/PDSIZE
/// document settings (see PTYPE).
@MainActor
public final class PointCommand: FeatureCommand {

    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        processor.commandPrompt = "Specify a point (Esc to finish)."
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {}

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        let entity = CADEntity(
            layerID: engine.document.activeLayerID ?? UUID(),
            localGeometry: [.point(position: Vector3(x: worldX, y: worldY, z: 0))])
        engine.document.addEntity(entity)
        engine.tabManager.markActiveDirty()
        processor.commandPrompt = "Specify a point (Esc to finish)."
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

// =========================================================================
// MARK: - PTypeCommand (PTYPE / DDPTYPE)
// =========================================================================

/// Command-line point-style editor (the DDPTYPE dialog is a future UI
/// slice; both names run these prompts): PDMODE value then PDSIZE value.
/// Writes the live document fields with the same validation as the
/// PDMODE/PDSIZE sysvars, so `setvar` and PTYPE never disagree.
@MainActor
public final class PTypeCommand: FeatureCommand {

    private enum State {
        case mode
        case size
    }

    private var state: State = .mode

    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        state = .mode
        processor.commandPrompt =
            "Enter point display mode [0 dot/1 none/2 plus/3 X/4 tick, +32 circle, +64 square] <\(engine.document.pointDisplayMode)>:"
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {}

    public func handleCommandText(
        _ text: String, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        let upper = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        switch state {
        case .mode:
            guard let m = Int(upper), CADDocument.isValidPointDisplayMode(m) else {
                processor.commandPrompt =
                    "Enter point display mode [0-4, +32 circle, +64 square]:"
                return .handled
            }
            engine.document.pointDisplayMode = m
            state = .size
            processor.commandPrompt =
                "Enter point size [>0 absolute, 0 = 5% of viewport, <0 = percent] <\(engine.document.pointDisplaySize)>:"
            return .handled
        case .size:
            guard let s = Double(upper), s.isFinite else {
                processor.commandPrompt = "Enter a real point size:"
                return .handled
            }
            engine.document.pointDisplaySize = s
            processor.commandPrompt =
                "Point style set: mode \(engine.document.pointDisplayMode), size \(s)."
            return .finished
        }
    }

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        // Clicks do nothing; PTYPE is prompt-driven.
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
        if scancode == SDL_SCANCODE_ESCAPE { return .finished }
        return .continue
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}
}
