import Foundation
import ImGui
import SwiftSDL

// =========================================================================
// MARK: - CircleCommand
// =========================================================================

/// Interactive circle drawing: center point then radius point.
@MainActor
public final class CircleCommand: FeatureCommand {

    private enum State {
        case waitingForCenter
        case waitingForRadius(centerX: Double, centerY: Double)
    }

    private var state: State = .waitingForCenter
    private var currentMouseWorldX: Double = 0
    private var currentMouseWorldY: Double = 0

    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        state = .waitingForCenter
        processor.commandPrompt = "Specify center point (Esc to cancel)."
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        state = .waitingForCenter
    }

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        switch state {
        case .waitingForCenter:
            state = .waitingForRadius(centerX: worldX, centerY: worldY)
            processor.commandPrompt = "Specify radius (Esc to cancel)."
            return .continue

        case .waitingForRadius(let cx, let cy):
            let center = Vector3(x: cx, y: cy, z: 0)
            let radius = sqrt((worldX - cx) * (worldX - cx) + (worldY - cy) * (worldY - cy))
            guard radius > 1e-9 else {
                processor.commandPrompt = "Radius too small. Try again."
                return .continue
            }
            let prim: CADPrimitive = .circle(center: center, radius: radius)
            let entity = CADEntity(
                layerID: engine.document.activeLayerID ?? UUID(),
                localGeometry: [prim])
            engine.document.addEntity(entity)
            engine.tabManager.markActiveDirty()
            processor.commandPrompt = "Circle created (r=\(String(format: "%.2f", radius)))."
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
        return .continue
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {
        guard case .waitingForRadius(let cx, let cy) = state else { return }

        let drawList = igGetForegroundDrawList_ViewportPtr(nil)
        let col = makeCol32(0, 255, 128, 200)
        let radius = sqrt(
            (currentMouseWorldX - cx) * (currentMouseWorldX - cx)
                + (currentMouseWorldY - cy) * (currentMouseWorldY - cy))

        if radius > 1e-6 {
            let segments = 64
            var points: [ImVec2] = []
            for i in 0...segments {
                let angle = Double(i) * 2.0 * .pi / Double(segments)
                let wx = cx + cos(angle) * radius
                let wy = cy + sin(angle) * radius
                let sp = EngineCameraManager.worldToScreen(worldX: wx, worldY: wy, cam: cam)
                points.append(ImVec2(x: sp.x, y: sp.y))
            }
            points.withUnsafeBufferPointer { buf in
                ImDrawListAddPolyline(drawList, buf.baseAddress, Int32(points.count), col, 1.5, ImDrawFlags(0))
            }
        }

        // Crosshair at center
        let cp = EngineCameraManager.worldToScreen(worldX: cx, worldY: cy, cam: cam)
        let crossCol = makeCol32(255, 255, 255, 150)
        ImDrawListAddLine(drawList, ImVec2(x: cp.x - 6, y: cp.y), ImVec2(x: cp.x + 6, y: cp.y), crossCol, 1.0)
        ImDrawListAddLine(drawList, ImVec2(x: cp.x, y: cp.y - 6), ImVec2(x: cp.x, y: cp.y + 6), crossCol, 1.0)

        // Line from center to cursor
        let mp = EngineCameraManager.worldToScreen(worldX: currentMouseWorldX, worldY: currentMouseWorldY, cam: cam)
        ImDrawListAddLine(drawList, ImVec2(x: cp.x, y: cp.y), ImVec2(x: mp.x, y: mp.y),
                          makeCol32(0, 255, 128, 100), 1.0)
    }
}
