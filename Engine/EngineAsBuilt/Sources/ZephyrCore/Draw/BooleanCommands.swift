import Foundation
import CSDL3
import SwiftSDL

// =========================================================================
// MARK: - BooleanCommands (UNION / SUBTRACT / INTERSECT)
// =========================================================================
//
// Step 2 Booleans over the Step 1 region model. UNION merges all selected
// regions (disjoint inputs yield one entity per island), SUBTRACT removes
// the cutter set from the target set (contained cutters become holes),
// INTERSECT keeps only the common overlap (empty overlap deletes all
// inputs with the LT "Null region" message).
//
// Enforcement: every selected entity must be a region (REGION first);
// all regions must share one Z elevation. Any violation aborts with no
// document changes. Each execution commits atomically via one
// `replaceEntities` call, so one undo step restores all inputs.

// MARK: - Shared executor

@MainActor
enum BooleanExecutor {

    /// Runs `op` and commits the result in one undo step.
    /// - Returns: the prompt message describing the outcome.
    static func execute(
        op: RegionBooleanOp,
        opName: String,
        targetHandles: Set<UUID>,
        cutterHandles: Set<UUID>,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> String {
        let doc = engine.document
        let targets = targetHandles.compactMap { doc.entity(for: $0) }
        let cutters = cutterHandles.compactMap { doc.entity(for: $0) }

        guard !targets.isEmpty else {
            return "No target regions selected."
        }
        if op == .subtract, cutters.isEmpty {
            return "No cutting regions selected."
        }

        let (targetSolids, targetFailures) = RegionBoolean.extractSolids(
            from: targets)
        if !targetFailures.isEmpty {
            return "\(opName) requires region entities - "
                + "\(targetFailures.count) object(s) rejected, no changes made."
        }
        var cutterSolids: [BooleanSolid] = []
        if op == .subtract {
            let (solids, failures) = RegionBoolean.extractSolids(
                from: cutters)
            if !failures.isEmpty {
                return "\(opName) requires region entities - "
                    + "\(failures.count) object(s) rejected, no changes made."
            }
            cutterSolids = solids
        }

        let (faces, failures) = RegionBoolean.apply(
            op, targets: targetSolids, cutters: cutterSolids)
        if !failures.isEmpty {
            return failures.joined(separator: " ")
        }

        var newEntities: [CADEntity] = []
        newEntities.reserveCapacity(faces.count)
        for face in faces {
            var prims: [CADPrimitive] = [
                .polyline(path: face.outer, color: face.color),
            ]
            for hole in face.holes {
                prims.append(.polyline(path: hole, color: face.color))
            }
            var entity = CADEntity(
                layerID: face.layerID,
                localGeometry: prims,
                transform: .identity)
            entity.xdata[CADRegion.markerKey] = .bool(true)
            newEntities.append(entity)
        }

        var removed = targetHandles
        removed.formUnion(cutterHandles)
        doc.replaceEntities(remove: removed, add: newEntities)

        engine.cadSelection.clearSelection()
        for entity in newEntities {
            engine.cadSelection.addToSelection(entity.handle)
        }
        engine.tabManager.markActiveDirty()

        if newEntities.isEmpty {
            if op == .intersect {
                return "Null region created - deleted."
            }
            return "0 Regions created."
        }
        let word = newEntities.count == 1 ? "Region" : "Regions"
        let message = "\(newEntities.count) \(word) created."
        print("[\(opName)] \(message)")
        return message
    }
}

// MARK: - Selection helper

/// Click-to-add selection shared by the Boolean commands (mirrors
/// `RegionCommand`/`ExplodeCommand` hit-testing).
@MainActor
private enum BooleanSelection {
    static func toggle(
        worldX: Double, worldY: Double,
        engine: PhrostEngine,
        processor: CADCommandProcessor,
        verb: String
    ) {
        let threshold = 8.0 / max(engine.camera.zoom, 0.001)
        guard let handle = engine.cadSelection.hitTest(
            worldX: worldX,
            worldY: worldY,
            document: engine.document,
            threshold: threshold,
            simplifyComplexBlocks: engine.simplifyComplexBlocks
        ) else {
            return
        }
        let shiftHeld = engine.io?.pointee.KeyShift ?? false
        if shiftHeld {
            engine.cadSelection.removeFromSelection(handle)
        } else {
            engine.cadSelection.addToSelection(handle)
        }
        processor.commandPrompt =
            "\(verb) (\(engine.cadSelection.selectedCount) selected, Enter to finish):"
    }
}

// MARK: - UNION

/// AutoCAD `UNION`: merge all selected regions into one. Disjoint inputs
/// become one entity per island, all selected together.
@MainActor
public final class UnionCommand: FeatureCommand {

    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        if engine.cadSelection.hasSelection {
            let message = BooleanExecutor.execute(
                op: .union, opName: "UNION",
                targetHandles: engine.cadSelection.selectedHandles,
                cutterHandles: [],
                engine: engine, processor: processor)
            processor.commandPrompt = message
            processor.finishFeatureCommand(engine: engine)
            return
        }
        processor.commandPrompt = "Select objects:"
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {}

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        BooleanSelection.toggle(
            worldX: worldX, worldY: worldY,
            engine: engine, processor: processor, verb: "Select objects")
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
            let message = BooleanExecutor.execute(
                op: .union, opName: "UNION",
                targetHandles: engine.cadSelection.selectedHandles,
                cutterHandles: [],
                engine: engine, processor: processor)
            processor.commandPrompt = message
            return .finished
        case SDL_SCANCODE_ESCAPE:
            return .finished
        default:
            return .continue
        }
    }

    public func handleCommandText(
        _ text: String,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            let message = BooleanExecutor.execute(
                op: .union, opName: "UNION",
                targetHandles: engine.cadSelection.selectedHandles,
                cutterHandles: [],
                engine: engine, processor: processor)
            processor.commandPrompt = message
            return .finished
        }
        return .continue
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}
    public var isSnappingEnabled: Bool { false }
}

// MARK: - INTERSECT

/// AutoCAD `INTERSECT`: keep only the overlap common to every selected
/// region. Empty overlap deletes all inputs.
@MainActor
public final class IntersectCommand: FeatureCommand {

    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        if engine.cadSelection.hasSelection {
            let message = BooleanExecutor.execute(
                op: .intersect, opName: "INTERSECT",
                targetHandles: engine.cadSelection.selectedHandles,
                cutterHandles: [],
                engine: engine, processor: processor)
            processor.commandPrompt = message
            processor.finishFeatureCommand(engine: engine)
            return
        }
        processor.commandPrompt = "Select objects:"
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {}

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        BooleanSelection.toggle(
            worldX: worldX, worldY: worldY,
            engine: engine, processor: processor, verb: "Select objects")
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
            let message = BooleanExecutor.execute(
                op: .intersect, opName: "INTERSECT",
                targetHandles: engine.cadSelection.selectedHandles,
                cutterHandles: [],
                engine: engine, processor: processor)
            processor.commandPrompt = message
            return .finished
        case SDL_SCANCODE_ESCAPE:
            return .finished
        default:
            return .continue
        }
    }

    public func handleCommandText(
        _ text: String,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            let message = BooleanExecutor.execute(
                op: .intersect, opName: "INTERSECT",
                targetHandles: engine.cadSelection.selectedHandles,
                cutterHandles: [],
                engine: engine, processor: processor)
            processor.commandPrompt = message
            return .finished
        }
        return .continue
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}
    public var isSnappingEnabled: Bool { false }
}

// MARK: - SUBTRACT

/// AutoCAD `SUBTRACT`: two-stage. First the target set (objects to keep),
/// then the cutter set (objects to remove). Contained cutters become
/// holes; a fully covered target leaves nothing behind.
@MainActor
public final class SubtractCommand: FeatureCommand {

    private enum Step {
        case selectTargets
        case selectCutters
    }

    private var step: Step = .selectTargets
    private var targetHandles: Set<UUID> = []

    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        if engine.cadSelection.hasSelection {
            // Pre-selected entities become the target set (documented).
            targetHandles = engine.cadSelection.selectedHandles
            engine.cadSelection.clearSelection()
            step = .selectCutters
            processor.commandPrompt = "Select objects to subtract:"
            return
        }
        step = .selectTargets
        processor.commandPrompt = "Select objects to subtract from:"
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {}

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        switch step {
        case .selectTargets:
            BooleanSelection.toggle(
                worldX: worldX, worldY: worldY,
                engine: engine, processor: processor,
                verb: "Select objects to subtract from")
        case .selectCutters:
            BooleanSelection.toggle(
                worldX: worldX, worldY: worldY,
                engine: engine, processor: processor,
                verb: "Select objects to subtract")
        }
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
            switch step {
            case .selectTargets:
                targetHandles = engine.cadSelection.selectedHandles
                engine.cadSelection.clearSelection()
                step = .selectCutters
                processor.commandPrompt = "Select objects to subtract:"
                return .handled
            case .selectCutters:
                let message = BooleanExecutor.execute(
                    op: .subtract, opName: "SUBTRACT",
                    targetHandles: targetHandles,
                    cutterHandles: engine.cadSelection.selectedHandles,
                    engine: engine, processor: processor)
                processor.commandPrompt = message
                return .finished
            }
        case SDL_SCANCODE_ESCAPE:
            return .finished
        default:
            return .continue
        }
    }

    public func handleCommandText(
        _ text: String,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty else { return .continue }
        switch step {
        case .selectTargets:
            targetHandles = engine.cadSelection.selectedHandles
            engine.cadSelection.clearSelection()
            step = .selectCutters
            processor.commandPrompt = "Select objects to subtract:"
            return .handled
        case .selectCutters:
            let message = BooleanExecutor.execute(
                op: .subtract, opName: "SUBTRACT",
                targetHandles: targetHandles,
                cutterHandles: engine.cadSelection.selectedHandles,
                engine: engine, processor: processor)
            processor.commandPrompt = message
            return .finished
        }
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}
    public var isSnappingEnabled: Bool { false }
}
