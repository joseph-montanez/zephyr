// Sources/ZephyrCore/Draw/DimDiameterCommand.swift
import Foundation
import CSDL3
import ImGui
import SwiftSDL

@MainActor
public final class DimDiameterCommand: FeatureCommand {
    
    private enum State {
        case pickingArcOrCircle
        case pickingTextLocation
    }
    
    private var state: State = .pickingArcOrCircle
    private var arcCenter: Vector3?
    private var arcRadius: Double?
    private var currentMouseWorldX: Double = 0
    private var currentMouseWorldY: Double = 0
    
    public init() {}
    
    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        state = .pickingArcOrCircle
        arcCenter = nil
        arcRadius = nil
        processor.commandPrompt = "Select arc or circle:"
    }
    
    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        processor.commandPrompt = "Command cancelled."
    }
    
    public func getDrawingSnapPoints() -> [Vector3] {
        var pts = [Vector3]()
        if let c = arcCenter { pts.append(c) }
        return pts
    }
    
    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        
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
                    state = .pickingTextLocation
                    processor.commandPrompt = "Specify dimension text location:"
                    return .continue
                }
            }
            processor.commandPrompt = "Selected entity is not an arc or circle. Select arc or circle:"
            return .continue
            
        case .pickingTextLocation:
            guard let center = arcCenter, let radius = arcRadius else { return .finished }
            let textLoc = engine.snap.currentSnapResult?.worldPos ?? Vector3(x: worldX, y: worldY, z: 0)
            
            commitDimension(center: center, radius: radius, textLoc: textLoc, engine: engine, processor: processor)
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
        case .pickingTextLocation:
            guard let center = arcCenter, let radius = arcRadius else { return }
            let textLoc = engine.snap.currentSnapResult?.worldPos ?? Vector3(x: currentMouseWorldX, y: currentMouseWorldY, z: 0)
            
            let dir = Vector3(x: textLoc.x - center.x, y: textLoc.y - center.y, z: 0)
            guard hypot(dir.x, dir.y) > 0 else { return }
            
            let n = dir.normalized
            let p1World = Vector3(x: center.x - n.x * radius, y: center.y - n.y * radius, z: 0)
            let p2World = Vector3(x: center.x + n.x * radius, y: center.y + n.y * radius, z: 0)
            
            let p1 = EngineCameraManager.worldToScreen(worldX: p1World.x, worldY: p1World.y, cam: cam)
            let p2 = EngineCameraManager.worldToScreen(worldX: p2World.x, worldY: p2World.y, cam: cam)
            let t2 = EngineCameraManager.worldToScreen(worldX: textLoc.x, worldY: textLoc.y, cam: cam)
            
            ImDrawListAddLine(drawList, ImVec2(x: p1.x, y: p1.y), ImVec2(x: p2.x, y: p2.y), col, 1.5)
            ImDrawListAddLine(drawList, ImVec2(x: p2.x, y: p2.y), ImVec2(x: t2.x, y: t2.y), col, 1.5)
        }
    }
    
    private func commitDimension(center: Vector3, radius: Double, textLoc: Vector3, engine: PhrostEngine, processor: CADCommandProcessor) {
        let dir = Vector3(x: textLoc.x - center.x, y: textLoc.y - center.y, z: 0)
        guard hypot(dir.x, dir.y) > 0 else { return }
        
        let n = dir.normalized
        let p1World = Vector3(x: center.x - n.x * radius, y: center.y - n.y * radius, z: 0)
        let p2World = Vector3(x: center.x + n.x * radius, y: center.y + n.y * radius, z: 0)
        
        let style = CADDimensionStyle.default
        let color: ColorRGBA = .white
        let valueStr = style.formatMeasurement(radius * 2, prefix: "Ø")
        
        let angle = atan2(n.y, n.x)
        
        let metadata = CADDimensionMetadata(
            type: .diameter,
            measurement: radius * 2,
            defPoint: p1World,
            defPoint2: p2World,
            defPoint3: nil,
            textMidpoint: textLoc,
            rotationAngle: angle
        )
        
        var primitives: [CADPrimitive] = []
        // Diameter line
        primitives.append(.line(start: p1World, end: p2World, color: color))
        // Leader line
        primitives.append(.line(start: p2World, end: textLoc, color: color))
        
        // Arrowheads
        primitives.append(contentsOf: DimensionPrimitives.arrowhead(tip: p1World, direction: n, size: style.arrowSize, color: color))
        primitives.append(contentsOf: DimensionPrimitives.arrowhead(tip: p2World, direction: Vector3(x: -n.x, y: -n.y, z: 0), size: style.arrowSize, color: color))
        
        // Horizontal text tail if text is outside
        let textTailLength: Double = 5.0
        let tailEnd = Vector3(x: textLoc.x + (n.x >= 0 ? textTailLength : -textTailLength), y: textLoc.y, z: 0)
        primitives.append(.line(start: textLoc, end: tailEnd, color: color))
        
        // Text
        let textPos = Vector3(x: textLoc.x + (n.x >= 0 ? textTailLength/2 : -textTailLength/2), y: textLoc.y + style.textOffset, z: 0)
        primitives.append(DimensionPrimitives.dimensionText(position: textPos, value: valueStr, rotation: 0, style: style, color: color))
        
        DimensionPrimitives.commitDimension(primitives: primitives, metadata: metadata, layerID: engine.document.activeLayerID ?? UUID(), document: engine.document)
    }
}
