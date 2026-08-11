import Foundation
import CSDL3
import ImGui
import SwiftSDL

@MainActor
public final class ClipCommand: FeatureCommand {
    private enum State {
        case selectingTargets
        case options
        case boundaryMethod
        case selectingPolyline
        case rectangleFirst
        case rectangleSecond(Vector3)
        case polygonal
        case polygonArcMidpoint
        case polygonArcEndpoint(Vector3)
        case polygonLength
        case depthFront
        case depthBack(Double)
        case done
    }

    private var state: State = .selectingTargets
    private var targetHandles: [UUID] = []
    private var boundaryPoints: [Vector3] = []
    private var currentMouse = Vector3.zero
    private var preInvert = false

    public init() {}

    public var isSnappingEnabled: Bool {
        switch state {
        case .rectangleFirst, .rectangleSecond, .polygonal,
             .polygonArcMidpoint, .polygonArcEndpoint, .polygonLength:
            return true
        default:
            return false
        }
    }

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        targetHandles = engine.cadSelection.selectedHandles.compactMap { handle in
            guard let entity = engine.document.entity(for: handle),
                  CADClipMetadata.isSupportedTarget(entity) else { return nil }
            return handle
        }
        if targetHandles.isEmpty {
            state = .selectingTargets
            showCanvasPrompt(targetSelectionPrompt, processor: processor)
        } else {
            state = .options
            openTextPrompt(optionPrompt(engine: engine), processor: processor)
        }
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        boundaryPoints.removeAll()
        targetHandles.removeAll()
        state = .done
    }

    public func handleMouseClick(
        worldX: Double,
        worldY: Double,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        let point = Vector3(x: worldX, y: worldY, z: 0)
        switch state {
        case .selectingTargets:
            let rawPoint = rawWorldPoint(engine: engine)
            guard let handle = supportedTarget(
                at: rawPoint,
                engine: engine),
                  let entity = engine.document.entity(for: handle),
                  CADClipMetadata.isSupportedTarget(entity) else {
                processor.commandPrompt = "No clip-compatible object found. Click a block reference, raster image, or imported PDF underlay; press Enter when done."
                return .handled
            }

            let shiftHeld = engine.io?.pointee.KeyShift ?? false
            if shiftHeld, targetHandles.contains(handle) {
                targetHandles.removeAll { $0 == handle }
                engine.cadSelection.removeFromSelection(handle)
            } else if !targetHandles.contains(handle) {
                targetHandles.append(handle)
                engine.cadSelection.addToSelection(handle)
            }
            processor.commandPrompt = targetSelectionPrompt
            return .handled

        case .selectingPolyline:
            let rawPoint = rawWorldPoint(engine: engine)
            let threshold = max(8.0 / max(engine.camera.zoom, 0.001), 0.01)
            guard let handle = engine.cadSelection.hitTest(
                worldX: rawPoint.x,
                worldY: rawPoint.y,
                document: engine.document,
                threshold: threshold,
                simplifyComplexBlocks: false),
                  let entity = engine.document.entity(for: handle),
                  let points = straightBoundary(from: entity), points.count >= 3 else {
                processor.commandPrompt = "Select a straight-segment 2D polyline, polygon, or rectangle:"
                return .handled
            }
            return applyBoundary(points, engine: engine, processor: processor)

        case .rectangleFirst:
            state = .rectangleSecond(point)
            boundaryPoints = [point]
            processor.commandPrompt = "Specify opposite corner:"
            return .handled

        case .rectangleSecond(let first):
            let points = [
                Vector3(x: first.x, y: first.y, z: 0),
                Vector3(x: point.x, y: first.y, z: 0),
                Vector3(x: point.x, y: point.y, z: 0),
                Vector3(x: first.x, y: point.y, z: 0)
            ]
            guard abs(point.x - first.x) > 1e-9, abs(point.y - first.y) > 1e-9 else {
                processor.commandPrompt = "Rectangle is too small. Specify opposite corner:"
                return .handled
            }
            return applyBoundary(points, engine: engine, processor: processor)

        case .polygonal:
            if boundaryPoints.last?.distance(to: point) ?? .infinity > 1e-9 {
                boundaryPoints.append(point)
            }
            processor.commandPrompt = polygonPrompt
            return .handled

        case .polygonArcMidpoint:
            guard !boundaryPoints.isEmpty else {
                state = .polygonal
                return .handled
            }
            state = .polygonArcEndpoint(point)
            processor.commandPrompt = "Specify arc endpoint:"
            return .handled

        case .polygonArcEndpoint(let midpoint):
            guard let start = boundaryPoints.last,
                  let arc = arcPoints(start: start, midpoint: midpoint, end: point) else {
                processor.commandPrompt = "Arc points are collinear. Specify arc midpoint:"
                state = .polygonArcMidpoint
                return .handled
            }
            boundaryPoints.append(contentsOf: arc.dropFirst())
            state = .polygonal
            processor.commandPrompt = polygonPrompt
            return .handled

        default:
            return .handled
        }
    }

    public func handleMouseMotion(
        worldX: Double,
        worldY: Double,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) {
        currentMouse = Vector3(x: worldX, y: worldY, z: 0)
    }

    public func handleKeyDown(
        scancode: SDL_Scancode,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        if scancode == SDL_SCANCODE_RETURN || scancode == SDL_SCANCODE_KP_ENTER {
            switch state {
            case .selectingTargets:
                guard !targetHandles.isEmpty else {
                    processor.commandPrompt = targetSelectionPrompt
                    return .handled
                }
                state = .options
                openTextPrompt(optionPrompt(engine: engine), processor: processor)
                return .handled
            case .options, .boundaryMethod:
                return handleCommandText("", engine: engine, processor: processor)
            case .polygonal:
                return closePolygon(engine: engine, processor: processor)
            default:
                return .handled
            }
        }
        return .continue
    }

    public func handleCommandText(
        _ text: String,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = value.uppercased()

        switch state {
        case .selectingTargets:
            if value.isEmpty, !targetHandles.isEmpty {
                state = .options
                openTextPrompt(optionPrompt(engine: engine), processor: processor)
            } else {
                showCanvasPrompt(targetSelectionPrompt, processor: processor)
            }
            return .handled

        case .options:
            switch upper {
            case "", "N", "NEW", "NEW BOUNDARY", "NEWBOUNDARY":
                preInvert = false
                state = .boundaryMethod
                openTextPrompt(boundaryMethodPrompt, processor: processor)
            case "ON":
                return updateClips(engine: engine, processor: processor) { $0.isEnabled = true }
            case "OFF":
                return updateClips(engine: engine, processor: processor) { $0.isEnabled = false }
            case "I", "INVERT", "INVERT CLIP", "INVERTCLIP":
                return updateClips(engine: engine, processor: processor) { $0.isInverted.toggle() }
            case "D", "DELETE":
                var changed: [CADEntity] = []
                for handle in targetHandles {
                    guard var entity = engine.document.entity(for: handle) else { continue }
                    CADClipMetadata.set(nil, on: &entity)
                    changed.append(entity)
                }
                engine.document.updateEntities(changed)
                engine.tabManager.markActiveDirty()
                processor.commandPrompt = "Clipping boundary deleted."
                return .finished
            case "G", "GENERATE", "GENERATE POLYLINE", "GENERATEPOLYLINE":
                return generatePolylines(engine: engine, processor: processor)
            case "C", "CLIPDEPTH":
                state = .depthFront
                openTextPrompt("Specify front clipping depth:", processor: processor)
            default:
                openTextPrompt(optionPrompt(engine: engine), processor: processor)
            }
            return .handled

        case .boundaryMethod:
            switch upper {
            case "S", "SELECT", "SELECT POLYLINE", "SELECTPOLYLINE":
                state = .selectingPolyline
                showCanvasPrompt("Select a straight-segment 2D polyline:", processor: processor)
            case "P", "POLYGONAL", "POLYGON":
                boundaryPoints.removeAll()
                state = .polygonal
                showCanvasPrompt(polygonPrompt, processor: processor)
            case "", "R", "RECTANGULAR", "RECTANGLE":
                boundaryPoints.removeAll()
                state = .rectangleFirst
                showCanvasPrompt("Specify first corner:", processor: processor)
            case "I", "INVERT", "INVERT CLIP", "INVERTCLIP":
                preInvert.toggle()
                openTextPrompt(boundaryMethodPrompt, processor: processor)
            default:
                openTextPrompt(boundaryMethodPrompt, processor: processor)
            }
            return .handled

        case .polygonal:
            switch upper {
            case "", "C", "CLOSE":
                return closePolygon(engine: engine, processor: processor)
            case "U", "UNDO":
                if !boundaryPoints.isEmpty { boundaryPoints.removeLast() }
                showCanvasPrompt(polygonPrompt, processor: processor)
            case "A", "ARC":
                guard !boundaryPoints.isEmpty else {
                    processor.commandPrompt = "Specify the first polygon vertex before Arc."
                    return .handled
                }
                state = .polygonArcMidpoint
                showCanvasPrompt("Specify arc midpoint:", processor: processor)
            case "L", "LENGTH":
                guard !boundaryPoints.isEmpty else {
                    processor.commandPrompt = "Specify the first polygon vertex before Length."
                    return .handled
                }
                state = .polygonLength
                openTextPrompt("Specify segment length:", processor: processor)
            default:
                openTextPrompt(polygonPrompt, processor: processor)
            }
            return .handled

        case .polygonLength:
            guard let length = Double(value), length > 1e-9, let start = boundaryPoints.last else {
                openTextPrompt("Enter a positive segment length:", processor: processor)
                return .handled
            }
            let dx = currentMouse.x - start.x
            let dy = currentMouse.y - start.y
            let magnitude = hypot(dx, dy)
            let ux = magnitude > 1e-9 ? dx / magnitude : 1.0
            let uy = magnitude > 1e-9 ? dy / magnitude : 0.0
            boundaryPoints.append(Vector3(x: start.x + ux * length, y: start.y + uy * length, z: 0))
            state = .polygonal
            showCanvasPrompt(polygonPrompt, processor: processor)
            return .handled

        case .depthFront:
            guard let depth = Double(value) else {
                openTextPrompt("Specify front clipping depth:", processor: processor)
                return .handled
            }
            state = .depthBack(depth)
            openTextPrompt("Specify back clipping depth:", processor: processor)
            return .handled

        case .depthBack(let front):
            guard let back = Double(value) else {
                openTextPrompt("Specify back clipping depth:", processor: processor)
                return .handled
            }
            return updateClips(engine: engine, processor: processor) {
                $0.frontDepth = front
                $0.backDepth = back
            }

        default:
            return .handled
        }
    }

    public func commandTextOptions(for input: String) -> [FeatureCommandTextOption] {
        let options: [FeatureCommandTextOption]
        switch state {
        case .options:
            options = [
                .init(value: "N", title: "New boundary", aliases: ["NEW"]),
                .init(value: "ON", title: "ON"),
                .init(value: "OFF", title: "OFF"),
                .init(value: "I", title: "Invert clip", aliases: ["INVERT"]),
                .init(value: "D", title: "Delete", aliases: ["DELETE"]),
                .init(value: "G", title: "Generate Polyline", aliases: ["GENERATE"]),
                .init(value: "C", title: "Clipdepth", aliases: ["CLIPDEPTH"])
            ]
        case .boundaryMethod:
            options = [
                .init(value: "S", title: "Select Polyline", aliases: ["SELECT"]),
                .init(value: "P", title: "Polygonal", aliases: ["POLYGON"]),
                .init(value: "R", title: "Rectangular", aliases: ["RECTANGLE"]),
                .init(value: "I", title: "Invert clip", aliases: ["INVERT"])
            ]
        case .polygonal:
            options = [
                .init(value: "A", title: "Arc"),
                .init(value: "C", title: "Close"),
                .init(value: "L", title: "Length"),
                .init(value: "U", title: "Undo")
            ]
        default:
            options = []
        }
        return options.filter { $0.matches(input) }
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {
        var points = boundaryPoints
        switch state {
        case .rectangleSecond(let first):
            points = [
                first,
                Vector3(x: currentMouse.x, y: first.y, z: 0),
                currentMouse,
                Vector3(x: first.x, y: currentMouse.y, z: 0),
                first
            ]
        case .polygonal, .polygonArcMidpoint, .polygonLength:
            if !points.isEmpty { points.append(currentMouse) }
        case .polygonArcEndpoint(let midpoint):
            if let start = points.last, let arc = arcPoints(start: start, midpoint: midpoint, end: currentMouse) {
                points.append(contentsOf: arc.dropFirst())
            }
        default:
            break
        }
        guard points.count >= 2 else { return }
        let drawList = igGetForegroundDrawList_ViewportPtr(nil)
        let color = UInt32(0xFF80FF00)
        for i in 0..<(points.count - 1) {
            let a = EngineCameraManager.worldToScreen(worldX: points[i].x, worldY: points[i].y, cam: cam)
            let b = EngineCameraManager.worldToScreen(worldX: points[i + 1].x, worldY: points[i + 1].y, cam: cam)
            ImDrawListAddLine(
                drawList,
                ImVec2(x: a.x, y: a.y),
                ImVec2(x: b.x, y: b.y),
                color,
                1.5)
        }
    }

    public func getDrawingSnapPoints() -> [Vector3] { boundaryPoints }

    private var polygonPrompt: String {
        "Specify next point or [Arc/Close/Length/Undo]:"
    }

    private var boundaryMethodPrompt: String {
        "Specify clipping boundary [Select Polyline/Polygonal/Rectangular/Invert clip] <Rectangular>:"
    }

    private func openTextPrompt(_ prompt: String, processor: CADCommandProcessor) {
        processor.commandPrompt = prompt
        processor.commandBuffer = ""
        processor.commandSelectionIndex = 0
        processor.commandLineActive = true
    }

    private func showCanvasPrompt(_ prompt: String, processor: CADCommandProcessor) {
        processor.commandPrompt = prompt
        processor.commandBuffer = ""
        processor.commandSelectionIndex = 0
        processor.commandLineActive = false
    }

    private var targetSelectionPrompt: String {
        if targetHandles.isEmpty {
            return "Select block reference, raster image, or imported PDF underlay; press Enter when done."
        }
        return "CLIP selected \(targetHandles.count) object(s). Select more, Shift-click to remove, or press Enter."
    }

    private func rawWorldPoint(engine: PhrostEngine) -> Vector3 {
        let (worldX, worldY) = engine.camera.screenToWorld(
            screenX: Float(engine.interaction.lastMouseX),
            screenY: Float(engine.interaction.lastMouseY),
            windowWidth: engine.windowWidth,
            windowHeight: engine.windowHeight)
        return Vector3(x: worldX, y: worldY, z: 0)
    }

    private func supportedTarget(
        at point: Vector3,
        engine: PhrostEngine
    ) -> UUID? {
        let threshold = max(8.0 / max(engine.camera.zoom, 0.001), 0.01)
        if let handle = engine.cadSelection.hitTest(
            worldX: point.x,
            worldY: point.y,
            document: engine.document,
            threshold: threshold,
            simplifyComplexBlocks: false),
           let entity = engine.document.entity(for: handle),
           CADClipMetadata.isSupportedTarget(entity) {
            return handle
        }

        var bestHandle: UUID?
        var bestDrawOrder = Int.min
        var bestArea = Double.infinity
        for entity in engine.document.entitiesView {
            guard CADClipMetadata.isSupportedTarget(entity),
                  let layer = engine.document.layer(for: entity.layerID),
                  layer.isVisible,
                  let bounds = entity.worldBoundingBox,
                  bounds.expanded(by: threshold).contains(point)
            else { continue }

            let area = bounds.area
            if entity.drawOrder > bestDrawOrder
                || (entity.drawOrder == bestDrawOrder && area < bestArea) {
                bestHandle = entity.handle
                bestDrawOrder = entity.drawOrder
                bestArea = area
            }
        }
        return bestHandle
    }

    private func optionPrompt(engine: PhrostEngine) -> String {
        let hasBoundary = targetHandles.contains { handle in
            engine.document.entity(for: handle).flatMap { CADClipMetadata.value(from: $0) } != nil
        }
        return hasBoundary
            ? "Enter clipping option [ON/OFF/Clipdepth/Delete/generate Polyline/Invert clip/New boundary] <New boundary>:"
            : "Enter clipping option [New boundary] <New boundary>:"
    }

    private func closePolygon(engine: PhrostEngine, processor: CADCommandProcessor) -> CommandResult {
        guard boundaryPoints.count >= 3 else {
            processor.commandPrompt = "A clipping polygon requires at least three vertices."
            return .handled
        }
        return applyBoundary(boundaryPoints, engine: engine, processor: processor)
    }

    private func applyBoundary(
        _ worldPoints: [Vector3],
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        var changed: [CADEntity] = []
        for handle in targetHandles {
            guard var entity = engine.document.entity(for: handle) else { continue }
            let inverse = entity.transform.inverse()
            let local = worldPoints.map(inverse.transformPoint)
            let old = CADClipMetadata.value(from: entity)
            let clip = CADClipData(
                boundary: local,
                isEnabled: true,
                isInverted: preInvert,
                frontDepth: old?.frontDepth,
                backDepth: old?.backDepth)
            CADClipMetadata.set(clip, on: &entity)
            changed.append(entity)
        }
        guard !changed.isEmpty else {
            processor.commandPrompt = "No clip-capable objects selected."
            return .finished
        }
        engine.document.updateEntities(changed)
        engine.tabManager.markActiveDirty()
        processor.commandPrompt = "Clipping boundary applied to \(changed.count) object(s)."
        return .finished
    }

    private func updateClips(
        engine: PhrostEngine,
        processor: CADCommandProcessor,
        mutate: (inout CADClipData) -> Void
    ) -> CommandResult {
        var changed: [CADEntity] = []
        for handle in targetHandles {
            guard var entity = engine.document.entity(for: handle),
                  var clip = CADClipMetadata.value(from: entity) else { continue }
            mutate(&clip)
            CADClipMetadata.set(clip, on: &entity)
            changed.append(entity)
        }
        guard !changed.isEmpty else {
            processor.commandPrompt = "The selected object has no clipping boundary."
            return .finished
        }
        engine.document.updateEntities(changed)
        engine.tabManager.markActiveDirty()
        processor.commandPrompt = "Clipping boundary updated."
        return .finished
    }

    private func generatePolylines(
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        guard let layerID = engine.document.activeLayerID else {
            processor.commandPrompt = "No active layer."
            return .finished
        }
        var count = 0
        for handle in targetHandles {
            guard let entity = engine.document.entity(for: handle),
                  let clip = CADClipMetadata.value(from: entity),
                  clip.boundary.count >= 3 else { continue }
            let world = clip.boundary.map(entity.transform.transformPoint)
            let polyline = CADPolyline(points: world, isClosed: true)
            engine.document.addEntity(CADEntity(
                layerID: layerID,
                localGeometry: [.polyline(path: polyline)]))
            count += 1
        }
        if count > 0 { engine.tabManager.markActiveDirty() }
        processor.commandPrompt = count > 0
            ? "Generated \(count) clipping polyline(s)."
            : "The selected object has no clipping boundary."
        return .finished
    }

    private func straightBoundary(from entity: CADEntity) -> [Vector3]? {
        guard let geometry = entity.localGeometry else { return nil }
        for primitive in geometry {
            let local: [Vector3]?
            switch primitive {
            case .polyline(let path, _):
                local = path.hasBulges ? nil : path.points
            case .polygon(let points, _), .fillPolygon(let points, _):
                local = points
            case .rect(let origin, let size, _):
                local = [
                    origin,
                    Vector3(x: origin.x + size.x, y: origin.y, z: origin.z),
                    Vector3(x: origin.x + size.x, y: origin.y + size.y, z: origin.z),
                    Vector3(x: origin.x, y: origin.y + size.y, z: origin.z)
                ]
            default:
                local = nil
            }
            if let local, local.count >= 3 { return local.map(entity.transform.transformPoint) }
        }
        return nil
    }

    private func arcPoints(start: Vector3, midpoint: Vector3, end: Vector3) -> [Vector3]? {
        let ax = start.x, ay = start.y
        let bx = midpoint.x, by = midpoint.y
        let cx = end.x, cy = end.y
        let d = 2.0 * (ax * (by - cy) + bx * (cy - ay) + cx * (ay - by))
        guard abs(d) > 1e-12 else { return nil }
        let aa = ax * ax + ay * ay
        let bb = bx * bx + by * by
        let cc = cx * cx + cy * cy
        let center = Vector3(
            x: (aa * (by - cy) + bb * (cy - ay) + cc * (ay - by)) / d,
            y: (aa * (cx - bx) + bb * (ax - cx) + cc * (bx - ax)) / d,
            z: 0)
        let radius = center.distance(to: start)
        guard radius > 1e-9 else { return nil }
        let startAngle = atan2(start.y - center.y, start.x - center.x)
        let midAngle = atan2(midpoint.y - center.y, midpoint.x - center.x)
        let endAngle = atan2(end.y - center.y, end.x - center.x)
        let ccwSweep = normalized(endAngle - startAngle)
        let midSweep = normalized(midAngle - startAngle)
        let sweep = midSweep <= ccwSweep ? ccwSweep : ccwSweep - 2.0 * .pi
        let segments = max(8, Int(ceil(abs(sweep) * 12.0)))
        return (0...segments).map { index in
            let angle = startAngle + sweep * Double(index) / Double(segments)
            return Vector3(
                x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius,
                z: 0)
        }
    }

    private func normalized(_ angle: Double) -> Double {
        var value = angle.truncatingRemainder(dividingBy: 2.0 * .pi)
        if value < 0 { value += 2.0 * .pi }
        return value
    }
}

@MainActor
public final class ClipFrameVariableCommand: FeatureCommand {
    private let name: String

    public init(_ name: String) {
        self.name = name.uppercased()
    }

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        processor.commandPrompt = "Enter new value for \(name) <\(CADClipFrameSettings.value(name))>:"
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {}

    public func handleMouseClick(
        worldX: Double,
        worldY: Double,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult { .handled }

    public func handleMouseMotion(
        worldX: Double,
        worldY: Double,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) {}

    public func handleKeyDown(
        scancode: SDL_Scancode,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult { .handled }

    public func handleCommandText(
        _ text: String,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            processor.commandPrompt = "\(name) = \(CADClipFrameSettings.value(name))"
            return .finished
        }
        guard let number = Int(value), (0...2).contains(number) else {
            processor.commandPrompt = "Enter 0, 1, or 2 for \(name):"
            return .handled
        }
        CADClipFrameSettings.set(name, value: number)
        engine.document.markNeedsRegeneration()
        processor.commandPrompt = "\(name) = \(number)"
        return .finished
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}
    public var isSnappingEnabled: Bool { false }
    public func getDrawingSnapPoints() -> [Vector3] { [] }
}
