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
                    return commitHatch(boundary: worldPts,
                                       engine: engine, processor: processor)
                }
            }
            processor.commandPrompt = "No closed boundary found at click location."
            return .continue
        }

        // ── Pick Points mode ──
        if let polygon = CADBoundaryDetector.findEnclosingPolygon(
            seedX: worldX, seedY: worldY,
            document: engine.document,
            maxEdgeCount: 2000
        ) {
            return commitHatch(boundary: polygon,
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

    // MARK: - Commit

    private func commitHatch(
        boundary: [Vector3],
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
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
        case 2:  // Gradient — store as fillComplexPolygon with gradient for now,
                 // or fall back to solid with primary color.
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

        let hatchPrim: CADPrimitive
        if fillType == 2, let c1 = primaryColor {
            // Gradient: build a gradient primitive with a fallback color2.
            let c2 = secondaryColor ?? ColorRGBA(
                r: min(255, c1.r + 60), g: min(255, c1.g + 60),
                b: min(255, c1.b + 60))
            hatchPrim = CADPrimitive.gradient(
                outer: boundary, holes: [],
                gradientName: gradientName, angle: angle, color1: c1, color2: c2)
        } else {
            hatchPrim = CADPrimitive.hatch(
                boundary: boundary,
                pattern: effectivePattern,
                scale: scale,
                angle: angle,
                color: effectiveColor,
                backgroundColor: effectiveBgColor
            )
        }

        let layerID = engine.document.activeLayerID
            ?? engine.document.allLayers.first?.handle
            ?? UUID()
        let entity = CADEntity(layerID: layerID, localGeometry: [hatchPrim])

        engine.document.addEntity(entity)
        engine.tabManager.markActiveDirty()

        processor.commandPrompt = "Hatch created (\(boundary.count) boundary vertices)."
        state = .completed
        return .finished
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
        
        if uiSettings.closeRequested || uiSettings.applyClicked {
            // The command design currently applies hatch on click. 
            // If the user clicks Apply without picking a point, or clicks Close, we terminate.
            state = .completed
        }
    }
}

