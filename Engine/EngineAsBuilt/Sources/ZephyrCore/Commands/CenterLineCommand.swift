// Sources/ZephyrCore/Commands/CenterLineCommand.swift
import Foundation
import CSDL3
import ImGui
import SwiftSDL

/// CENTERLINE (CL), Phase 2.1: pick two parallel lines to commit the
/// midway centerline spanning their combined extent. Non-parallel or
/// degenerate picks report honestly and stay on the same step. The
/// centerline links both source handles in xdata so MOVE carries it
/// (associative-lite; re-measurement waits for DIMREASSOCIATE).
@MainActor
public final class CenterLineCommand: FeatureCommand {

    private var first: (Vector3, Vector3, UUID)?

    public init() {}

    public var isSnappingEnabled: Bool { true }

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        first = nil
        processor.commandPrompt = "Select first line:"
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        processor.commandPrompt = "Command cancelled."
    }

    public func getDrawingSnapPoints() -> [Vector3] {
        guard let first else { return [] }
        return [first.0, first.1]
    }

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        guard let hitId = CADHitTesting.hitTest(
            worldX: worldX, worldY: worldY, document: engine.document),
              let entity = engine.document.entity(for: hitId),
              let geom = entity.resolvedGeometry(in: engine.document) else {
            processor.commandPrompt = first == nil
                ? "No line there. Select first line:"
                : "No line there. Select second line:"
            return .continue
        }
        var picked: (Vector3, Vector3)?
        for prim in geom {
            if case .line(let start, let end, _) = prim {
                picked = (start, end)
                break
            }
        }
        guard let picked else {
            processor.commandPrompt = first == nil
                ? "Selected entity is not a line. Select first line:"
                : "Selected entity is not a line. Select second line:"
            return .continue
        }
        guard let first else {
            self.first = (picked.0, picked.1, hitId)
            processor.commandPrompt = "Select second line:"
            return .continue
        }
        guard let (m1, m2) = CenterMarkMath.midline(
            a1: first.0, a2: first.1, b1: picked.0, b2: picked.1) else {
            processor.commandPrompt = "Lines must be parallel with extent. Select second line:"
            return .continue
        }
        let color: ColorRGBA = .white
        var centerline = CADEntity(
            layerID: engine.document.activeLayerID ?? UUID(),
            localGeometry: [.line(start: m1, end: m2, color: color)])
        centerline.xdata[CenterMarkLink.lineSourcesKey] = .string(
            "\(first.2.uuidString),\(hitId.uuidString)")
        engine.document.addEntities([centerline])
        return .finished
    }

    public func handleMouseMotion(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {}

    public func handleKeyDown(
        scancode: SDL_Scancode,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        if scancode == SDL_SCANCODE_ESCAPE {
            return .finished
        }
        return .continue
    }

    public func handleCommandText(
        _ text: String, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        return .continue
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}
}
