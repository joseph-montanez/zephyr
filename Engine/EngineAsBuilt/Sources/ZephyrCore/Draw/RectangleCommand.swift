import Foundation
import CSDL3
import ImGui
import SwiftSDL

// =========================================================================
// MARK: - RectangleCommand
// =========================================================================

/// Interactive 2-corner rectangle drawing with width/height numeric entry.
/// After placing the first corner, type width (Tab → height) and press Enter
/// to place the opposite corner at exact dimensions.
@MainActor
public final class RectangleCommand: FeatureCommand {

    private enum State {
        case waitingForFirstCorner
        case waitingForSecondCorner(firstX: Double, firstY: Double)
    }

    private var state: State = .waitingForFirstCorner
    private var currentMouseWorldX: Double = 0
    private var currentMouseWorldY: Double = 0
    private var input = DynamicNumericInput()

    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        state = .waitingForFirstCorner
        input.reset()
        input.tabCycle = [.width, .height]
        processor.commandPrompt = "Specify first corner or enter width (Esc to cancel)."
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        state = .waitingForFirstCorner
        input.reset()
    }

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        switch state {
        case .waitingForFirstCorner:
            state = .waitingForSecondCorner(firstX: worldX, firstY: worldY)
            input.reset()
            processor.commandPrompt = "Specify opposite corner or type W+H (Tab, Enter) (Esc to cancel)."
            return .continue

        case .waitingForSecondCorner(let firstX, let firstY):
            return commitRect(firstX: firstX, firstY: firstY,
                              secondX: worldX, secondY: worldY,
                              engine: engine, processor: processor)
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
        if scancode == SDL_SCANCODE_RETURN || scancode == SDL_SCANCODE_KP_ENTER {
            return handleDimensionEnter(engine: engine, processor: processor)
        }

        let dynResult = input.handleKey(scancode)
        switch dynResult {
        case .ignored:
            break
        case .consumed:
            return .handled
        case .commitValue:
            // User pressed Enter — commit if we have both width and height
            return handleDimensionEnter(engine: engine, processor: processor)
        case .commitAngle:
            return .handled
        case .cancel:
            return .finished
        }

        switch scancode {
        case SDL_SCANCODE_ESCAPE:
            return .finished
        default:
            return .continue
        }
    }

    public func handleCommandText(
        _ text: String, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        let dynResult = input.handleText(text)
        switch dynResult {
        case .ignored:  return .continue
        case .consumed: return .handled
        case .commitValue: return handleDimensionEnter(engine: engine, processor: processor)
        case .commitAngle: return .handled
        case .cancel: return .finished
        }
    }

    /// When Enter is pressed, try to commit the rectangle using typed width/height.
    /// If only one dimension is typed, use the mouse for the other.
    private func handleDimensionEnter(
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        guard case .waitingForSecondCorner(let fx, let fy) = state else {
            return .handled
        }

        let typedW = Double(input.buffers[.width, default: ""])
        let typedH = Double(input.buffers[.height, default: ""])

        // Determine the direction from first corner to cursor
        let dx = currentMouseWorldX - fx
        let dy = currentMouseWorldY - fy

        let w: Double
        let h: Double

        if let tw = typedW, let th = typedH {
            // Both typed — use them directly (absolute values)
            w = abs(tw)
            h = abs(th)
        } else if let tw = typedW {
            // Only width typed; use mouse for height
            w = abs(tw)
            h = abs(dy) > 1e-9 ? abs(dy) : w  // default to square if mouse is on axis
        } else if let th = typedH {
            // Only height typed; use mouse for width
            h = abs(th)
            w = abs(dx) > 1e-9 ? abs(dx) : h
        } else {
            // Nothing typed — use mouse position
            // (this shouldn't normally happen since Enter was pressed)
            w = abs(dx)
            h = abs(dy)
        }

        guard w > 1e-9, h > 1e-9 else {
            processor.commandPrompt = "Dimensions too small. Try again."
            return .handled
        }

        // Determine which quadrant the cursor is in relative to first corner
        let sx = dx >= 0 ? fx : fx - w
        let sy = dy >= 0 ? fy : fy - h

        return commitRect(firstX: fx, firstY: fy,
                          secondX: sx + w, secondY: sy + h,
                          engine: engine, processor: processor)
    }

    private func commitRect(firstX: Double, firstY: Double,
                            secondX: Double, secondY: Double,
                            engine: PhrostEngine, processor: CADCommandProcessor) -> CommandResult {
        let originX = min(firstX, secondX)
        let originY = min(firstY, secondY)
        let sizeX = abs(secondX - firstX)
        let sizeY = abs(secondY - firstY)
        guard sizeX > 1e-9, sizeY > 1e-9 else {
            processor.commandPrompt = "Rectangle too small. Try again."
            return .continue
        }
        let prim: CADPrimitive = .rect(
            origin: Vector3(x: originX, y: originY, z: 0),
            size: Vector3(x: sizeX, y: sizeY, z: 0))
        let entity = CADEntity(
            layerID: engine.document.activeLayerID ?? UUID(),
            localGeometry: [prim])
        engine.document.addEntity(entity)
        engine.tabManager.markActiveDirty()
        processor.commandPrompt = "Rectangle created (\(String(format: "%.2f", sizeX)) x \(String(format: "%.2f", sizeY)))."
        return .finished
    }

    // MARK: - Overlay

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {
        guard case .waitingForSecondCorner(let firstX, let firstY) = state else { return }

        let drawList = igGetForegroundDrawList_ViewportPtr(nil)
        let col = makeCol32(0, 255, 128, 200)

        let p1 = EngineCameraManager.worldToScreen(worldX: firstX, worldY: firstY, cam: cam)
        let p2 = EngineCameraManager.worldToScreen(worldX: currentMouseWorldX, worldY: firstY, cam: cam)
        let p3 = EngineCameraManager.worldToScreen(worldX: currentMouseWorldX, worldY: currentMouseWorldY, cam: cam)
        let p4 = EngineCameraManager.worldToScreen(worldX: firstX, worldY: currentMouseWorldY, cam: cam)

        ImDrawListAddLine(drawList, ImVec2(x: p1.x, y: p1.y), ImVec2(x: p2.x, y: p2.y), col, 1.5)
        ImDrawListAddLine(drawList, ImVec2(x: p2.x, y: p2.y), ImVec2(x: p3.x, y: p3.y), col, 1.5)
        ImDrawListAddLine(drawList, ImVec2(x: p3.x, y: p3.y), ImVec2(x: p4.x, y: p4.y), col, 1.5)
        ImDrawListAddLine(drawList, ImVec2(x: p4.x, y: p4.y), ImVec2(x: p1.x, y: p1.y), col, 1.5)

        let fillCol = makeCol32(0, 255, 128, 30)
        ImDrawListAddRectFilled(drawList,
                                ImVec2(x: min(p1.x, p3.x), y: min(p1.y, p3.y)),
                                ImVec2(x: max(p1.x, p3.x), y: max(p1.y, p3.y)),
                                fillCol, 0.0, 0)

        let w = abs(currentMouseWorldX - firstX)
        let h = abs(currentMouseWorldY - firstY)
        if w > 1e-6 && h > 1e-6 {
            let labelW = String(format: "%.1f", w)
            let labelH = String(format: "%.1f", h)
            let midX = (firstX + currentMouseWorldX) / 2
            let midY = (firstY + currentMouseWorldY) / 2
            let sp = EngineCameraManager.worldToScreen(worldX: midX, worldY: midY, cam: cam)
            let label = "\(labelW) x \(labelH)"
            ImDrawListAddText(drawList, ImVec2(x: sp.x - 25, y: sp.y - 10),
                              makeCol32(255, 255, 255, 200), label, nil)
        }

        input.renderOverlay(cam: cam, worldX: currentMouseWorldX, worldY: currentMouseWorldY)
    }
}
