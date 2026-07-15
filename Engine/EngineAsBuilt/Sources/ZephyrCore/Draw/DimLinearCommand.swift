// Sources/ZephyrCore/Draw/DimLinearCommand.swift
import Foundation
import CSDL3
import ImGui
import SwiftSDL

@MainActor
public final class DimLinearCommand: FeatureCommand {
    
    private enum State {
        case pickingFirstExtOrigin
        case pickingSecondExtOrigin
        case pickingDimLinePos
    }
    
    private var state: State = .pickingFirstExtOrigin
    private var defPoint1: Vector3?
    private var defPoint2: Vector3?
    private var currentMouseWorldX: Double = 0
    private var currentMouseWorldY: Double = 0
    
    public init() {}
    
    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        state = .pickingFirstExtOrigin
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
        
        switch state {
        case .pickingFirstExtOrigin:
            defPoint1 = snapPos
            state = .pickingSecondExtOrigin
            processor.commandPrompt = "Specify second extension line origin:"
            return .continue
            
        case .pickingSecondExtOrigin:
            defPoint2 = snapPos
            state = .pickingDimLinePos
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
        
        switch state {
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
            
            // Auto-detect horizontal vs vertical
            let midX = (p1.x + p2.x) / 2.0
            let midY = (p1.y + p2.y) / 2.0
            let dx = abs(dimLinePos.x - midX)
            let dy = abs(dimLinePos.y - midY)
            let isHorizontal = dy > dx
            
            let dimStart: Vector3
            let dimEnd: Vector3

            if isHorizontal {
                dimStart = Vector3(x: p1.x, y: dimLinePos.y, z: 0)
                dimEnd = Vector3(x: p2.x, y: dimLinePos.y, z: 0)
            } else {
                dimStart = Vector3(x: dimLinePos.x, y: p1.y, z: 0)
                dimEnd = Vector3(x: dimLinePos.x, y: p2.y, z: 0)
            }
            
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
    
    private func commitDimension(p1: Vector3, p2: Vector3, dimLinePos: Vector3, engine: PhrostEngine, processor: CADCommandProcessor) {
        let midX = (p1.x + p2.x) / 2.0
        let midY = (p1.y + p2.y) / 2.0
        let dx = abs(dimLinePos.x - midX)
        let dy = abs(dimLinePos.y - midY)
        let isHorizontal = dy > dx
        
        let dimStart: Vector3
        let dimEnd: Vector3
        let dist: Double
        let angle: Double
        
        if isHorizontal {
            dimStart = Vector3(x: p1.x, y: dimLinePos.y, z: 0)
            dimEnd = Vector3(x: p2.x, y: dimLinePos.y, z: 0)
            dist = abs(p2.x - p1.x)
            angle = 0
        } else {
            dimStart = Vector3(x: dimLinePos.x, y: p1.y, z: 0)
            dimEnd = Vector3(x: dimLinePos.x, y: p2.y, z: 0)
            dist = abs(p2.y - p1.y)
            angle = .pi / 2
        }
        
        let textMidpoint = Vector3(x: (dimStart.x + dimEnd.x) / 2.0, y: (dimStart.y + dimEnd.y) / 2.0, z: 0)
        let style = CADDimensionStyle.default
        let color: ColorRGBA = .white
        let valueStr = style.formatMeasurement(dist)
        
        let metadata = CADDimensionMetadata(
            type: .linearOrRotated,
            measurement: dist,
            defPoint: dimLinePos,
            defPoint2: p1,
            defPoint3: p2,
            textMidpoint: textMidpoint,
            rotationAngle: angle
        )
        
        var primitives: [CADPrimitive] = []
        primitives.append(contentsOf: DimensionPrimitives.extensionLines(feature1: p1, feature2: p2, dimLineStart: dimStart, dimLineEnd: dimEnd, style: style, color: color))
        primitives.append(contentsOf: DimensionPrimitives.dimensionLine(from: dimStart, to: dimEnd, arrowAtStart: true, arrowAtEnd: true, style: style, color: color))
        primitives.append(DimensionPrimitives.dimensionText(position: textMidpoint, value: valueStr, rotation: angle, style: style, color: color))
        
        DimensionPrimitives.commitDimension(primitives: primitives, metadata: metadata, layerID: engine.document.activeLayerID ?? UUID(), document: engine.document)
    }
}
