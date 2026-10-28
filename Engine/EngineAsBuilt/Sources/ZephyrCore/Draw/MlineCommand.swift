import Foundation
import CSDL3
import ImGui
import SwiftSDL

// =========================================================================
// MLINE — interactive multiline drawing. Click centerline points (C
// closes, Enter finishes); J cycles justification, S sets scale, ST
// picks the style. The baked element lines plus centerline xdata land
// on one undo entry, and both writers rebuild MLINE entities from it.
// =========================================================================

@MainActor
public final class MlineCommand: FeatureCommand {
    public var name: String { "MLINE" }

    private var points: [Vector3] = []
    private var currentMouseWorldX: Double = 0
    private var currentMouseWorldY: Double = 0
    private var styleName = "Standard"
    private var scale = 1.0
    private var justification = 0
    private var awaitingValue: Awaiting = .none

    private enum Awaiting {
        case none
        case scale
        case style
    }

    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        points.removeAll()
        styleName = engine.document.currentMlineStyleName
        scale = engine.document.mlineScale
        justification = engine.document.mlineJustification
        awaitingValue = .none
        prompt(processor: processor)
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        points.removeAll()
        awaitingValue = .none
    }

    public func getDrawingSnapPoints() -> [Vector3] { points }

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        points.append(Vector3(x: worldX, y: worldY, z: 0))
        prompt(processor: processor)
        return .continue
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
        switch scancode {
        case SDL_SCANCODE_C:
            return finalize(engine: engine, processor: processor, closed: true)
        case SDL_SCANCODE_J:
            justification = (justification + 1) % 3
            engine.document.mlineJustification = justification
            prompt(processor: processor)
            return .continue
        case SDL_SCANCODE_S:
            awaitingValue = .scale
            processor.commandPrompt = "Enter multiline scale <\(fmt(scale))>:"
            processor.commandBuffer = ""
            processor.commandSelectionIndex = 0
            processor.commandLineActive = true
            return .continue
        case SDL_SCANCODE_T:
            awaitingValue = .style
            processor.commandPrompt = "Enter multiline style name <\(styleName)>:"
            processor.commandBuffer = ""
            processor.commandSelectionIndex = 0
            processor.commandLineActive = true
            return .continue
        case SDL_SCANCODE_RETURN, SDL_SCANCODE_KP_ENTER:
            return finalize(engine: engine, processor: processor, closed: false)
        case SDL_SCANCODE_ESCAPE:
            return finalize(engine: engine, processor: processor, closed: false)
        default:
            return .continue
        }
    }

    public func handleCommandText(
        _ text: String, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch awaitingValue {
        case .scale:
            awaitingValue = .none
            if let value = Double(input), value > 0 {
                scale = value
                engine.document.mlineScale = value
            }
            prompt(processor: processor)
            return .continue
        case .style:
            awaitingValue = .none
            if !input.isEmpty {
                let resolved = engine.document.mlineStyle(named: input)
                styleName = resolved.name
                engine.document.currentMlineStyleName = resolved.name
            }
            prompt(processor: processor)
            return .continue
        case .none:
            if input.uppercased() == "C" {
                return finalize(engine: engine, processor: processor, closed: true)
            }
            if input.uppercased() == "J" {
                justification = (justification + 1) % 3
                engine.document.mlineJustification = justification
                prompt(processor: processor)
                return .continue
            }
            return finalize(engine: engine, processor: processor, closed: false)
        }
    }

    private func justificationName() -> String {
        switch justification {
        case 0: return "Top"
        case 2: return "Bottom"
        default: return "Zero"
        }
    }

    private func prompt(processor: CADCommandProcessor) {
        let head = points.isEmpty ? "Specify first point" : "Specify next point"
        processor.commandPrompt =
            "\(head) [Justification/Scale/STyle] <J=\(justificationName()) S=\(fmt(scale)) ST=\(styleName)> (C closes, Enter finishes)."
        processor.commandLineActive = false
    }

    private func fmt(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    private func finalize(
        engine: PhrostEngine, processor: CADCommandProcessor, closed: Bool
    ) -> CommandResult {
        awaitingValue = .none
        guard points.count >= (closed ? 3 : 2) else {
            processor.commandPrompt = "Command cancelled."
            return .finished
        }
        let style = engine.document.mlineStyle(named: styleName)
        let primitives = MlineMath.bake(
            centerline: points, style: style, scale: scale,
            justification: justification, closed: closed)
        guard !primitives.isEmpty else {
            processor.commandPrompt = "Command cancelled."
            return .finished
        }
        var entity = CADEntity(
            layerID: engine.document.activeLayerID ?? UUID(),
            localGeometry: primitives)
        entity.xdata["dxf.mlineStyle"] = .string(style.name)
        entity.xdata["dxf.mlineScale"] = .double(scale)
        entity.xdata["dxf.mlineJustification"] = .int(justification)
        entity.xdata["dxf.mlineClosed"] = .int(closed ? 1 : 0)
        entity.xdata["dxf.mlineCenterline"] = .string(
            MlineMath.encodeCenterline(points))
        engine.document.addEntity(entity)
        engine.tabManager.markActiveDirty()
        processor.commandPrompt =
            "Multiline created with \(points.count) points (\(style.name))."
        return .finished
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {
        let drawList = igGetForegroundDrawList_ViewportPtr(nil)
        let col = makeCol32(0, 255, 128, 200)
        if points.count >= 2 {
            for i in 0..<(points.count - 1) {
                let p1 = EngineCameraManager.worldToScreen(
                    worldX: points[i].x, worldY: points[i].y, cam: cam)
                let p2 = EngineCameraManager.worldToScreen(
                    worldX: points[i + 1].x, worldY: points[i + 1].y, cam: cam)
                ImDrawListAddLine(
                    drawList, ImVec2(x: p1.x, y: p1.y), ImVec2(x: p2.x, y: p2.y),
                    col, 1.5)
            }
        }
        let dotCol = makeCol32(0, 200, 100, 255)
        for pt in points {
            let sp = EngineCameraManager.worldToScreen(
                worldX: pt.x, worldY: pt.y, cam: cam)
            ImDrawListAddCircleFilled(
                drawList, ImVec2(x: sp.x, y: sp.y), 3.0, dotCol, 0)
        }
    }
}
