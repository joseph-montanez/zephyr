// Sources/ZephyrCore/Draw/DimJoggedCommand.swift
import Foundation
import CSDL3
import ImGui
import SwiftSDL

@MainActor
public final class DimJoggedCommand: FeatureCommand {
    
    private enum State {
        case pickingArcOrCircle
        case pickingCenterOverride
        case pickingDimensionPos
        case pickingJogPos
    }
    
    private var state: State = .pickingArcOrCircle
    private var arcCenter: Vector3?
    private var arcRadius: Double?
    private var centerOverride: Vector3?
    private var dimensionPos: Vector3?
    
    private var currentMouseWorldX: Double = 0
    private var currentMouseWorldY: Double = 0
    
    public init() {}
    
    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        state = .pickingArcOrCircle
        arcCenter = nil
        arcRadius = nil
        centerOverride = nil
        dimensionPos = nil
        processor.commandPrompt = "Select arc or circle:"
    }
    
    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        processor.commandPrompt = "Command cancelled."
    }
    
    public func getDrawingSnapPoints() -> [Vector3] {
        var pts = [Vector3]()
        if let c = arcCenter { pts.append(c) }
        if let c = centerOverride { pts.append(c) }
        return pts
    }
    
    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        let snapPos = engine.snap.currentSnapResult?.worldPos ?? Vector3(x: worldX, y: worldY, z: 0)
        
        switch state {
        case .pickingArcOrCircle:
            if let hitId = CADHitTesting.hitTest(worldX: worldX, worldY: worldY, document: engine.document),
               let entity = engine.document.entity(for: hitId),
               let geom = entity.resolvedGeometry(in: engine.document) {
                
                var found = false
                for prim in geom {
                    if case .circle(let center, let radius, _) = prim {
                        arcCenter = center
                        arcRadius = radius
                        found = true
                        break
                    } else if case .arc(let center, let radius, _, _, _) = prim {
                        arcCenter = center
                        arcRadius = radius
                        found = true
                        break
                    }
                }
                
                if found {
                    state = .pickingCenterOverride
                    processor.commandPrompt = "Specify center location override:"
                    return .continue
                }
            }
            processor.commandPrompt = "Selected entity is not an arc or circle. Select arc or circle:"
            return .continue
            
        case .pickingCenterOverride:
            centerOverride = snapPos
            state = .pickingDimensionPos
            processor.commandPrompt = "Specify dimension line location:"
            return .continue
            
        case .pickingDimensionPos:
            dimensionPos = snapPos
            state = .pickingJogPos
            processor.commandPrompt = "Specify jog location:"
            return .continue
            
        case .pickingJogPos:
            guard let center = arcCenter, let radius = arcRadius, let override = centerOverride, let dimPos = dimensionPos else { return .finished }
            let jogPos = snapPos
            
            commitDimension(center: center, radius: radius, override: override, dimPos: dimPos, jogPos: jogPos, engine: engine, processor: processor)
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
        
        switch state {
        case .pickingArcOrCircle:
            break
        case .pickingCenterOverride:
            guard let center = arcCenter else { return }
            let cur = engine.snap.currentSnapResult?.worldPos ?? Vector3(x: currentMouseWorldX, y: currentMouseWorldY, z: 0)
            let cs = EngineCameraManager.worldToScreen(worldX: center.x, worldY: center.y, cam: cam)
            let curs = EngineCameraManager.worldToScreen(worldX: cur.x, worldY: cur.y, cam: cam)
            // Just show a line from actual center to override center
            ImDrawListAddLine(drawList, ImVec2(x: cs.x, y: cs.y), ImVec2(x: curs.x, y: curs.y), col, 1.0)
        case .pickingDimensionPos:
            guard let override = centerOverride else { return }
            let dimPos = engine.snap.currentSnapResult?.worldPos ?? Vector3(x: currentMouseWorldX, y: currentMouseWorldY, z: 0)
            let os = EngineCameraManager.worldToScreen(worldX: override.x, worldY: override.y, cam: cam)
            let ds = EngineCameraManager.worldToScreen(worldX: dimPos.x, worldY: dimPos.y, cam: cam)
            ImDrawListAddLine(drawList, ImVec2(x: os.x, y: os.y), ImVec2(x: ds.x, y: ds.y), col, 1.5)
        case .pickingJogPos:
            guard let override = centerOverride, let dimPos = dimensionPos else { return }
            let jogPos = engine.snap.currentSnapResult?.worldPos ?? Vector3(x: currentMouseWorldX, y: currentMouseWorldY, z: 0)
            
            let os = EngineCameraManager.worldToScreen(worldX: override.x, worldY: override.y, cam: cam)
            let ds = EngineCameraManager.worldToScreen(worldX: dimPos.x, worldY: dimPos.y, cam: cam)
            let js = EngineCameraManager.worldToScreen(worldX: jogPos.x, worldY: jogPos.y, cam: cam)
            
            // Simple visual for jog
            ImDrawListAddLine(drawList, ImVec2(x: os.x, y: os.y), ImVec2(x: js.x, y: js.y), col, 1.5)
            ImDrawListAddLine(drawList, ImVec2(x: js.x, y: js.y), ImVec2(x: ds.x, y: ds.y), col, 1.5)
        }
    }
    
    private func commitDimension(center: Vector3, radius: Double, override: Vector3, dimPos: Vector3, jogPos: Vector3, engine: PhrostEngine, processor: CADCommandProcessor) {
        
        let dir = Vector3(x: dimPos.x - override.x, y: dimPos.y - override.y, z: 0)
        guard hypot(dir.x, dir.y) > 0 else { return }
        
        let n = dir.normalized
        let arcPoint = Vector3(x: center.x + n.x * radius, y: center.y + n.y * radius, z: 0)
        
        let style = CADDimensionStyle.default
        let color: ColorRGBA = .white
        let valueStr = style.formatMeasurement(radius, prefix: "R")
        
        let angle = atan2(n.y, n.x)
        
        let metadata = CADDimensionMetadata(
            type: .jogged,
            measurement: radius,
            defPoint: center, // actual center
            defPoint2: arcPoint,
            defPoint3: jogPos,
            textMidpoint: dimPos,
            rotationAngle: angle
        )
        
        var primitives: [CADPrimitive] = []
        // Leader
        primitives.append(.line(start: override, end: jogPos, color: color))
        
        // Let's create a simple jog zigzag
        let jogDir = n
        let jogPerp = Vector3(x: -jogDir.y, y: jogDir.x, z: 0)
        let jogSize = 2.0
        let j1 = Vector3(x: jogPos.x + jogPerp.x * jogSize, y: jogPos.y + jogPerp.y * jogSize, z: 0)
        let j2 = Vector3(x: jogPos.x - jogPerp.x * jogSize + jogDir.x * jogSize, y: jogPos.y - jogPerp.y * jogSize + jogDir.y * jogSize, z: 0)
        let j3 = Vector3(x: jogPos.x + jogDir.x * jogSize, y: jogPos.y + jogDir.y * jogSize, z: 0)
        
        primitives.append(.line(start: jogPos, end: j1, color: color))
        primitives.append(.line(start: j1, end: j2, color: color))
        primitives.append(.line(start: j2, end: j3, color: color))
        primitives.append(.line(start: j3, end: dimPos, color: color))
        
        // Arrowhead
        primitives.append(contentsOf: DimensionPrimitives.arrowhead(tip: arcPoint, direction: Vector3(x: -n.x, y: -n.y, z: 0), size: style.arrowSize, color: color))
        
        // Text
        primitives.append(DimensionPrimitives.dimensionText(position: dimPos, value: valueStr, rotation: 0, style: style, color: color))
        
        DimensionPrimitives.commitDimension(primitives: primitives, metadata: metadata, layerID: engine.document.activeLayerID ?? UUID(), document: engine.document)
    }
}
