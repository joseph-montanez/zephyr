import Foundation
import ImGui
import SwiftSDL

// =========================================================================
// MARK: - EllipseCommand
// =========================================================================

/// Interactive ellipse: center, major axis endpoint, minor axis point.
/// Creates an `.ellipse` CADPrimitive with semantic parameters.
@MainActor
public final class EllipseCommand: FeatureCommand {

    private enum State {
        case waitingForCenter
        case waitingForMajorAxis(centerX: Double, centerY: Double)
        case waitingForMinorAxis(centerX: Double, centerY: Double, majorX: Double, majorY: Double)
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
            state = .waitingForMajorAxis(centerX: worldX, centerY: worldY)
            processor.commandPrompt = "Specify end of major axis (Esc to cancel)."
            return .continue

        case .waitingForMajorAxis(let cx, let cy):
            let dx = worldX - cx
            let dy = worldY - cy
            let dist = sqrt(dx * dx + dy * dy)
            guard dist > 1e-9 else {
                processor.commandPrompt = "Major axis too short. Try again."
                return .continue
            }
            state = .waitingForMinorAxis(centerX: cx, centerY: cy, majorX: worldX, majorY: worldY)
            processor.commandPrompt = "Specify end of minor axis (Esc to cancel)."
            return .continue

        case .waitingForMinorAxis(let cx, let cy, let mx, let my):
            let center = Vector3(x: cx, y: cy, z: 0)
            let majorAxis = Vector3(x: mx - cx, y: my - cy, z: 0)
            let majorLen = majorAxis.magnitude
            let angle = atan2(majorAxis.y, majorAxis.x)

            // Project click onto minor axis (perpendicular to major)
            let dx = worldX - cx
            let dy = worldY - cy
            let perp = Vector3(x: -sin(angle), y: cos(angle), z: 0)
            let minorDist = abs(dx * perp.x + dy * perp.y)
            let minorRatio = majorLen > 1e-9 ? minorDist / majorLen : 0.5

            guard minorRatio > 1e-9 else {
                processor.commandPrompt = "Minor axis too short. Try again."
                return .continue
            }

            let prim: CADPrimitive = .ellipse(center: center, majorAxis: majorAxis,
                                               minorRatio: minorRatio)
            let entity = CADEntity(
                layerID: engine.document.activeLayerID ?? UUID(),
                localGeometry: [prim])
            engine.document.addEntity(entity)
            engine.tabManager.markActiveDirty()
            processor.commandPrompt = "Ellipse created (major=\(String(format: "%.2f", majorLen)), ratio=\(String(format: "%.3f", minorRatio)))."
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
        let drawList = igGetForegroundDrawList_ViewportPtr(nil)
        let col = makeCol32(0, 255, 128, 200)

        switch state {
        case .waitingForCenter:
            break

        case .waitingForMajorAxis(let cx, let cy):
            let cp = EngineCameraManager.worldToScreen(worldX: cx, worldY: cy, cam: cam)
            let mp = EngineCameraManager.worldToScreen(worldX: currentMouseWorldX, worldY: currentMouseWorldY, cam: cam)
            ImDrawListAddLine(drawList, ImVec2(x: cp.x, y: cp.y), ImVec2(x: mp.x, y: mp.y), col, 1.5)

        case .waitingForMinorAxis(let cx, let cy, let mx, let my):
            let majorAxis = Vector3(x: mx - cx, y: my - cy, z: 0)
            let majorLen = majorAxis.magnitude
            let angle = atan2(majorAxis.y, majorAxis.x)

            // Project cursor to minor axis distance
            let dx = currentMouseWorldX - cx
            let dy = currentMouseWorldY - cy
            let perpX = -sin(angle)
            let perpY = cos(angle)
            let minorDist = abs(dx * perpX + dy * perpY)
            let minorRatio = majorLen > 1e-9 ? minorDist / majorLen : 0.5
            let minorLen = majorLen * minorRatio

            // Generate ellipse points for preview
            let segments = 64
            let cosRot = cos(angle)
            let sinRot = sin(angle)
            var points: [ImVec2] = []
            for i in 0...segments {
                let t = Double(i) * 2.0 * .pi / Double(segments)
                let px = majorLen * cos(t)
                let py = minorLen * sin(t)
                let rx = px * cosRot - py * sinRot + cx
                let ry = px * sinRot + py * cosRot + cy
                let sp = EngineCameraManager.worldToScreen(worldX: rx, worldY: ry, cam: cam)
                points.append(ImVec2(x: sp.x, y: sp.y))
            }
            points.withUnsafeBufferPointer { buf in
                ImDrawListAddPolyline(drawList, buf.baseAddress, Int32(points.count), col, 1.5, ImDrawFlags(0))
            }

            // Draw axes
            let cp = EngineCameraManager.worldToScreen(worldX: cx, worldY: cy, cam: cam)
            let mp = EngineCameraManager.worldToScreen(worldX: mx, worldY: my, cam: cam)
            let ep1 = EngineCameraManager.worldToScreen(worldX: cx + cos(angle + .pi/2) * minorLen,
                                                   worldY: cy + sin(angle + .pi/2) * minorLen, cam: cam)
            let ep2 = EngineCameraManager.worldToScreen(worldX: cx + cos(angle - .pi/2) * minorLen,
                                                   worldY: cy + sin(angle - .pi/2) * minorLen, cam: cam)
            let axisCol = makeCol32(255, 255, 100, 100)
            ImDrawListAddLine(drawList, ImVec2(x: cp.x, y: cp.y), ImVec2(x: mp.x, y: mp.y), axisCol, 1.0)
            ImDrawListAddLine(drawList, ImVec2(x: ep1.x, y: ep1.y), ImVec2(x: ep2.x, y: ep2.y), axisCol, 1.0)
        }
    }
}
