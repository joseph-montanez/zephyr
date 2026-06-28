// Sources/ZephyrCore/Draw/DimOrdinateCommand.swift
import Foundation
import CSDL3
import ImGui
import SwiftSDL

@MainActor
public final class DimOrdinateCommand: FeatureCommand {
    
    private enum State {
        case pickingFeature
        case pickingLeaderEndpoint
    }
    
    private var state: State = .pickingFeature
    private var featurePoint: Vector3?
    private var currentMouseWorldX: Double = 0
    private var currentMouseWorldY: Double = 0
    
    public init() {}
    
    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        state = .pickingFeature
        featurePoint = nil
        processor.commandPrompt = "Specify feature location:"
    }
    
    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        processor.commandPrompt = "Command cancelled."
    }
    
    public func getDrawingSnapPoints() -> [Vector3] {
        var pts = [Vector3]()
        if let f = featurePoint { pts.append(f) }
        return pts
    }
    
    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        let snapPos = engine.snap.currentSnapResult?.worldPos ?? Vector3(x: worldX, y: worldY, z: 0)
        
        switch state {
        case .pickingFeature:
            featurePoint = snapPos
            state = .pickingLeaderEndpoint
            processor.commandPrompt = "Specify leader endpoint:"
            return .continue
            
        case .pickingLeaderEndpoint:
            guard let f = featurePoint else { return .finished }
            let leaderPos = snapPos
            
            commitDimension(feature: f, leader: leaderPos, engine: engine, processor: processor)
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
        case .pickingFeature:
            break
        case .pickingLeaderEndpoint:
            guard let f = featurePoint else { return }
            let leaderPos = engine.snap.currentSnapResult?.worldPos ?? Vector3(x: currentMouseWorldX, y: currentMouseWorldY, z: 0)
            
            let isXType = isOrdinateXType(feature: f, leader: leaderPos, engine: engine)
            
            let jogPos: Vector3
            if isXType {
                jogPos = Vector3(x: f.x, y: leaderPos.y, z: 0)
            } else {
                jogPos = Vector3(x: leaderPos.x, y: f.y, z: 0)
            }
            
            let fs = EngineCameraManager.worldToScreen(worldX: f.x, worldY: f.y, cam: cam)
            let js = EngineCameraManager.worldToScreen(worldX: jogPos.x, worldY: jogPos.y, cam: cam)
            let ls = EngineCameraManager.worldToScreen(worldX: leaderPos.x, worldY: leaderPos.y, cam: cam)
            
            ImDrawListAddLine(drawList, ImVec2(x: fs.x, y: fs.y), ImVec2(x: js.x, y: js.y), col, 1.5)
            ImDrawListAddLine(drawList, ImVec2(x: js.x, y: js.y), ImVec2(x: ls.x, y: ls.y), col, 1.5)
        }
    }
    
    private func isOrdinateXType(feature: Vector3, leader: Vector3, engine: PhrostEngine) -> Bool {
        let dx = abs(leader.x - feature.x)
        let dy = abs(leader.y - feature.y)
        
        let vw = Double(engine.windowWidth)
        let vh = Double(engine.windowHeight)
        
        if vw > 0 && vh > 0 {
            return (dx / vw) < (dy / vh)
        }
        return dy > dx
    }
    
    private func commitDimension(feature: Vector3, leader: Vector3, engine: PhrostEngine, processor: CADCommandProcessor) {
        let isXType = isOrdinateXType(feature: feature, leader: leader, engine: engine)
        
        let jogPos: Vector3
        let textValue: Double
        
        if isXType {
            jogPos = Vector3(x: feature.x, y: leader.y, z: 0)
            textValue = feature.x
        } else {
            jogPos = Vector3(x: leader.x, y: feature.y, z: 0)
            textValue = feature.y
        }
        
        let style = CADDimensionStyle.default
        let color: ColorRGBA = .white
        let valueStr = style.formatMeasurement(textValue)
        
        var flags = 0
        if isXType { flags |= (1 << 6) } // Bit 6 for X-type ordinate
        
        let metadata = CADDimensionMetadata(
            type: .ordinate,
            measurement: textValue,
            defPoint: feature,
            defPoint2: leader,
            defPoint3: jogPos,
            textMidpoint: leader,
            rotationAngle: 0,
            flags: flags
        )
        
        var primitives: [CADPrimitive] = []
        // Leader
        primitives.append(.line(start: feature, end: jogPos, color: color))
        primitives.append(.line(start: jogPos, end: leader, color: color))
        
        // Text
        primitives.append(DimensionPrimitives.dimensionText(position: leader, value: valueStr, rotation: 0, style: style, color: color))
        
        DimensionPrimitives.commitDimension(primitives: primitives, metadata: metadata, layerID: engine.document.activeLayerID ?? UUID(), document: engine.document)
    }
}
