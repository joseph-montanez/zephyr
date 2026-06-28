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

    public init() {}

    // MARK: - FeatureCommand conformance

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        state = .waitingForInternalPoint
        currentMouseWorldX = 0
        currentMouseWorldY = 0
        processor.commandPrompt = "HATCH: Click inside an enclosed area to fill (Esc to cancel)."
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        state = .completed
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
                    return commitHatch(boundary: worldPts, holes: [],
                                       engine: engine, processor: processor)
                }
            }
            processor.commandPrompt = "No closed boundary found at click location."
            return .continue
        }

        // ── Pick Points mode ──
        if let region = CADBoundaryDetector.findEnclosingRegion(
            seedX: worldX, seedY: worldY,
            document: engine.document,
            maxEdgeCount: 2000
        ) {
            return commitHatch(boundary: region.outer,
                               holes: region.holes,
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
        if fillType == 2, let c1 = primaryColor {
            let c2 = secondaryColor ?? ColorRGBA(
                r: UInt8(min(255, Int(c1.r) + 60)),
                g: UInt8(min(255, Int(c1.g) + 60)),
                b: UInt8(min(255, Int(c1.b) + 60)))
            prims.append(.gradient(
                outer: boundary, holes: holes,
                gradientName: gradientName, angle: angle, color1: c1, color2: c2))
        } else if effectivePattern.uppercased() == "SOLID" || effectivePattern.isEmpty {
            prims.append(.fillComplexPolygon(
                outer: boundary, holes: holes, color: effectiveColor))
        } else {
            if let bg = effectiveBgColor {
                prims.append(.fillComplexPolygon(
                    outer: boundary, holes: holes, color: bg))
            }
            let patternBoundary = holes.isEmpty
                ? boundary
                : DXFHatchGenerator.connectHoles(outer: boundary, holes: holes)
            prims.append(.hatch(
                boundary: patternBoundary,
                pattern: effectivePattern,
                scale: scale,
                angle: angle,
                color: effectiveColor,
                backgroundColor: nil))
        }
        return prims
    }

    /// Extract the outer boundary and holes from an existing hatch entity.
    private func extractBoundary(from entity: CADEntity) -> (outer: [Vector3], holes: [[Vector3]])? {
        guard let geometry = entity.localGeometry else { return nil }
        var outer: [Vector3] = []
        var allHoles: [[Vector3]] = []
        for prim in geometry {
            switch prim {
            case .fillComplexPolygon(let o, let h, _):
                if outer.isEmpty { outer = o }
                allHoles.append(contentsOf: h)
            case .gradient(let o, let h, _, _, _, _):
                if outer.isEmpty { outer = o }
                allHoles.append(contentsOf: h)
            case .hatch(let b, _, _, _, _, _):
                if outer.isEmpty { outer = b }
            default:
                break
            }
        }
        guard !outer.isEmpty else { return nil }
        return (outer, allHoles)
    }

    /// Apply the current ribbon settings to the selected hatch entity in-place.
    private func applyToSelected(engine: PhrostEngine, processor: CADCommandProcessor) {
        guard let handle = engine.cadSelection.lastSelectedHandle,
              let entity = engine.document.entity(for: handle),
              let (boundary, holes) = extractBoundary(from: entity) else {
            processor.commandPrompt = "No hatch selected to apply changes to."
            return
        }
        let newPrims = buildPrimitives(boundary: boundary, holes: holes)
        engine.document.updateEntityGeometry(for: handle, geometry: newPrims)
        engine.tabManager.markActiveDirty()
        processor.commandPrompt = "Hatch updated. Click inside another area or press Esc/Enter."
    }

    private func commitHatch(
        boundary: [Vector3],
        holes: [[Vector3]] = [],
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        let hatchPrims = buildPrimitives(boundary: boundary, holes: holes)

        let layerID = engine.document.activeLayerID
            ?? engine.document.allLayers.first?.handle
            ?? UUID()
        let entity = CADEntity(layerID: layerID, localGeometry: hatchPrims)

        engine.document.addEntity(entity)
        engine.tabManager.markActiveDirty()

        // Select the newly created hatch so the user can inspect/refine settings.
        engine.cadSelection.clearSelection()
        engine.cadSelection.addToSelection(entity.handle)

        processor.commandPrompt = holes.isEmpty
            ? "Hatch created (\(boundary.count) boundary vertices). Click inside another area or press Esc/Enter."
            : "Hatch created (\(boundary.count) boundary vertices, \(holes.count) hole(s)). Click inside another area or press Esc/Enter."
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
            showModeSection: true,
            applyClicked: false,
            closeRequested: false,
            associative: true
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
        
        if uiSettings.applyClicked {
            applyToSelected(engine: engine, processor: engine.commandProcessor)
        }
        if uiSettings.closeRequested {
            state = .completed
        }
    }
}

