// Sources/ZephyrCore/Draw/DimAngularCommand.swift
import Foundation
import CSDL3
import ImGui
import SwiftSDL

@MainActor
public final class DimAngularCommand: FeatureCommand {
    
    private enum State {
        case pickingFirstEntityOrVertex
        case pickingSecondLine(firstLineStart: Vector3, firstLineEnd: Vector3)
        case pickingFirstPoint(vertex: Vector3)
        case pickingSecondPoint(vertex: Vector3, p1: Vector3)
        case pickingDimensionPos
    }
    
    private var state: State = .pickingFirstEntityOrVertex
    
    private var center: Vector3?
    private var p1: Vector3?
    private var p2: Vector3?
    
    private var currentMouseWorldX: Double = 0
    private var currentMouseWorldY: Double = 0
    
    public init() {}
    
    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        state = .pickingFirstEntityOrVertex
        center = nil
        p1 = nil
        p2 = nil
        processor.commandPrompt = "Select arc, circle, line, or specify vertex:"
    }
    
    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        processor.commandPrompt = "Command cancelled."
    }
    
    public func getDrawingSnapPoints() -> [Vector3] {
        var pts = [Vector3]()
        if let c = center { pts.append(c) }
        if let p = p1 { pts.append(p) }
        if let p = p2 { pts.append(p) }
        return pts
    }
    
    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        let snapPos = engine.snap.currentSnapResult?.worldPos ?? Vector3(x: worldX, y: worldY, z: 0)
        
        switch state {
        case .pickingFirstEntityOrVertex:
            if let hitId = CADHitTesting.hitTest(worldX: worldX, worldY: worldY, document: engine.document),
               let entity = engine.document.entity(for: hitId),
               let geom = entity.resolvedGeometry(in: engine.document) {
                
                for prim in geom {
                    if case .line(let start, let end, _) = prim {
                        state = .pickingSecondLine(firstLineStart: start, firstLineEnd: end)
                        processor.commandPrompt = "Select second line:"
                        return .continue
                    } else if case .arc(let center, let radius, let startAngle, let endAngle, _) = prim {
                        self.center = center
                        self.p1 = Vector3(x: center.x + cos(startAngle) * radius, y: center.y + sin(startAngle) * radius, z: 0)
                        self.p2 = Vector3(x: center.x + cos(endAngle) * radius, y: center.y + sin(endAngle) * radius, z: 0)
                        state = .pickingDimensionPos
                        processor.commandPrompt = "Specify dimension arc line location:"
                        return .continue
                    } else if case .circle(let center, let radius, _) = prim {
                        // For a circle, this click becomes the first point of the angle, wait for second
                        self.center = center
                        let dx = worldX - center.x
                        let dy = worldY - center.y
                        let angle = atan2(dy, dx)
                        self.p1 = Vector3(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius, z: 0)
                        state = .pickingSecondPoint(vertex: center, p1: self.p1!)
                        processor.commandPrompt = "Specify second angle endpoint:"
                        return .continue
                    }
                }
            }
            
            // If no entity was hit or it wasn't a line/arc/circle, treat as vertex
            self.center = snapPos
            state = .pickingFirstPoint(vertex: snapPos)
            processor.commandPrompt = "Specify first angle endpoint:"
            return .continue
            
        case .pickingSecondLine(let l1s, let l1e):
            if let hitId = CADHitTesting.hitTest(worldX: worldX, worldY: worldY, document: engine.document),
               let entity = engine.document.entity(for: hitId),
               let geom = entity.resolvedGeometry(in: engine.document) {
                for prim in geom {
                    if case .line(let l2s, let l2e, _) = prim {
                        // Find intersection of l1 and l2
                        let dir1 = Vector3(x: l1e.x - l1s.x, y: l1e.y - l1s.y, z: 0)
                        let dir2 = Vector3(x: l2e.x - l2s.x, y: l2e.y - l2s.y, z: 0)
                        if let intersection = CADGeometryMath.intersectRayLine(rayOrigin: l1s, rayDir: dir1, lineP1: l2s, lineP2: l2e) { // Roughly
                            self.center = intersection
                        } else {
                            // Assuming they intersect somewhere if not parallel
                            let cross = dir1.x * dir2.y - dir1.y * dir2.x
                            if abs(cross) > 1e-6 {
                                let dx1 = l2s.x - l1s.x
                                let dy1 = l2s.y - l1s.y
                                let t = (dx1 * dir2.y - dy1 * dir2.x) / cross
                                self.center = Vector3(x: l1s.x + dir1.x * t, y: l1s.y + dir1.y * t, z: 0)
                            } else {
                                processor.commandPrompt = "Lines are parallel."
                                return .continue
                            }
                        }
                        
                        // We will use the points clicked to determine which angle quadrant to use later,
                        // but for simplicity, we just use the line endpoints.
                        self.p1 = l1e
                        self.p2 = l2e
                        state = .pickingDimensionPos
                        processor.commandPrompt = "Specify dimension arc line location:"
                        return .continue
                    }
                }
            }
            processor.commandPrompt = "Select second line:"
            return .continue
            
        case .pickingFirstPoint(let v):
            self.p1 = snapPos
            state = .pickingSecondPoint(vertex: v, p1: snapPos)
            processor.commandPrompt = "Specify second angle endpoint:"
            return .continue
            
        case .pickingSecondPoint(let v, let p1):
            self.p2 = snapPos
            state = .pickingDimensionPos
            processor.commandPrompt = "Specify dimension arc line location:"
            return .continue
            
        case .pickingDimensionPos:
            guard let center = center, let p1 = p1, let p2 = p2 else { return .finished }
            commitDimension(center: center, p1: p1, p2: p2, dimPos: snapPos, engine: engine, processor: processor)
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
        case .pickingFirstEntityOrVertex:
            break
        case .pickingSecondLine:
            break
        case .pickingFirstPoint(let v):
            let vs = EngineCameraManager.worldToScreen(worldX: v.x, worldY: v.y, cam: cam)
            let cur = EngineCameraManager.worldToScreen(worldX: currentMouseWorldX, worldY: currentMouseWorldY, cam: cam)
            ImDrawListAddLine(drawList, ImVec2(x: vs.x, y: vs.y), ImVec2(x: cur.x, y: cur.y), col, 1.0)
        case .pickingSecondPoint(let v, let p1):
            let vs = EngineCameraManager.worldToScreen(worldX: v.x, worldY: v.y, cam: cam)
            let p1s = EngineCameraManager.worldToScreen(worldX: p1.x, worldY: p1.y, cam: cam)
            let cur = EngineCameraManager.worldToScreen(worldX: currentMouseWorldX, worldY: currentMouseWorldY, cam: cam)
            ImDrawListAddLine(drawList, ImVec2(x: vs.x, y: vs.y), ImVec2(x: p1s.x, y: p1s.y), col, 1.0)
            ImDrawListAddLine(drawList, ImVec2(x: vs.x, y: vs.y), ImVec2(x: cur.x, y: cur.y), col, 1.0)
        case .pickingDimensionPos:
            guard let center = center, let p1 = p1, let p2 = p2 else { return }
            let dimPos = engine.snap.currentSnapResult?.worldPos ?? Vector3(x: currentMouseWorldX, y: currentMouseWorldY, z: 0)
            
            let radius = hypot(dimPos.x - center.x, dimPos.y - center.y)
            let a1 = atan2(p1.y - center.y, p1.x - center.x)
            let a2 = atan2(p2.y - center.y, p2.x - center.x)
            
            // Draw arc
            // In a real app we'd draw the arc segment, here we just do a simple line for overlay
            let p1s = EngineCameraManager.worldToScreen(worldX: center.x + cos(a1)*radius, worldY: center.y + sin(a1)*radius, cam: cam)
            let p2s = EngineCameraManager.worldToScreen(worldX: center.x + cos(a2)*radius, worldY: center.y + sin(a2)*radius, cam: cam)
            
            ImDrawListAddLine(drawList, ImVec2(x: p1s.x, y: p1s.y), ImVec2(x: p2s.x, y: p2s.y), col, 1.5)
        }
    }
    
    private func commitDimension(center: Vector3, p1: Vector3, p2: Vector3, dimPos: Vector3, engine: PhrostEngine, processor: CADCommandProcessor) {
        let radius = hypot(dimPos.x - center.x, dimPos.y - center.y)
        let a1 = atan2(p1.y - center.y, p1.x - center.x)
        let a2 = atan2(p2.y - center.y, p2.x - center.x)
        
        var diff = a2 - a1
        if diff < 0 { diff += 2 * .pi }
        
        let style = CADDimensionStyle.default
        let color: ColorRGBA = .white
        let valueStr = style.formatAngle(diff)
        
        let metadata = CADDimensionMetadata(
            type: .angular,
            measurement: diff * 180 / .pi,
            defPoint: dimPos,
            defPoint2: p1,
            defPoint3: p2,
            defPoint4: center,
            textMidpoint: dimPos,
            rotationAngle: 0
        )
        
        var primitives: [CADPrimitive] = []
        // Arc line
        primitives.append(.arc(center: center, radius: radius, startAngle: a1, endAngle: a2, color: color))
        
        // Arrowheads
        let a1Dir = Vector3(x: -sin(a1), y: cos(a1), z: 0) // Tangent
        let a2Dir = Vector3(x: sin(a2), y: -cos(a2), z: 0) // Tangent
        let ap1 = Vector3(x: center.x + cos(a1)*radius, y: center.y + sin(a1)*radius, z: 0)
        let ap2 = Vector3(x: center.x + cos(a2)*radius, y: center.y + sin(a2)*radius, z: 0)
        
        primitives.append(contentsOf: DimensionPrimitives.arrowhead(tip: ap1, direction: a1Dir, size: style.arrowSize, color: color))
        primitives.append(contentsOf: DimensionPrimitives.arrowhead(tip: ap2, direction: a2Dir, size: style.arrowSize, color: color))
        
        // Text
        primitives.append(DimensionPrimitives.dimensionText(position: dimPos, value: valueStr, rotation: 0, style: style, color: color))
        
        DimensionPrimitives.commitDimension(primitives: primitives, metadata: metadata, layerID: engine.document.activeLayerID ?? UUID(), document: engine.document)
    }
}
