// Sources/ZephyrCore/Commands/CenterMarkCommand.swift
import Foundation
import CSDL3
import ImGui
import SwiftSDL

/// CENTERMARK (CM) and DIMCENTER (DCE), Phase 2.1: pick a circle or arc to
/// commit a center cross sized from the current dimstyle
/// (CENTEREXE-style: the scaled extensionLineExtend). Each pick commits
/// immediately and the command stays active for the next; Enter or Escape
/// finishes. The mark links its source handle in xdata so MOVE carries it
/// (associative-lite; re-measurement waits for DIMREASSOCIATE).
@MainActor
public final class CenterMarkCommand: FeatureCommand {

    public init() {}

    public var isSnappingEnabled: Bool { true }

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        processor.commandPrompt = "Select circle or arc for center mark:"
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        processor.commandPrompt = "Command cancelled."
    }

    public func getDrawingSnapPoints() -> [Vector3] { [] }

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        guard let hitId = CADHitTesting.hitTest(
            worldX: worldX, worldY: worldY, document: engine.document),
              let entity = engine.document.entity(for: hitId),
              let geom = entity.resolvedGeometry(in: engine.document) else {
            processor.commandPrompt = "No circle or arc there. Select circle or arc for center mark:"
            return .continue
        }
        var center: Vector3?
        for prim in geom {
            if case .circle(let c, _, _) = prim {
                center = c
                break
            } else if case .arc(let c, _, _, _, _) = prim {
                center = c
                break
            }
        }
        guard let center else {
            processor.commandPrompt = "Selected entity is not a circle or arc. Select circle or arc for center mark:"
            return .continue
        }
        commit(center: center, source: hitId, engine: engine)
        processor.commandPrompt = "Select circle or arc for center mark:"
        return .continue
    }

    public func handleMouseMotion(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {}

    public func handleKeyDown(
        scancode: SDL_Scancode,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        switch scancode {
        case SDL_SCANCODE_ESCAPE, SDL_SCANCODE_RETURN, SDL_SCANCODE_KP_ENTER:
            return .finished
        default:
            return .continue
        }
    }

    public func handleCommandText(
        _ text: String, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        return .continue
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}

    private func commit(center: Vector3, source: UUID, engine: PhrostEngine) {
        let halfSize = engine.document.currentDimensionStyle().extensionLineExtend
        let (w0, w1, h0, h1) = CenterMarkMath.crossArms(center: center, halfSize: halfSize)
        let color: ColorRGBA = .white
        var mark = CADEntity(
            layerID: engine.document.activeLayerID ?? UUID(),
            localGeometry: [
                .line(start: w0, end: w1, color: color),
                .line(start: h0, end: h1, color: color),
            ])
        mark.xdata[CenterMarkLink.markSourceKey] = .string(source.uuidString)
        engine.document.addEntities([mark])
    }
}
