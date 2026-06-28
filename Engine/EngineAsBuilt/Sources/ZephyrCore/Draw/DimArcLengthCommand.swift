// Sources/ZephyrCore/Draw/DimArcLengthCommand.swift
import Foundation
import CSDL3
import ImGui
import SwiftSDL

@MainActor
public final class DimArcLengthCommand: FeatureCommand {
    
    private enum State {
        case pickingArc
        case pickingDimensionPos
    }
    
    private var state: State = .pickingArc
    private var arcCenter: Vector3?
    private var arcRadius: Double?
    private var arcStartAngle: Double?
    private var arcEndAngle: Double?
    private var currentMouseWorldX: Double = 0
    private var currentMouseWorldY: Double = 0
    
    public init() {}
    
    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        state = .pickingArc
        arcCenter = nil
        arcRadius = nil
        arcStartAngle = nil
        arcEndAngle = nil
        processor.commandPrompt = "Select arc:"
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
        case .pickingArc:
            if let hitId = CADHitTesting.hitTest(worldX: worldX, worldY: worldY, document: engine.document),
               let entity = engine.document.entity(for: hitId),
               let geom = entity.resolvedGeometry(in: engine.document) {
                
                var found = false
                for prim in geom {
                    if case .arc(let center, let radius, let startAngle, let endAngle, _) = prim {
                        arcCenter = center
                        arcRadius = radius
                        arcStartAngle = startAngle
                        arcEndAngle = endAngle
                        found = true
                        break
                    }
                }
                
                if found {
                    state = .pickingDimensionPos
                    processor.commandPrompt = "Specify arc length dimension location:"
                    return .continue
                }
            }
            processor.commandPrompt = "Selected entity is not an arc. Select arc:"
            return .continue
            
        case .pickingDimensionPos:
            guard let center = arcCenter, let radius = arcRadius, let sa = arcStartAngle, let ea = arcEndAngle else { return .finished }
            let dimPos = engine.snap.currentSnapResult?.worldPos ?? Vector3(x: worldX, y: worldY, z: 0)
            
            commitDimension(center: center, radius: radius, startAngle: sa, endAngle: ea, dimPos: dimPos, engine: engine, processor: processor)
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
        case .pickingArc:
            break
        case .pickingDimensionPos:
            guard let center = arcCenter, let sa = arcStartAngle, let ea = arcEndAngle else { return }
            let dimPos = engine.snap.currentSnapResult?.worldPos ?? Vector3(x: currentMouseWorldX, y: currentMouseWorldY, z: 0)
            
            let dimRadius = hypot(dimPos.x - center.x, dimPos.y - center.y)
            
            // Draw arc
            let p1s = EngineCameraManager.worldToScreen(worldX: center.x + cos(sa)*dimRadius, worldY: center.y + sin(sa)*dimRadius, cam: cam)
            let p2s = EngineCameraManager.worldToScreen(worldX: center.x + cos(ea)*dimRadius, worldY: center.y + sin(ea)*dimRadius, cam: cam)
            
            ImDrawListAddLine(drawList, ImVec2(x: p1s.x, y: p1s.y), ImVec2(x: p2s.x, y: p2s.y), col, 1.5)
        }
    }
    
    private func commitDimension(center: Vector3, radius: Double, startAngle: Double, endAngle: Double, dimPos: Vector3, engine: PhrostEngine, processor: CADCommandProcessor) {
        let dimRadius = hypot(dimPos.x - center.x, dimPos.y - center.y)
        
        var sweep = endAngle - startAngle
        if sweep < 0 { sweep += 2 * .pi }
        
        let length = abs(sweep * radius)
        
        let style = CADDimensionStyle.default
        let color: ColorRGBA = .white
        
        // Use an arc symbol prefix or just format it
        let valueStr = style.formatMeasurement(length)
        
        let metadata = CADDimensionMetadata(
            type: .arcLength,
            measurement: length,
            defPoint: dimPos,
            defPoint2: Vector3(x: center.x + cos(startAngle)*radius, y: center.y + sin(startAngle)*radius, z: 0),
            defPoint3: Vector3(x: center.x + cos(endAngle)*radius, y: center.y + sin(endAngle)*radius, z: 0),
            textMidpoint: dimPos,
            rotationAngle: 0
        )
        
        var primitives: [CADPrimitive] = []
        // Arc line
        primitives.append(.arc(center: center, radius: dimRadius, startAngle: startAngle, endAngle: endAngle, color: color))
        
        // Extension lines
        let p1 = Vector3(x: center.x + cos(startAngle)*radius, y: center.y + sin(startAngle)*radius, z: 0)
        let p2 = Vector3(x: center.x + cos(endAngle)*radius, y: center.y + sin(endAngle)*radius, z: 0)
        let d1 = Vector3(x: center.x + cos(startAngle)*dimRadius, y: center.y + sin(startAngle)*dimRadius, z: 0)
        let d2 = Vector3(x: center.x + cos(endAngle)*dimRadius, y: center.y + sin(endAngle)*dimRadius, z: 0)
        
        primitives.append(.line(start: p1, end: d1, color: color))
        primitives.append(.line(start: p2, end: d2, color: color))
        
        // Arrowheads
        let a1Dir = Vector3(x: -sin(startAngle), y: cos(startAngle), z: 0)
        let a2Dir = Vector3(x: sin(endAngle), y: -cos(endAngle), z: 0)
        
        primitives.append(contentsOf: DimensionPrimitives.arrowhead(tip: d1, direction: a1Dir, size: style.arrowSize, color: color))
        primitives.append(contentsOf: DimensionPrimitives.arrowhead(tip: d2, direction: a2Dir, size: style.arrowSize, color: color))
        
        // Arc length symbol above text (simplified as an arc or just a text override)
        // We'll just append text for now
        primitives.append(DimensionPrimitives.dimensionText(position: dimPos, value: valueStr, rotation: 0, style: style, color: color))
        
        DimensionPrimitives.commitDimension(primitives: primitives, metadata: metadata, layerID: engine.document.activeLayerID ?? UUID(), document: engine.document)
    }
}
