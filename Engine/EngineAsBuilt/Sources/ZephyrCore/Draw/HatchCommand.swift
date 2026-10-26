import Foundation
import CSDL3
import ImGui
import SwiftSDL

// =========================================================================
// MARK: - HatchCommand
// =========================================================================

/// AutoCAD-style hatch creation with a floating contextual ribbon.
///
/// Supports two selection modes:
///   - **Pick Points** — ray-cast + wall-follow boundary detection (default).
///   - **Select Boundary** — click an existing closed entity to use its geometry.
///
/// The floating ribbon (rendered via `renderImGui`) lets the user choose fill type,
/// pattern, angle, scale, colors, and selection mode *before* placing the hatch.
@MainActor
public final class HatchCommand: FeatureCommand {

    // MARK: - Selection mode

    enum HatchSelectionMode { case pickPoints, selectBoundary }

    // MARK: - Command state

    private enum State {
        case waitingForInternalPoint
        case completed
    }

    private var state: State = .waitingForInternalPoint
    private var currentMouseWorldX: Double = 0
    private var currentMouseWorldY: Double = 0

    // MARK: - Hatch settings (ribbon state)

    /// 0 = Pattern, 1 = Solid, 2 = Gradient
    private var fillType: Int32 = 1
    private var patternName: String = "ANSI31"
    private var gradientName: String = "LINEAR"
    private var hatchScale: Float = 1.0
    private var hatchAngle: Float = 0.0
    private var primaryColor: ColorRGBA? = nil       // nil = ByLayer
    private var backgroundColor: ColorRGBA? = nil    // nil = None
    private var secondaryColor: ColorRGBA? = nil     // for gradients
    private var selectionMode: HatchSelectionMode = .pickPoints
    private var islandStyle: Int32 = 0
    private var associative: Bool = true
    private var lastCreatedHatchHandle: UUID?
    private var hatchDragPreEditSnapshot: CADDocumentSnapshot?
    private var lastObservedUndoDepth: Int = -1

    public init() {}

    /// Preset pattern/scale/angle before `start` (used by the `-HATCH`
    /// command-line form). Callers validate the pattern name first
    /// (`DXFHatchGenerator.patternDefinition(for:)` or SOLID).
    public func preset(pattern: String? = nil, scale: Float? = nil, angle: Float? = nil) {
        if let pattern {
            let key = pattern.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if !key.isEmpty {
                patternName = key
                fillType = 0
            }
        }
        if let scale, scale > 0 { hatchScale = scale }
        if let angle { hatchAngle = angle }
    }

    internal var currentBackgroundColor: ColorRGBA? { backgroundColor }
    internal var currentFillType: Int32 { fillType }
    internal var currentIslandStyle: Int32 { islandStyle }
    internal var currentPatternName: String { patternName }

    // MARK: - FeatureCommand conformance

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        state = .waitingForInternalPoint
        currentMouseWorldX = 0
        currentMouseWorldY = 0
        lastCreatedHatchHandle = nil
        hatchDragPreEditSnapshot = nil

        if let handle = engine.cadSelection.lastSelectedHandle,
           let entity = engine.document.entity(for: handle) {
            initFromEntity(entity)
            lastCreatedHatchHandle = handle
        }

        lastObservedUndoDepth = engine.document.undoManager.undoDepth
        processor.commandPrompt = "HATCH: Click inside an enclosed area to fill (Esc to cancel)."
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        if let snapshot = hatchDragPreEditSnapshot {
            engine.document.pushUndo(snapshot)
            hatchDragPreEditSnapshot = nil
        }
        state = .completed
    }

    internal func initFromEntity(_ entity: CADEntity) {
        if let storedIsland = entity.xdata["dxf.hatchStyle"] {
            switch storedIsland {
            case .int(let v): islandStyle = Int32(v)
            case .double(let v): islandStyle = Int32(v)
            default: break
            }
        }

        if let storedAssoc = entity.xdata["dxf.hatchAssociative"] {
            switch storedAssoc {
            case .bool(let b): associative = b
            case .int(let v): associative = v != 0
            default: break
            }
        }

        if let storedScale = entity.xdata["dxf.hatchScale"] {
            switch storedScale {
            case .double(let v): hatchScale = Float(v)
            case .int(let v): hatchScale = Float(v)
            default: break
            }
        }

        if let storedAngle = entity.xdata["dxf.hatchAngle"] {
            switch storedAngle {
            case .double(let v): hatchAngle = Float(v)
            case .int(let v): hatchAngle = Float(v)
            default: break
            }
        }

        if case .string(let key)? = entity.xdata["zephyr.hatchPatternKey"] {
            let k = key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if !k.isEmpty { patternName = k }
        } else if case .string(let name)? = entity.xdata["dxf.hatchPatternName"] {
            let n = name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if !n.isEmpty { patternName = n }
        }

        if case .string(let hex)? = entity.xdata["zephyr.hatchBackgroundColor"],
           let bg = ColorRGBA(hex: hex) {
            backgroundColor = bg
        } else {
            backgroundColor = nil
        }

        guard let geometry = entity.localGeometry else { return }

        for prim in geometry {
            switch prim {
            case .gradient(_, _, let name, let angle, let c1, let c2):
                fillType = 2
                gradientName = name
                hatchAngle = Float(angle)
                primaryColor = c1
                secondaryColor = c2
                backgroundColor = nil
                return
            case .hatchPath(_, _, let pat, let scale, let angle, let color, let bg):
                fillType = 0
                patternName = pat.isEmpty ? patternName : pat
                hatchScale = Float(scale)
                hatchAngle = Float(angle)
                primaryColor = color
                secondaryColor = nil
                if bg != nil { backgroundColor = bg }
                return
            case .hatch(_, let pat, let scale, let angle, let color, let bg):
                fillType = 0
                patternName = pat.isEmpty ? patternName : pat
                hatchScale = Float(scale)
                hatchAngle = Float(angle)
                primaryColor = color
                secondaryColor = nil
                if bg != nil { backgroundColor = bg }
                return
            case .fillComplexPolygon(_, _, let color):
                fillType = 1
                primaryColor = color
                secondaryColor = nil
                backgroundColor = nil
            default:
                break
            }
        }
    }

    public var isSnappingEnabled: Bool { false }

    public func getDrawingSnapPoints() -> [Vector3] { [] }

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        guard case .waitingForInternalPoint = state else { return .finished }

        // ── Select Boundary mode ──
        if selectionMode == .selectBoundary {
            let threshold = 6.0 / engine.camera.zoom
            if let handle = engine.cadSelection.hitTest(
                worldX: worldX, worldY: worldY,
                document: engine.document,
                threshold: threshold,
                simplifyComplexBlocks: false),
               let entity = engine.document.entity(for: handle),
               let geometry = engine.document.resolvedGeometry(for: entity),
               let firstPrim = geometry.first {

                let worldPts = CADGeometryMath.worldPointsForPrimitive(
                    firstPrim, transform: entity.transform)
                if worldPts.count >= 3 {
                    let regions: [(outer: [Vector3], holes: [[Vector3]])]
                    if islandStyle == 2 {
                        regions = [(worldPts, [])]
                    } else {
                        let holes = CADBoundaryDetector.findHoleLoops(
                            inside: worldPts, seed: worldPts[0],
                            document: engine.document, epsilonSq: 1e-6)
                        if holes.isEmpty {
                            regions = [(worldPts, [])]
                        } else {
                            let classified = CADBoundaryDetector.classifyLoops(
                                [worldPts] + holes, islandStyle: Int(islandStyle))
                            regions = classified.map { ($0.outer, $0.holes) }
                        }
                    }
                    return commitHatch(regions: regions,
                                       engine: engine, processor: processor)
                }
            }
            processor.commandPrompt = "No closed boundary found at click location."
            return .continue
        }

        // ── Pick Points mode ──
        if let regions = CADBoundaryDetector.findEnclosingRegions(
            seedX: worldX, seedY: worldY,
            document: engine.document,
            islandStyle: Int(islandStyle),
            maxEdgeCount: 2000
        ), !regions.isEmpty {
            return commitHatch(regions: regions.map { ($0.outer, $0.holes) },
                               engine: engine, processor: processor)
        } else {
            processor.commandPrompt =
                "A closed boundary cannot be determined. Click inside a fully enclosed loop."
            return .continue
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
        switch scancode {
        case SDL_SCANCODE_ESCAPE, SDL_SCANCODE_RETURN, SDL_SCANCODE_KP_ENTER:
            if let snapshot = hatchDragPreEditSnapshot {
                engine.document.pushUndo(snapshot)
                hatchDragPreEditSnapshot = nil
            }
            state = .completed
            return .finished
        default:
            return .continue
        }
    }

    // MARK: - Commit / Apply

    /// Build hatch primitives from the current ribbon settings.
    private func buildPrimitives(boundary: [Vector3], holes: [[Vector3]]) -> [CADPrimitive] {
        let effectivePattern: String
        let effectiveColor: ColorRGBA?
        let effectiveBgColor: ColorRGBA?

        switch fillType {
        case 0:  // Pattern
            effectivePattern = patternName.isEmpty ? "SOLID" : patternName
            effectiveColor = primaryColor
            effectiveBgColor = backgroundColor
        case 1:  // Solid
            effectivePattern = "SOLID"
            effectiveColor = primaryColor
            effectiveBgColor = nil
        case 2:  // Gradient
            effectivePattern = "SOLID"
            effectiveColor = primaryColor ?? ColorRGBA(r: 128, g: 128, b: 128, a: 180)
            effectiveBgColor = nil
        default:
            effectivePattern = "SOLID"
            effectiveColor = nil
            effectiveBgColor = nil
        }

        let scale = Double(hatchScale)
        let angle = Double(hatchAngle)

        var prims: [CADPrimitive] = []
        if fillType == 2 {
            let c1 = primaryColor ?? ColorRGBA(r: 128, g: 128, b: 128, a: 255)
            let c2 = secondaryColor ?? ColorRGBA(
                r: UInt8(min(255, Int(c1.r) + 60)),
                g: UInt8(min(255, Int(c1.g) + 60)),
                b: UInt8(min(255, Int(c1.b) + 60)),
                a: c1.a)
            prims.append(.gradient(
                outer: boundary, holes: holes,
                gradientName: gradientName, angle: angle, color1: c1, color2: c2))
        } else if effectivePattern.uppercased() == "SOLID" || effectivePattern.isEmpty {
            prims.append(.fillComplexPolygon(
                outer: boundary, holes: holes, color: effectiveColor))
        } else {
            prims.append(.hatchPath(
                boundary: CADPolyline(points: boundary, isClosed: true),
                holes: holes.map { CADPolyline(points: $0, isClosed: true) },
                pattern: effectivePattern,
                scale: scale,
                angle: angle,
                color: effectiveColor,
                backgroundColor: effectiveBgColor))
        }
        return prims
    }

    private func extractAllBoundaryPaths(from entity: CADEntity) -> [CADPolyline] {
        guard let geometry = entity.localGeometry else { return [] }
        let carriers = geometry.compactMap { prim -> CADPolyline? in
            guard case .polyline(let path, _) = prim, path.isHatchBoundaryCarrier else { return nil }
            return path
        }
        if !carriers.isEmpty { return carriers }

        var paths: [CADPolyline] = []
        for prim in geometry {
            switch prim {
            case .hatchPath(let boundary, let holes, _, _, _, _, _):
                paths.append(boundary)
                paths.append(contentsOf: holes)
            case .hatch(let boundary, _, _, _, _, _):
                let loops = splitConnectedHatchBoundary(boundary)
                if loops.outer.count >= 3 { paths.append(CADPolyline(points: loops.outer, isClosed: true)) }
                for h in loops.holes where h.count >= 3 { paths.append(CADPolyline(points: h, isClosed: true)) }
            case .fillComplexPolygon(let outer, let holes, _):
                if outer.count >= 3 { paths.append(CADPolyline(points: outer, isClosed: true)) }
                for h in holes where h.count >= 3 { paths.append(CADPolyline(points: h, isClosed: true)) }
            case .gradient(let outer, let holes, _, _, _, _):
                if outer.count >= 3 { paths.append(CADPolyline(points: outer, isClosed: true)) }
                for h in holes where h.count >= 3 { paths.append(CADPolyline(points: h, isClosed: true)) }
            default:
                break
            }
        }
        return paths
    }

    /// Extract the outer boundary and holes from an existing hatch entity.
    private func extractBoundary(from entity: CADEntity) -> (outer: [Vector3], holes: [[Vector3]])? {
        guard let geometry = entity.localGeometry else { return nil }

        if let complex = geometry.compactMap({ prim -> (outer: [Vector3], holes: [[Vector3]])? in
            guard case .fillComplexPolygon(let outer, let holes, _) = prim else { return nil }
            return (normalizedLoop(outer), holes.map { normalizedLoop($0) }.filter { $0.count >= 3 })
        }).first {
            return complex.outer.count >= 3 ? complex : nil
        }

        if let gradient = geometry.compactMap({ prim -> (outer: [Vector3], holes: [[Vector3]])? in
            guard case .gradient(let outer, let holes, _, _, _, _) = prim else { return nil }
            return (normalizedLoop(outer), holes.map { normalizedLoop($0) }.filter { $0.count >= 3 })
        }).first {
            return gradient.outer.count >= 3 ? gradient : nil
        }

        let transparentLoops = geometry.compactMap { prim -> [Vector3]? in
            guard case .polygon(let points, let color) = prim, color?.a == 0 else { return nil }
            return normalizedLoop(points)
        }.filter { $0.count >= 3 }
        if !transparentLoops.isEmpty {
            let classified = classifyLoops(transparentLoops)
            return classified.outer.count >= 3 ? classified : nil
        }

        if let hatchPath = geometry.compactMap({ prim -> (outer: [Vector3], holes: [[Vector3]])? in
            guard case .hatchPath(let boundary, let holes, _, _, _, _, _) = prim else { return nil }
            return (normalizedLoop(boundary.tessellatedPoints()), holes.map { normalizedLoop($0.tessellatedPoints()) }.filter { $0.count >= 3 })
        }).first {
            return hatchPath.outer.count >= 3 ? hatchPath : nil
        }

        if let hatchBoundary = geometry.compactMap({ prim -> [Vector3]? in
            guard case .hatch(let boundary, _, _, _, _, _) = prim else { return nil }
            return boundary
        }).first {
            let split = splitConnectedHatchBoundary(hatchBoundary)
            return split.outer.count >= 3 ? split : nil
        }

        return nil
    }

    private func applyHatchXData(to entity: inout CADEntity) {
        entity.xdata.removeValue(forKey: "dxf.hatchRawBody")
        entity.xdata.removeValue(forKey: "dxf.hatchRawHandle")
        entity.xdata.removeValue(forKey: "dxf.hatchPatternLines")

        let patternKey: String
        switch fillType {
        case 0:
            let value = patternName.trimmingCharacters(in: .whitespacesAndNewlines)
            patternKey = value.isEmpty ? "ANSI31" : value.uppercased()
        case 2:
            patternKey = "GRADIENT"
        case 3:
            patternKey = "USER"
        default:
            patternKey = "SOLID"
        }

        let dxfPatternName = fillType == 0
            ? DXFHatchGenerator.patternExportName(for: patternKey)
            : patternKey
        let scale = Double(hatchScale)
        let definitionType = fillType == 3
            ? 0
            : DXFHatchGenerator.patternDefinitionType(for: patternKey)

        entity.xdata["zephyr.hatchPatternKey"] = .string(patternKey)
        entity.xdata["dxf.hatchPatternName"] = .string(dxfPatternName)
        entity.xdata["dxf.hatchPatternType"] = .string(DXFHatchGenerator.patternKindName(for: patternKey))
        entity.xdata["dxf.hatchPatternDefinitionType"] = .int(definitionType)
        entity.xdata["dxf.hatchScale"] = .double(scale)
        entity.xdata["dxf.hatchAngle"] = .double(Double(hatchAngle))
        entity.xdata["dxf.hatchSpacing"] = .double(
            DXFHatchGenerator.effectiveSpacing(patternName: patternKey, scale: scale))
        entity.xdata["dxf.hatchAssociative"] = .bool(associative)
        entity.xdata["dxf.hatchIsGradient"] = .bool(fillType == 2)
        entity.xdata["dxf.hatchStyle"] = .int(Int(islandStyle))

        if fillType == 2 {
            let c1 = primaryColor ?? ColorRGBA(r: 128, g: 128, b: 128, a: 255)
            let c2 = secondaryColor ?? ColorRGBA(
                r: UInt8(min(255, Int(c1.r) + 60)),
                g: UInt8(min(255, Int(c1.g) + 60)),
                b: UInt8(min(255, Int(c1.b) + 60)),
                a: c1.a)
            entity.xdata["dxf.hatchGradientName"] = .string(gradientName.uppercased())
            entity.xdata["dxf.hatchGradientAngle"] = .double(Double(hatchAngle))
            entity.xdata["dxf.hatchGradientSingleColor"] = .bool(false)
            entity.xdata["dxf.hatchGradientTint"] = .double(0.0)
            entity.xdata["dxf.hatchGradientStops"] = .string(gradientStopsJSON(c1, c2))
        } else {
            entity.xdata.removeValue(forKey: "dxf.hatchGradientName")
            entity.xdata.removeValue(forKey: "dxf.hatchGradientAngle")
            entity.xdata.removeValue(forKey: "dxf.hatchGradientShift")
            entity.xdata.removeValue(forKey: "dxf.hatchGradientTint")
            entity.xdata.removeValue(forKey: "dxf.hatchGradientSingleColor")
            entity.xdata.removeValue(forKey: "dxf.hatchGradientStops")
        }

        if fillType == 0, let bg = backgroundColor {
            let hex = String(format: "#%02X%02X%02X%02X", bg.r, bg.g, bg.b, bg.a)
            entity.xdata["zephyr.hatchBackgroundColor"] = .string(hex)
        } else {
            entity.xdata.removeValue(forKey: "zephyr.hatchBackgroundColor")
        }
    }

    private func gradientStopsJSON(_ first: ColorRGBA, _ second: ColorRGBA) -> String {
        func rgb(_ color: ColorRGBA) -> Int {
            (Int(color.r) << 16) | (Int(color.g) << 8) | Int(color.b)
        }
        let stops: [[String: Any]] = [
            ["position": 0.0, "aci": 0, "rgb": rgb(first)],
            ["position": 1.0, "aci": 0, "rgb": rgb(second)]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: stops),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    private func classifyLoops(_ loops: [[Vector3]]) -> (outer: [Vector3], holes: [[Vector3]]) {
        guard let outerIndex = loops.indices.max(by: { abs(loopArea(loops[$0])) < abs(loopArea(loops[$1])) }) else {
            return ([], [])
        }
        let outer = normalizedLoop(loops[outerIndex])
        let holes = loops.indices.filter { $0 != outerIndex }.map { normalizedLoop(loops[$0]) }.filter { $0.count >= 3 }
        return (outer, holes)
    }

    private func splitConnectedHatchBoundary(_ boundary: [Vector3]) -> (outer: [Vector3], holes: [[Vector3]]) {
        var points = normalizedLoop(boundary)
        var holes: [[Vector3]] = []

        while points.count >= 7 {
            var foundBridge: (start: Int, close: Int)? = nil

            if points.count > 4 {
                outerLoop: for start in 1..<(points.count - 2) {
                    let minClose = start + 3
                    guard minClose < points.count - 1 else { continue }
                    for close in minClose..<(points.count - 1) {
                        if nearlyEqual(points[start], points[close])
                            && nearlyEqual(points[start - 1], points[close + 1]) {
                            foundBridge = (start, close)
                            break outerLoop
                        }
                    }
                }
            }

            guard let bridge = foundBridge else { break }

            let hole = normalizedLoop(Array(points[bridge.start..<bridge.close]))
            if hole.count >= 3 { holes.append(hole) }
            points.removeSubrange(bridge.start...(bridge.close + 1))
            points = removeConsecutiveDuplicates(points)
        }

        let outer = normalizedLoop(removeConsecutiveDuplicates(points))
        if outer.count >= 3 { return (outer, holes) }
        return (normalizedLoop(boundary), holes)
    }

    private func normalizedLoop(_ loop: [Vector3]) -> [Vector3] {
        var points = removeConsecutiveDuplicates(loop)
        if points.count > 1, let first = points.first, let last = points.last, nearlyEqual(first, last) {
            points.removeLast()
        }
        return points
    }

    private func removeConsecutiveDuplicates(_ loop: [Vector3]) -> [Vector3] {
        var result: [Vector3] = []
        for point in loop {
            if let last = result.last, nearlyEqual(last, point) { continue }
            result.append(point)
        }
        return result
    }

    private func nearlyEqual(_ a: Vector3, _ b: Vector3) -> Bool {
        let dx = a.x - b.x
        let dy = a.y - b.y
        let dz = a.z - b.z
        return dx * dx + dy * dy + dz * dz < 1e-12
    }

    private func loopArea(_ loop: [Vector3]) -> Double {
        let points = normalizedLoop(loop)
        guard points.count >= 3 else { return 0 }
        var area = 0.0
        for i in points.indices {
            let p1 = points[i]
            let p2 = points[(i + 1) % points.count]
            area += p1.x * p2.y - p2.x * p1.y
        }
        return area * 0.5
    }

    /// Apply the current ribbon settings to the selected hatch entity in-place.
    private func applyToSelected(
        engine: PhrostEngine,
        processor: CADCommandProcessor,
        pushUndo: Bool = false
    ) {
        guard let handle = engine.cadSelection.lastSelectedHandle ?? lastCreatedHatchHandle,
              let entity = engine.document.entity(for: handle) else {
            processor.commandPrompt = "No hatch selected to apply changes to."
            return
        }
        let allBoundaryPaths = extractAllBoundaryPaths(from: entity)
        guard !allBoundaryPaths.isEmpty else {
            processor.commandPrompt = "No hatch boundary found to apply changes to."
            return
        }
        let allLoops = allBoundaryPaths.map { $0.tessellatedPoints() }
        let regions = CADBoundaryDetector.classifyLoops(allLoops, islandStyle: Int(islandStyle))
        guard !regions.isEmpty else { return }

        var newPrims: [CADPrimitive] = []
        for region in regions {
            newPrims.append(contentsOf: buildPrimitives(boundary: region.outer, holes: region.holes))
        }
        for path in allBoundaryPaths {
            var carrier = path
            carrier.isHatchBoundaryCarrier = true
            newPrims.append(.polyline(path: carrier, color: .transparent))
        }

        var updated = entity
        applyHatchXData(to: &updated)
        updated.localGeometry = newPrims
        if pushUndo {
            engine.document.updateEntity(updated)
        } else {
            engine.document.updateEntityLive(updated)
        }
        engine.tabManager.markActiveDirty()
        processor.commandPrompt = "Hatch updated. Click inside another area or press Esc/Enter."
    }

    private func commitHatch(
        boundary: [Vector3],
        holes: [[Vector3]] = [],
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        commitHatch(regions: [(boundary, holes)], engine: engine, processor: processor)
    }

    private func commitHatch(
        regions: [(outer: [Vector3], holes: [[Vector3]])],
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        var hatchPrims: [CADPrimitive] = []
        for (boundary, holes) in regions {
            hatchPrims.append(contentsOf: buildPrimitives(boundary: boundary, holes: holes))
            var outerCarrier = CADPolyline(points: boundary, isClosed: true)
            outerCarrier.isHatchBoundaryCarrier = true
            hatchPrims.append(.polyline(path: outerCarrier, color: .transparent))
            for hole in holes {
                var holeCarrier = CADPolyline(points: hole, isClosed: true)
                holeCarrier.isHatchBoundaryCarrier = true
                hatchPrims.append(.polyline(path: holeCarrier, color: .transparent))
            }
        }

        let layerID = engine.document.activeLayerID
            ?? engine.document.allLayers.first?.handle
            ?? UUID()
        var entity = CADEntity(layerID: layerID, localGeometry: hatchPrims)
        applyHatchXData(to: &entity)

        engine.document.addEntity(entity)
        engine.tabManager.markActiveDirty()
        lastCreatedHatchHandle = entity.handle

        // Select the newly created hatch so the user can inspect/refine settings.
        engine.cadSelection.clearSelection()
        engine.cadSelection.addToSelection(entity.handle)

        let totalHoles = regions.reduce(0) { $0 + $1.holes.count }
        processor.commandPrompt = totalHoles == 0
            ? "Hatch created (\(regions.count) region(s)). Click inside another area or press Esc/Enter."
            : "Hatch created (\(regions.count) region(s), \(totalHoles) hole(s)). Click inside another area or press Esc/Enter."
        return .continue
    }

    // MARK: - Overlay

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {
        let drawList = igGetForegroundDrawList_ViewportPtr(nil)
        let sc = EngineCameraManager.worldToScreen(
            worldX: currentMouseWorldX, worldY: currentMouseWorldY, cam: cam)
        let color = makeCol32(0, 255, 255, 150)

        // Subtle crosshair circle — indicates the "pick point" tool is active.
        ImDrawListAddCircle(drawList, ImVec2(x: sc.x, y: sc.y), 6.0, color, 0, 1.5)
    }

    // MARK: - Contextual Ribbon (renderImGui)

    public func renderImGui(engine: PhrostEngine) {
        guard case .waitingForInternalPoint = state else { return }

        // Resync command state if undo/redo altered the document
        let currentUndoDepth = engine.document.undoManager.undoDepth
        if lastObservedUndoDepth != -1, currentUndoDepth != lastObservedUndoDepth {
            if let handle = engine.cadSelection.lastSelectedHandle ?? lastCreatedHatchHandle,
               let entity = engine.document.entity(for: handle) {
                initFromEntity(entity)
            }
        }
        lastObservedUndoDepth = currentUndoDepth

        let previousFillType = fillType
        let previousPatternName = patternName
        let previousGradientName = gradientName
        let previousScale = hatchScale
        let previousAngle = hatchAngle
        let previousPrimaryColor = primaryColor
        let previousBackgroundColor = backgroundColor
        let previousSecondaryColor = secondaryColor
        let previousIslandStyle = islandStyle
        let previousAssociative = associative

        // Package command state into HatchRibbonUI.Settings
        var uiSettings = HatchRibbonUI.Settings(
            fillType: fillType,
            patternName: patternName,
            gradientName: gradientName,
            scale: hatchScale,
            angle: hatchAngle,
            primaryColor: primaryColor,
            backgroundColor: backgroundColor,
            secondaryColor: secondaryColor,
            selectionMode: (selectionMode == .selectBoundary ? 1 : 0),
            islandStyle: islandStyle,
            showModeSection: true,
            applyClicked: false,
            closeRequested: false,
            associative: associative
        )
        HatchRibbonUI.render(&uiSettings, engine: engine)
        
        // Pull back changes
        fillType = uiSettings.fillType
        patternName = uiSettings.patternName
        gradientName = uiSettings.gradientName
        hatchScale = uiSettings.scale
        hatchAngle = uiSettings.angle
        primaryColor = uiSettings.primaryColor
        backgroundColor = uiSettings.backgroundColor
        secondaryColor = uiSettings.secondaryColor
        selectionMode = uiSettings.selectionMode == 1 ? .selectBoundary : .pickPoints
        islandStyle = uiSettings.islandStyle
        associative = uiSettings.associative

        let settingsChanged = previousFillType != fillType
            || previousPatternName != patternName
            || previousGradientName != gradientName
            || previousScale != hatchScale
            || previousAngle != hatchAngle
            || previousPrimaryColor != primaryColor
            || previousBackgroundColor != backgroundColor
            || previousSecondaryColor != secondaryColor
            || previousIslandStyle != islandStyle
            || previousAssociative != associative

        if uiSettings.closeRequested {
            if let snapshot = hatchDragPreEditSnapshot {
                engine.document.pushUndo(snapshot)
                hatchDragPreEditSnapshot = nil
            }
            state = .completed
            engine.commandProcessor.finishFeatureCommand(engine: engine)
            return
        }

        let hasHatchToUpdate = lastCreatedHatchHandle != nil || engine.cadSelection.lastSelectedHandle != nil

        if uiSettings.isContinuousDragFinished {
            if let snapshot = hatchDragPreEditSnapshot {
                engine.document.pushUndo(snapshot)
                hatchDragPreEditSnapshot = nil
            } else if settingsChanged && hasHatchToUpdate {
                applyToSelected(engine: engine, processor: engine.commandProcessor, pushUndo: true)
                lastObservedUndoDepth = engine.document.undoManager.undoDepth
                return
            }
            if hasHatchToUpdate {
                applyToSelected(engine: engine, processor: engine.commandProcessor, pushUndo: false)
                engine.document.invalidateEntityGrid()
                engine.document.markEdited(regenerate: true)
            }
            lastObservedUndoDepth = engine.document.undoManager.undoDepth
        } else if uiSettings.isContinuousDragActive {
            if hatchDragPreEditSnapshot == nil {
                hatchDragPreEditSnapshot = engine.document.snapshot()
            }
            if hasHatchToUpdate {
                applyToSelected(engine: engine, processor: engine.commandProcessor, pushUndo: false)
            }
        } else if uiSettings.applyClicked || (settingsChanged && hasHatchToUpdate) {
            if let snapshot = hatchDragPreEditSnapshot {
                engine.document.pushUndo(snapshot)
                hatchDragPreEditSnapshot = nil
            }
            applyToSelected(engine: engine, processor: engine.commandProcessor, pushUndo: true)
            lastObservedUndoDepth = engine.document.undoManager.undoDepth
        }
    }
}