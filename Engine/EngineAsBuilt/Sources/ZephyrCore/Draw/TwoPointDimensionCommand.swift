// Sources/ZephyrCore/Draw/TwoPointDimensionCommand.swift
import Foundation
import CSDL3
import ImGui
import SwiftSDL

/// Shared state machine for two-point dimensions (`DimLinearCommand`,
/// `DimAlignedCommand`).
///
/// Both commands pick two extension-line origins, then a dimension-line
/// position. Only the dimension-line math differs (axis-aligned vs.
/// parallel-to-measured), so subclasses override `dimensionEndpoints` and
/// `commitDimension`. All prompting, snapping, and rubber-band drawing is
/// shared here.
@MainActor
open class TwoPointDimensionCommand: FeatureCommand {

    public enum PickState {
        case pickingFirstExtOrigin
        case pickingSecondExtOrigin
        case pickingDimLinePos
    }

    var pickState: PickState = .pickingFirstExtOrigin
    var defPoint1: Vector3?
    var defPoint2: Vector3?
    var currentMouseWorldX: Double = 0
    var currentMouseWorldY: Double = 0

    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        pickState = .pickingFirstExtOrigin
        defPoint1 = nil
        defPoint2 = nil
        processor.commandPrompt = "Specify first extension line origin or <select object>:"
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        processor.commandPrompt = "Command cancelled."
    }

    public func getDrawingSnapPoints() -> [Vector3] {
        var pts = [Vector3]()
        if let p1 = defPoint1 { pts.append(p1) }
        if let p2 = defPoint2 { pts.append(p2) }
        return pts
    }

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        let snapPos = engine.snap.currentSnapResult?.worldPos ?? Vector3(x: worldX, y: worldY, z: 0)

        switch pickState {
        case .pickingFirstExtOrigin:
            defPoint1 = snapPos
            pickState = .pickingSecondExtOrigin
            processor.commandPrompt = "Specify second extension line origin:"
            return .continue

        case .pickingSecondExtOrigin:
            defPoint2 = snapPos
            pickState = .pickingDimLinePos
            processor.commandPrompt = "Specify dimension line location:"
            return .continue

        case .pickingDimLinePos:
            guard let p1 = defPoint1, let p2 = defPoint2 else { return .finished }
            let dimLinePos = snapPos

            commitDimension(p1: p1, p2: p2, dimLinePos: dimLinePos, engine: engine, processor: processor)
            return .finished
        }
    }

    public func handleMouseMotion(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        currentMouseWorldX = worldX
        currentMouseWorldY = worldY
    }

    public func handleKeyDown(
        scancode: SDL_Scancode, engine: PhrostEngine, processor: CADCommandProcessor
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

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {
        let drawList = igGetForegroundDrawList_ViewportPtr(nil)
        let col = makeCol32(0, 255, 128, 200)

        switch pickState {
        case .pickingFirstExtOrigin:
            break
        case .pickingSecondExtOrigin:
            guard let p1 = defPoint1 else { return }
            let p1Screen = EngineCameraManager.worldToScreen(worldX: p1.x, worldY: p1.y, cam: cam)
            let curScreen = EngineCameraManager.worldToScreen(worldX: currentMouseWorldX, worldY: currentMouseWorldY, cam: cam)
            ImDrawListAddLine(drawList, ImVec2(x: p1Screen.x, y: p1Screen.y), ImVec2(x: curScreen.x, y: curScreen.y), makeCol32(0, 255, 128, 100), 1.0)
        case .pickingDimLinePos:
            guard let p1 = defPoint1, let p2 = defPoint2 else { return }
            let dimLinePos = engine.snap.currentSnapResult?.worldPos ?? Vector3(x: currentMouseWorldX, y: currentMouseWorldY, z: 0)
            guard let (dimStart, dimEnd) = dimensionEndpoints(p1: p1, p2: p2, dimLinePos: dimLinePos) else { return }

            // Render rubber band lines
            let dsScreen = EngineCameraManager.worldToScreen(worldX: dimStart.x, worldY: dimStart.y, cam: cam)
            let deScreen = EngineCameraManager.worldToScreen(worldX: dimEnd.x, worldY: dimEnd.y, cam: cam)

            // Extensions
            let p1s = EngineCameraManager.worldToScreen(worldX: p1.x, worldY: p1.y, cam: cam)
            let p2s = EngineCameraManager.worldToScreen(worldX: p2.x, worldY: p2.y, cam: cam)

            ImDrawListAddLine(drawList, ImVec2(x: p1s.x, y: p1s.y), ImVec2(x: dsScreen.x, y: dsScreen.y), col, 1.0)
            ImDrawListAddLine(drawList, ImVec2(x: p2s.x, y: p2s.y), ImVec2(x: deScreen.x, y: deScreen.y), col, 1.0)

            // Dim line
            ImDrawListAddLine(drawList, ImVec2(x: dsScreen.x, y: dsScreen.y), ImVec2(x: deScreen.x, y: deScreen.y), col, 1.5)
        }
    }

    // MARK: - Subclass hooks

    /// Dimension-line endpoints for the preview. Returns nil to draw nothing
    /// (e.g. degenerate input).
    open func dimensionEndpoints(p1: Vector3, p2: Vector3, dimLinePos: Vector3) -> (Vector3, Vector3)? {
        return nil
    }

    /// Commits the dimension entity. Implemented by subclasses.
    open func commitDimension(p1: Vector3, p2: Vector3, dimLinePos: Vector3, engine: PhrostEngine, processor: CADCommandProcessor) {
    }
}
