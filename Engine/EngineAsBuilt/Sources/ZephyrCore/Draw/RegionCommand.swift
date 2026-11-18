import Foundation
import CSDL3
import SwiftSDL

// =========================================================================
// MARK: - RegionCommand (REGION / REG)
// =========================================================================

/// AutoCAD `REGION`: convert closed loops into region entities.
///
/// Accepted Step 1 inputs: closed polylines/polygons/rects, circles,
/// closed ellipses (tessellated), and chains of lines/arcs/open polylines
/// whose endpoints meet. Each closed loop becomes one region entity (a
/// closed polyline carrying the `zephyr.region` xdata marker, so rendering,
/// selection, AREA, and EXPLODE work through existing paths).
/// Self-intersecting and open loops are rejected with a message.
///
/// `DELOBJ = 0` retains the source geometry, any other value deletes it.
/// One undo step covers the whole conversion.
@MainActor
public final class RegionCommand: FeatureCommand {

    private enum Step {
        case selectObjects
        case done
    }

    private var step: Step = .selectObjects

    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        if engine.cadSelection.hasSelection {
            executeRegion(engine: engine, processor: processor)
            return
        }
        step = .selectObjects
        processor.commandPrompt = "Select objects:"
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {}

    public func handleMouseClick(
        worldX: Double,
        worldY: Double,
        engine: PhrostEngine,
        processor: CADCommandProcessor
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
        worldX: Double,
        worldY: Double,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) {}

    public func handleKeyDown(
        scancode: SDL_Scancode, engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        switch scancode {
        case SDL_SCANCODE_RETURN, SDL_SCANCODE_KP_ENTER, SDL_SCANCODE_SPACE:
            if step == .selectObjects {
                executeRegion(engine: engine, processor: processor)
                return .finished
            }
            return .finished
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
        if trimmed.isEmpty && step == .selectObjects {
            executeRegion(engine: engine, processor: processor)
            return .finished
        }
        return .continue
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}
    public var isSnappingEnabled: Bool { false }

    // MARK: - Execution

    private func executeRegion(
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        let handles = engine.cadSelection.selectedHandles
        guard !handles.isEmpty else {
            processor.commandPrompt = "No objects selected."
            processor.finishFeatureCommand(engine: engine)
            return
        }
        let doc = engine.document
        let entities = handles.compactMap { doc.entity(for: $0) }
        let (loops, failures) = RegionBuilder.buildRegions(from: entities)

        guard !loops.isEmpty else {
            let detail = failures.first.map { " \($0)" } ?? ""
            processor.commandPrompt = "0 regions created.\(detail)"
            processor.finishFeatureCommand(engine: engine)
            return
        }

        var newEntities: [CADEntity] = []
        newEntities.reserveCapacity(loops.count)
        for loop in loops {
            var entity = CADEntity(
                layerID: loop.layerID,
                localGeometry: [.polyline(path: loop.polyline, color: loop.color)],
                transform: .identity)
            entity.xdata[CADRegion.markerKey] = .bool(true)
            newEntities.append(entity)
        }

        var removed = Set<UUID>()
        for loop in loops {
            removed.formUnion(loop.sourceHandles)
        }
        // DELOBJ = 0 retains sources; any other value (default 3) deletes.
        let keepSources: Bool = {
            if case .int(let v) = processor.systemVariable("DELOBJ") {
                return v == 0
            }
            if case .real(let d) = processor.systemVariable("DELOBJ") {
                return Int(d) == 0
            }
            return false
        }()

        if keepSources {
            doc.addEntities(newEntities)
        } else {
            doc.replaceEntities(remove: removed, add: newEntities)
        }

        engine.cadSelection.clearSelection()
        for entity in newEntities {
            engine.cadSelection.addToSelection(entity.handle)
        }
        engine.tabManager.markActiveDirty()

        let loopWord = loops.count == 1 ? "loop" : "loops"
        let regionWord = newEntities.count == 1 ? "Region" : "Regions"
        var message =
            "\(loops.count) \(loopWord) extracted. "
            + "\(newEntities.count) \(regionWord) created."
        if !failures.isEmpty, loops.count != entities.count {
            message += " (\(failures.count) rejected.)"
        }
        print("[REGION] \(message)")
        processor.commandPrompt = message
        processor.finishFeatureCommand(engine: engine)
    }
}
