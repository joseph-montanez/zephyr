import Foundation
import CSDL3
import ImGui

// =========================================================================
// DELCONSTRAINT — remove constraints from picked objects (each pick
// strips every constraint touching that entity) or ALL to clear the
// drawing. Removals go through `removeConstraint`, so each is undoable.
// =========================================================================

@MainActor
public final class DelconstraintCommand: FeatureCommand {
    public var name: String { "DELCONSTRAINT" }

    private var finished = false

    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        finished = false
        processor.commandPrompt =
            "Select objects to remove constraints from, or [All] (\(engine.document.constraintCount) constraint(s)). Esc to finish."
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        finished = true
    }

    public func handleCommandText(
        _ text: String, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        let upper = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard upper == "ALL" else {
            processor.commandPrompt = "Type All to clear every constraint, or pick objects. Esc to finish."
            return .handled
        }
        let count = engine.document.constraintCount
        for constraint in engine.document.allConstraints {
            engine.document.removeConstraint(handle: constraint.handle)
        }
        engine.tabManager.markActiveDirty()
        processor.commandPrompt = "Removed \(count) constraint(s)."
        finished = true
        return .finished
    }

    public func handleKeyDown(
        scancode: SDL_Scancode, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        .continue
    }

    public func handleMouseClick(
        worldX: Double, worldY: Double, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        if finished { return .finished }
        guard let hit = CADHitTesting.nestedHitTest(
            worldX: worldX, worldY: worldY, document: engine.document) else {
            processor.commandPrompt = "No object there. Pick an object, or type All. Esc to finish."
            return .continue
        }
        let doomed = engine.document.constraintsAffecting(hit.entity.handle)
        for constraint in doomed {
            engine.document.removeConstraint(handle: constraint.handle)
        }
        engine.tabManager.markActiveDirty()
        if doomed.isEmpty {
            processor.commandPrompt = "Object has no constraints. Pick another, or type All. Esc to finish."
        } else {
            processor.commandPrompt =
                "Removed \(doomed.count) constraint(s) (\(engine.document.constraintCount) left). Pick another, or type All. Esc to finish."
        }
        return .continue
    }

    public func handleMouseMotion(
        worldX: Double, worldY: Double, engine: PhrostEngine, processor: CADCommandProcessor
    ) {}

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}
}
