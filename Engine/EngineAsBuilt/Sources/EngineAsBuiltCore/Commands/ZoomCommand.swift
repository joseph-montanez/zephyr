import Foundation
import CSDL3
import ImGui
import SwiftSDL

// =========================================================================
// MARK: - ZoomCommand
//
// AutoCAD-style ZOOM command with sub-commands:
//   All(A)  Extents(E)  Window(W/click)  Previous(P)  Object(O)
//   Realtime(drag)  Dynamic(D)  Center(C)  Left(L)  Right(R)  Scale(S)
//
// Typing Z or ZOOM enters the command.  The prompt shows available
// sub-commands.  Pressing a sub-command letter selects it; clicking without
// a typed sub-command defaults to Window mode.
//
// View history is pushed via engine.camera.pushViewState() just before each
// discrete zoom operation so ZOOM Previous can roll back.
// =========================================================================

@MainActor
public final class ZoomCommand: FeatureCommand {

    // MARK: - Nested Phase Enums

    enum WindowPhase {
        case waitingForFirstCorner
        case waitingForSecondCorner(firstX: Double, firstY: Double)
    }

    enum CenterPhase {
        case waitingForPoint
        case waitingForHeight(centerX: Double, centerY: Double)
    }

    enum DynamicPhase {
        case panning
        case resizing
    }

    enum ScaleParseResult {
        case drawingRelative(Double)
        case viewRelative(Double)
        case paperSpace(Double)  // treated as viewRelative for now
        case invalid
    }

    enum SubMode {
        case prompting
        case window(WindowPhase)
        case center(CenterPhase)
        case left(CenterPhase)
        case right(CenterPhase)
        case objectPicking(selected: Set<UUID>)
        case realtime(anchorScreenY: Float, zoomStart: Double)
        case dynamic(
            viewfinderMinX: Double, viewfinderMinY: Double,
            viewfinderMaxX: Double, viewfinderMaxY: Double,
            drawingMinX: Double, drawingMinY: Double,
            drawingMaxX: Double, drawingMaxY: Double,
            phase: DynamicPhase,
            dragAnchorWorldX: Double, dragAnchorWorldY: Double,
            dragAnchorVfMinX: Double, dragAnchorVfMinY: Double
        )
        case scale      // waiting for text input (via renderImGui)
        case textInput(subModeLabel: String, onConfirm: (Double) -> Void)
    }

    // MARK: - State

    private var subMode: SubMode = .prompting
    private var currentMouseWorldX: Double = 0
    private var currentMouseWorldY: Double = 0
    private var textInputBuffer: String = ""

    // MARK: - Public API for executeCommand interception

    /// Called by CADCommandProcessor.executeCommand when this command is active
    /// and the entered text didn't match any other registered command.
    /// Returns .continue if the text was consumed, .finished if the command is done.
    public func handleCommandText(
        _ text: String, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        switch subMode {
        case .scale:
            let result = parseScaleInput(text)
            switch result {
            case .drawingRelative(let n):
                applyScaleFactor(n, relativeTo: .drawing, engine: engine, processor: processor)
            case .viewRelative(let n):
                applyScaleFactor(n, relativeTo: .view, engine: engine, processor: processor)
            case .paperSpace(let n):
                applyScaleFactor(n, relativeTo: .view, engine: engine, processor: processor)
            case .invalid:
                processor.commandPrompt = "Invalid scale. Enter n, nX, or nXP (e.g. 2, 0.5x)."
                return .continue
            }
            return .finished

        case .textInput(let label, let onConfirm):
            guard let value = Double(text.trimmingCharacters(in: .whitespaces)) else {
                processor.commandPrompt = "Invalid number for \(label). Try again."
                return .continue
            }
            onConfirm(value)
            return .finished

        default:
            return .continue
        }
    }

    // MARK: - init

    public init() {}

    // MARK: - FeatureCommand Conformance

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        subMode = .prompting
        currentMouseWorldX = 0
        currentMouseWorldY = 0
        textInputBuffer = ""
        showPrompt(processor: processor, label: "[All/Center/Dynamic/Extents/Left/Previous/Right/Scale/Object/Window]")
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        subMode = .prompting
        textInputBuffer = ""
    }

    public var isSnappingEnabled: Bool {
        switch subMode {
        case .window, .center, .left, .right, .objectPicking, .dynamic:
            return true
        default:
            return false
        }
    }

    // MARK: - Mouse Click

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        switch subMode {

        // ── Prompting: default → Window ──
        case .prompting:
            subMode = .window(.waitingForSecondCorner(firstX: worldX, firstY: worldY))
            processor.commandPrompt = "Specify opposite corner"
            return .continue

        // ── Window ──
        case .window(.waitingForFirstCorner):
            subMode = .window(.waitingForSecondCorner(firstX: worldX, firstY: worldY))
            processor.commandPrompt = "Specify opposite corner"
            return .continue

        case .window(.waitingForSecondCorner(let fx, let fy)):
            let (minX, maxX) = (min(fx, worldX), max(fx, worldX))
            let (minY, maxY) = (min(fy, worldY), max(fy, worldY))
            zoomToWorldRect(minX: minX, minY: minY, maxX: maxX, maxY: maxY,
                            engine: engine, processor: processor)
            return .finished

        // ── Center / Left / Right ──
        case .center(.waitingForPoint):
            subMode = .center(.waitingForHeight(centerX: worldX, centerY: worldY))
            processor.commandPrompt = "Enter magnification or height"
            return .continue

        case .center(.waitingForHeight(_, _)):
            // Handled by text input, not mouse
            return .continue

        case .left(.waitingForPoint):
            subMode = .left(.waitingForHeight(centerX: worldX, centerY: worldY))
            processor.commandPrompt = "Enter magnification or height"
            return .continue

        case .left(.waitingForHeight(_, _)):
            return .continue

        case .right(.waitingForPoint):
            subMode = .right(.waitingForHeight(centerX: worldX, centerY: worldY))
            processor.commandPrompt = "Enter magnification or height"
            return .continue

        case .right(.waitingForHeight(_, _)):
            return .continue

        // ── Object Picking ──
        case .objectPicking(var selected):
            let threshold = 12.0 / engine.camera.zoom
            if let handle = CADHitTesting.hitTest(
                worldX: worldX, worldY: worldY,
                document: engine.document, threshold: threshold,
                simplifyComplexBlocks: engine.simplifyComplexBlocks)
            {
                if selected.contains(handle) {
                    selected.remove(handle)
                } else {
                    selected.insert(handle)
                }
                subMode = .objectPicking(selected: selected)
                let label = selected.isEmpty ? "Select objects" : "\(selected.count) object(s) selected"
                processor.commandPrompt = "\(label) — Enter to finish, Esc to cancel"
            }
            return .continue

        // ── Realtime ──
        case .realtime:
            // Mouse down starts drag; handled in first motion
            return .continue

        // ── Dynamic ──
        case .dynamic(let vfMinX, let vfMinY, let vfMaxX, let vfMaxY,
                       let dMinX, let dMinY, let dMaxX, let dMaxY, _, _, _, _, _):
            // Left click: start panning the viewfinder
            subMode = .dynamic(
                viewfinderMinX: vfMinX, viewfinderMinY: vfMinY,
                viewfinderMaxX: vfMaxX, viewfinderMaxY: vfMaxY,
                drawingMinX: dMinX, drawingMinY: dMinY,
                drawingMaxX: dMaxX, drawingMaxY: dMaxY,
                phase: .panning,
                dragAnchorWorldX: worldX, dragAnchorWorldY: worldY,
                dragAnchorVfMinX: vfMinX, dragAnchorVfMinY: vfMinY)
            return .continue

        case .scale, .textInput:
            return .continue
        }
    }

    // MARK: - Mouse Motion

    public func handleMouseMotion(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        currentMouseWorldX = worldX
        currentMouseWorldY = worldY

        switch subMode {

        // ── Realtime ──
        case .realtime(let anchorY, let zoomStart):
            let screenY = worldToScreenY(worldY: worldY, engine: engine)
            let deltaY = Double(screenY - anchorY)
            // Slower, more precise factor
            var factor = pow(1.03, deltaY / 10.0)
            // Clamp to avoid runaway zoom in a single drag
            factor = max(0.1, min(factor, 10.0))
            let newZoom = max(0.000001, min(zoomStart * factor, 1e15))
            engine.camera.zoom = newZoom

        // ── Dynamic panning ──
        case .dynamic(let vfMinX, let vfMinY, let vfMaxX, let vfMaxY,
                       let dMinX, let dMinY, let dMaxX, let dMaxY,
                       .panning,
                       let anchorWorldX, let anchorWorldY,
                       let anchorVfMinX, let anchorVfMinY):
            let dx = worldX - anchorWorldX
            let dy = worldY - anchorWorldY
            let vfW = vfMaxX - vfMinX
            let vfH = vfMaxY - vfMinY
            var newMinX = anchorVfMinX + dx
            var newMinY = anchorVfMinY + dy
            // Clamp to drawing extents
            newMinX = max(dMinX, min(newMinX, dMaxX - vfW))
            newMinY = max(dMinY, min(newMinY, dMaxY - vfH))
            subMode = .dynamic(
                viewfinderMinX: newMinX, viewfinderMinY: newMinY,
                viewfinderMaxX: newMinX + vfW, viewfinderMaxY: newMinY + vfH,
                drawingMinX: dMinX, drawingMinY: dMinY,
                drawingMaxX: dMaxX, drawingMaxY: dMaxY,
                phase: .panning,
                dragAnchorWorldX: anchorWorldX, dragAnchorWorldY: anchorWorldY,
                dragAnchorVfMinX: anchorVfMinX, dragAnchorVfMinY: anchorVfMinY)

        case .dynamic(let vfMinX, let vfMinY, let vfMaxX, let vfMaxY,
                       let dMinX, let dMinY, let dMaxX, let dMaxY,
                       .resizing, _, _, _, _):
            // Resize viewfinder toward mouse position
            let vfCenterX = (vfMinX + vfMaxX) / 2.0
            let vfCenterY = (vfMinY + vfMaxY) / 2.0
            let halfW = abs(worldX - vfCenterX)
            let halfH = abs(worldY - vfCenterY)
            let newMinX = max(dMinX, vfCenterX - halfW)
            let newMaxX = min(dMaxX, vfCenterX + halfW)
            let newMinY = max(dMinY, vfCenterY - halfH)
            let newMaxY = min(dMaxY, vfCenterY + halfH)
            subMode = .dynamic(
                viewfinderMinX: newMinX, viewfinderMinY: newMinY,
                viewfinderMaxX: newMaxX, viewfinderMaxY: newMaxY,
                drawingMinX: dMinX, drawingMinY: dMinY,
                drawingMaxX: dMaxX, drawingMaxY: dMaxY,
                phase: .resizing,
                dragAnchorWorldX: 0, dragAnchorWorldY: 0,
                dragAnchorVfMinX: 0, dragAnchorVfMinY: 0)

        default:
            break
        }
    }

    // MARK: - Key Down

    public func handleKeyDown(
        scancode: SDL_Scancode, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        // ── Sub-mode key dispatch (when prompting or mid-command) ──
        switch scancode {
        case SDL_SCANCODE_A:
            if case .prompting = subMode {
                executeAll(engine: engine, processor: processor)
                return .finished
            }
        case SDL_SCANCODE_C:
            if case .prompting = subMode {
                subMode = .center(.waitingForPoint)
                processor.commandPrompt = "Specify center point"
                return .continue
            }
        case SDL_SCANCODE_D:
            if case .prompting = subMode {
                executeDynamic(engine: engine, processor: processor)
                return .continue
            }
        case SDL_SCANCODE_E:
            if case .prompting = subMode {
                executeExtents(engine: engine, processor: processor)
                return .finished
            }
        case SDL_SCANCODE_L:
            if case .prompting = subMode {
                subMode = .left(.waitingForPoint)
                processor.commandPrompt = "Specify lower-left corner"
                return .continue
            }
        case SDL_SCANCODE_O:
            if case .prompting = subMode {
                executeObject(engine: engine, processor: processor)
                return .continue
            }
        case SDL_SCANCODE_P:
            if case .prompting = subMode {
                let restored = engine.camera.popViewState()
                if restored {
                    processor.commandPrompt = "Restored previous view"
                } else {
                    processor.commandPrompt = "No previous view saved"
                }
                return .finished
            }
        case SDL_SCANCODE_R:
            if case .prompting = subMode {
                subMode = .right(.waitingForPoint)
                processor.commandPrompt = "Specify lower-right corner"
                return .continue
            }
        case SDL_SCANCODE_S:
            if case .prompting = subMode {
                subMode = .scale
                processor.commandPrompt = "Enter scale factor (n, nX, nXP):"
                processor.commandLineActive = true
                processor.commandBuffer = ""
                return .continue
            }
        case SDL_SCANCODE_W:
            if case .prompting = subMode {
                subMode = .window(.waitingForFirstCorner)
                processor.commandPrompt = "Specify first corner"
                return .continue
            }

        // ── Dynamic: Enter to commit ──
        case SDL_SCANCODE_RETURN, SDL_SCANCODE_KP_ENTER:
            switch subMode {
            case .objectPicking(let selected) where !selected.isEmpty:
                zoomToObjects(handles: selected, engine: engine, processor: processor)
                return .finished
            case .objectPicking:
                processor.commandPrompt = "No objects selected. Click on objects or press Esc."
                return .continue
            case .dynamic(let vfMinX, let vfMinY, let vfMaxX, let vfMaxY, _, _, _, _, _, _, _, _, _):
                zoomToWorldRect(minX: vfMinX, minY: vfMinY, maxX: vfMaxX, maxY: vfMaxY,
                                engine: engine, processor: processor)
                return .finished
            default:
                return .continue
            }

        default:
            break
        }

        // ── Digits / period for scale or text input ──
        if case .scale = subMode {
            // While the command line is active, typing goes there.
            // We also handle digits here as a fallback.
            if let char = scancodeToChar(scancode),
               char == "." || (char >= "0" && char <= "9") || char == "x" || char == "X" {
                processor.commandLineActive = true
            }
            return .continue
        }

        return .continue
    }

    // MARK: - Render Overlay

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {
        let drawList = igGetForegroundDrawList_ViewportPtr(nil)

        switch subMode {
        // ── Window: rubber-band rectangle ──
        case .window(.waitingForSecondCorner(let fx, let fy)):
            let p1 = EngineCameraManager.worldToScreen(worldX: fx, worldY: fy, cam: cam)
            let p2 = EngineCameraManager.worldToScreen(worldX: currentMouseWorldX, worldY: currentMouseWorldY, cam: cam)
            let lineCol = makeCol32(0, 200, 255, 200)
            let fillCol = makeCol32(0, 200, 255, 40)

            let minX = min(p1.x, p2.x)
            let minY = min(p1.y, p2.y)
            let maxX = max(p1.x, p2.x)
            let maxY = max(p1.y, p2.y)

            let a = ImVec2(x: minX, y: minY)
            let c = ImVec2(x: maxX, y: maxY)
            ImDrawListAddRectFilled(drawList, a, c, fillCol, 0, 0)
            ImDrawListAddRect(drawList, a, c, lineCol, 0, 1.5, 0)

        // ── Object: highlight picked entities ──
        case .objectPicking(let selected):
            let highlightCol = makeCol32(0, 255, 255, 80)
            let outlineCol = makeCol32(0, 255, 255, 200)
            for handle in selected {
                guard let entity = engine.document.entity(for: handle),
                      let bb = entity.worldBoundingBox else { continue }
                let pMin = EngineCameraManager.worldToScreen(worldX: bb.min.x, worldY: bb.min.y, cam: cam)
                let pMax = EngineCameraManager.worldToScreen(worldX: bb.max.x, worldY: bb.max.y, cam: cam)
                let a = ImVec2(x: pMin.x, y: pMin.y)
                let c = ImVec2(x: pMax.x, y: pMax.y)
                ImDrawListAddRectFilled(drawList, a, c, highlightCol, 0, 0)
                ImDrawListAddRect(drawList, a, c, outlineCol, 0, 1.0, 0)
            }

        // ── Realtime: magnifying glass cursor indicator ──
        case .realtime:
            // Simple indicator: crosshair with circle
            let cx = Float(cam.screenCenterX)
            let cy = Float(cam.screenCenterY)
            let r: Float = 30
            let col = makeCol32(0, 200, 255, 160)
            ImDrawListAddCircle(drawList, ImVec2(x: cx, y: cy), r, col, 0, 2.0)
            // Plus/minus markers at top/bottom
            ImDrawListAddLine(drawList, ImVec2(x: cx - 8, y: cy - r), ImVec2(x: cx + 8, y: cy - r), col, 2.0)
            ImDrawListAddLine(drawList, ImVec2(x: cx - 8, y: cy + r), ImVec2(x: cx + 8, y: cy + r), col, 2.0)

        // ── Dynamic: viewfinder box ──
        case .dynamic(let vfMinX, let vfMinY, let vfMaxX, let vfMaxY,
                       let dMinX, let dMinY, let dMaxX, let dMaxY, _, _, _, _, _):
            // Drawing extents outline (dim)
            let deP1 = EngineCameraManager.worldToScreen(worldX: dMinX, worldY: dMinY, cam: cam)
            let deP2 = EngineCameraManager.worldToScreen(worldX: dMaxX, worldY: dMaxY, cam: cam)
            let deCol = makeCol32(100, 100, 100, 100)
            ImDrawListAddRect(drawList,
                ImVec2(x: deP1.x, y: deP1.y),
                ImVec2(x: deP2.x, y: deP2.y), deCol, 0, 1.0, 0)

            // Viewfinder box (bright dashed)
            let vfP1 = EngineCameraManager.worldToScreen(worldX: vfMinX, worldY: vfMinY, cam: cam)
            let vfP2 = EngineCameraManager.worldToScreen(worldX: vfMaxX, worldY: vfMaxY, cam: cam)
            let vfCol = makeCol32(0, 200, 255, 220)

            // Dashed rectangle (approximated with short line segments)
            drawDashedRect(drawList,
                           minX: vfP1.x, minY: vfP1.y,
                           maxX: vfP2.x, maxY: vfP2.y,
                           color: vfCol, dashLen: 8, gapLen: 6, thickness: 1.5)

            // Center X marker
            let midX = (vfP1.x + vfP2.x) / 2.0
            let midY = (vfP1.y + vfP2.y) / 2.0
            let xSize: Float = 12
            let xCol = makeCol32(0, 200, 255, 255)
            ImDrawListAddLine(drawList,
                ImVec2(x: midX - xSize, y: midY - xSize),
                ImVec2(x: midX + xSize, y: midY + xSize), xCol, 2.0)
            ImDrawListAddLine(drawList,
                ImVec2(x: midX + xSize, y: midY - xSize),
                ImVec2(x: midX - xSize, y: midY + xSize), xCol, 2.0)

        default:
            break
        }
    }

    // MARK: - Render ImGui (text input for Scale, Center height)

    public func renderImGui(engine: PhrostEngine) {
        switch subMode {
        case .center(.waitingForHeight(let cx, let cy)):
            renderTextInput(label: "Center Height",
                prompt: "Enter magnification or height for center (\(String(format: "%.2f", cx)), \(String(format: "%.2f", cy))):")
            { value in
                self.applyCenterHeight(cx: cx, cy: cy, height: value, engine: engine)
            }

        case .left(.waitingForHeight(let lx, let ly)):
            renderTextInput(label: "Left Height",
                prompt: "Enter magnification or height for lower-left (\(String(format: "%.2f", lx)), \(String(format: "%.2f", ly))):")
            { value in
                self.applyLeftHeight(lx: lx, ly: ly, height: value, engine: engine)
            }

        case .right(.waitingForHeight(let rx, let ry)):
            renderTextInput(label: "Right Height",
                prompt: "Enter magnification or height for lower-right (\(String(format: "%.2f", rx)), \(String(format: "%.2f", ry))):")
            { value in
                self.applyRightHeight(rx: rx, ry: ry, height: value, engine: engine)
            }

        default:
            break
        }
    }

    // MARK: - Sub-Command Executors

    /// ZOOM All: all visible entities + grid limits.
    private func executeAll(engine: PhrostEngine, processor: CADCommandProcessor) {
        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity
        var hasObjects = false

        for entity in engine.document.entitiesView {
            guard let layer = engine.document.layer(for: entity.layerID), layer.isVisible else { continue }
            guard let bb = entity.worldBoundingBox else { continue }
            hasObjects = true
            minX = min(minX, bb.min.x)
            minY = min(minY, bb.min.y)
            maxX = max(maxX, bb.max.x)
            maxY = max(maxY, bb.max.y)
        }

        // Expand to include grid extents if grid is visible
        if engine.snap.gridVisible {
            let gridSpacing = engine.snap.effectiveGridSpacing(
                windowWidth: engine.windowWidth, cameraZoom: engine.camera.zoom)
            let gridOriginX = engine.snap.gridOriginX
            let gridOriginY = engine.snap.gridOriginY
            // Grid covers viewport width/height worth of lines from origin
            let vp = engine.camera.worldViewportRect(windowWidth: engine.windowWidth, windowHeight: engine.windowHeight)
            let vpW = vp.maxX - vp.minX
            let vpW2 = max(vpW, 100.0)
            let gridExtent = gridSpacing * ceil(vpW2 / gridSpacing) * 2

            let gMinX = gridOriginX - gridExtent
            let gMaxX = gridOriginX + gridExtent
            let gMinY = gridOriginY - gridExtent
            let gMaxY = gridOriginY + gridExtent

            if hasObjects {
                minX = min(minX, gMinX)
                minY = min(minY, gMinY)
                maxX = max(maxX, gMaxX)
                maxY = max(maxY, gMaxY)
            } else {
                minX = gMinX; maxX = gMaxX
                minY = gMinY; maxY = gMaxY
                hasObjects = true
            }
        }

        guard hasObjects else {
            processor.commandPrompt = "No objects or grid limits to zoom to"
            return
        }

        let pad = 40.0
        minX -= pad; minY -= pad
        maxX += pad; maxY += pad
        zoomToWorldRect(minX: minX, minY: minY, maxX: maxX, maxY: maxY,
                        engine: engine, processor: processor)
    }

    /// ZOOM Extents: reuse existing zoomExtents.
    private func executeExtents(engine: PhrostEngine, processor: CADCommandProcessor) {
        engine.camera.pushViewState()
        engine.zoomExtents()
        processor.commandPrompt = nil
    }

    /// ZOOM Object: if entities pre-selected, zoom immediately; else enter picking.
    private func executeObject(engine: PhrostEngine, processor: CADCommandProcessor) {
        if engine.cadSelection.hasSelection {
            let handles = engine.cadSelection.selectedHandles
            zoomToObjects(handles: handles, engine: engine, processor: processor)
        } else {
            subMode = .objectPicking(selected: [])
            processor.commandPrompt = "Select objects — Enter to finish, Esc to cancel"
        }
    }

    /// ZOOM Dynamic: enter dynamic viewfinder mode.
    private func executeDynamic(engine: PhrostEngine, processor: CADCommandProcessor) {
        // Compute drawing extents
        var dMinX = Double.infinity, dMinY = Double.infinity
        var dMaxX = -Double.infinity, dMaxY = -Double.infinity
        var hasObjects = false

        for entity in engine.document.entitiesView {
            guard let layer = engine.document.layer(for: entity.layerID), layer.isVisible else { continue }
            guard let bb = entity.worldBoundingBox else { continue }
            hasObjects = true
            dMinX = min(dMinX, bb.min.x)
            dMinY = min(dMinY, bb.min.y)
            dMaxX = max(dMaxX, bb.max.x)
            dMaxY = max(dMaxY, bb.max.y)
        }

        if hasObjects {
            let pad = 0.05 * max(dMaxX - dMinX, dMaxY - dMinY, 1.0)
            dMinX -= pad; dMinY -= pad
            dMaxX += pad; dMaxY += pad
        } else {
            dMinX = -100; dMinY = -100
            dMaxX = 100; dMaxY = 100
        }

        // Initial viewfinder = current viewport
        let vp = engine.camera.worldViewportRect(windowWidth: engine.windowWidth, windowHeight: engine.windowHeight)
        subMode = .dynamic(
            viewfinderMinX: vp.minX, viewfinderMinY: vp.minY,
            viewfinderMaxX: vp.maxX, viewfinderMaxY: vp.maxY,
            drawingMinX: dMinX, drawingMinY: dMinY,
            drawingMaxX: dMaxX, drawingMaxY: dMaxY,
            phase: .panning,
            dragAnchorWorldX: 0, dragAnchorWorldY: 0,
            dragAnchorVfMinX: 0, dragAnchorVfMinY: 0)
        processor.commandPrompt = "Pan viewfinder (left-drag) or resize (scroll) — Enter to zoom, Esc to cancel"
    }

    // MARK: - Zoom Helpers

    /// Zoom to fit a world-space rectangle.
    private func zoomToWorldRect(
        minX: Double, minY: Double, maxX: Double, maxY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        let objW = maxX - minX
        let objH = maxY - minY
        guard objW > 1e-9, objH > 1e-9 else { return }

        let viewW = Double(engine.windowWidth)
        let viewH = Double(engine.windowHeight)
        let zoomX = viewW / objW
        let zoomY = viewH / objH

        engine.camera.pushViewState()
        engine.camera.zoom = min(zoomX, zoomY)
        engine.camera.offset = ((minX + maxX) / 2.0, (minY + maxY) / 2.0)
        processor.commandPrompt = nil
    }

    /// Zoom to fit a set of entities by their handles.
    private func zoomToObjects(
        handles: Set<UUID>, engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity
        var hasObjects = false

        for handle in handles {
            guard let entity = engine.document.entity(for: handle),
                  let bb = entity.worldBoundingBox else { continue }
            hasObjects = true
            minX = min(minX, bb.min.x)
            minY = min(minY, bb.min.y)
            maxX = max(maxX, bb.max.x)
            maxY = max(maxY, bb.max.y)
        }

        guard hasObjects else {
            processor.commandPrompt = "Selected objects have no geometry"
            return
        }

        let pad = 20.0
        minX -= pad; minY -= pad
        maxX += pad; maxY += pad
        zoomToWorldRect(minX: minX, minY: minY, maxX: maxX, maxY: maxY,
                        engine: engine, processor: processor)
    }

    // MARK: - Center / Left / Right Apply

    private func applyCenterHeight(cx: Double, cy: Double, height: Double, engine: PhrostEngine) {
        let viewH = Double(engine.windowHeight)
        let newZoom = viewH / max(height, 0.000001)
        engine.camera.pushViewState()
        engine.camera.zoom = newZoom
        engine.camera.offset = (cx, cy)
    }

    private func applyLeftHeight(lx: Double, ly: Double, height: Double, engine: PhrostEngine) {
        let viewW = Double(engine.windowWidth)
        let viewH = Double(engine.windowHeight)
        let newZoom = viewH / max(height, 0.000001)
        let centerX = lx + viewW / (2.0 * newZoom)
        let centerY = ly + viewH / (2.0 * newZoom)
        engine.camera.pushViewState()
        engine.camera.zoom = newZoom
        engine.camera.offset = (centerX, centerY)
    }

    private func applyRightHeight(rx: Double, ry: Double, height: Double, engine: PhrostEngine) {
        let viewW = Double(engine.windowWidth)
        let viewH = Double(engine.windowHeight)
        let newZoom = viewH / max(height, 0.000001)
        let centerX = rx - viewW / (2.0 * newZoom)
        let centerY = ry + viewH / (2.0 * newZoom)
        engine.camera.pushViewState()
        engine.camera.zoom = newZoom
        engine.camera.offset = (centerX, centerY)
    }

    // MARK: - Scale

    private enum ScaleRelative {
        case drawing
        case view
    }

    private func applyScaleFactor(
        _ n: Double, relativeTo rel: ScaleRelative,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        engine.camera.pushViewState()
        if case .drawing = rel {
            // Scale relative to drawing extents
            var dMinX = Double.infinity, dMinY = Double.infinity
            var dMaxX = -Double.infinity, dMaxY = -Double.infinity
            for entity in engine.document.entitiesView {
                guard let bb = entity.worldBoundingBox else { continue }
                dMinX = min(dMinX, bb.min.x)
                dMinY = min(dMinY, bb.min.y)
                dMaxX = max(dMaxX, bb.max.x)
                dMaxY = max(dMaxY, bb.max.y)
            }
            if dMinX.isFinite, dMaxX.isFinite {
                let extH = max(dMaxY - dMinY, 1.0)
                let viewH = Double(engine.windowHeight)
                engine.camera.zoom = viewH * n / extH
            } else {
                engine.camera.zoom = n
            }
        } else {
            engine.camera.zoom *= n
        }
        processor.commandPrompt = nil
    }

    /// Parse text like "2", "2x", "0.5x", "2xp"
    func parseScaleInput(_ text: String) -> ScaleParseResult {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .invalid }

        // Match: optional digits.digits, optional x or xp suffix
        let pattern = #"^([0-9]+(\.[0-9]+)?)([xX][pP]?)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) else {
            return .invalid
        }

        // Group 1: the number
        guard match.numberOfRanges > 1,
              let numRange = Range(match.range(at: 1), in: trimmed) else {
            return .invalid
        }
        guard let value = Double(String(trimmed[numRange])) else { return .invalid }

        // Group 3: suffix (x, xp, or nothing)
        var suffix = ""
        if match.numberOfRanges > 3,
           let sufRange = Range(match.range(at: 3), in: trimmed) {
            suffix = String(trimmed[sufRange]).lowercased()
        }

        switch suffix {
        case "xp": return .paperSpace(value)
        case "x":  return .viewRelative(value)
        default:   return .drawingRelative(value)
        }
    }

    // MARK: - Text Input via ImGui

    private func renderTextInput(
        label: String, prompt _: String, onConfirm: @escaping (Double) -> Void
    ) {
        // Show a small centered popup for numeric input
        let popupID = "##Zoom\(label.replacingOccurrences(of: " ", with: ""))"
        let flags: Int32 = Int32(ImGuiWindowFlags_NoResize.rawValue)
            | Int32(ImGuiWindowFlags_NoMove.rawValue)
            | Int32(ImGuiWindowFlags_NoSavedSettings.rawValue)

        let io = ImGuiGetIO()!
        let displayW = io.pointee.DisplaySize.x
        let displayH = io.pointee.DisplaySize.y
        let popupW: Float = 320
        let popupH: Float = 90
        ImGuiSetNextWindowPos(
            ImVec2(x: (displayW - popupW) / 2, y: (displayH - popupH) / 2),
            Int32(ImGuiCond_Always.rawValue), ImVec2(x: 0, y: 0))
        ImGuiSetNextWindowSize(ImVec2(x: popupW, y: popupH), Int32(ImGuiCond_Always.rawValue))

        var opened = true
        if igBegin(popupID, &opened, flags) {
            ImGuiTextV("Enter magnification or height:")
            ImGuiSpacing()

            var buf = [CChar](repeating: 0, count: 64)
            let bytes = textInputBuffer.utf8CString
            let copyLen = min(bytes.count, 63)
            buf.withUnsafeMutableBufferPointer { ptr in
                _ = ptr.initialize(from: bytes.prefix(copyLen))
            }

            ImGuiPushItemWidth(popupW - 40)
            ImGuiSetKeyboardFocusHere(0)
            let submitted = buf.withUnsafeMutableBufferPointer { ptr -> Bool in
                guard let base = ptr.baseAddress else { return false }
                return igInputText("##ZoomTextInput", base, 64,
                    Int32(ImGuiInputTextFlags_EnterReturnsTrue.rawValue)
                        | Int32(ImGuiInputTextFlags_AutoSelectAll.rawValue),
                    nil, nil)
            }
            ImGuiPopItemWidth()

            textInputBuffer = buf.withUnsafeBufferPointer { ptr -> String in
                let bytes = UnsafeRawBufferPointer(ptr).prefix(while: { $0 != 0 })
                return String(decoding: bytes, as: UTF8.self)
            }

            if submitted {
                let trimmed = textInputBuffer.trimmingCharacters(in: .whitespaces)
                if let value = Double(trimmed) {
                    textInputBuffer = ""
                    onConfirm(value)
                }
            }

            if ImGuiIsKeyPressed(ImGuiKey_Escape, false) {
                // Cancel text input — revert to window mode
                subMode = .window(.waitingForFirstCorner)
                textInputBuffer = ""
            }
        }
        ImGuiEnd()
    }

    // MARK: - Helpers

    private func showPrompt(processor: CADCommandProcessor, label: String) {
        processor.commandPrompt = label
    }

    private func worldToScreenY(worldY: Double, engine: PhrostEngine) -> Float {
        let cam = engine.camera.currentTransform(windowWidth: engine.windowWidth, windowHeight: engine.windowHeight)
        let pt = EngineCameraManager.worldToScreen(worldX: 0, worldY: worldY, cam: cam)
        return pt.y
    }

    /// Map SDL_Scancode to a character for digit/letter input.
    private func scancodeToChar(_ sc: SDL_Scancode) -> Character? {
        // Letters a-z
        if sc.rawValue >= SDL_SCANCODE_A.rawValue && sc.rawValue <= SDL_SCANCODE_Z.rawValue {
            let ascii = UInt8(0x61 + (sc.rawValue - SDL_SCANCODE_A.rawValue))
            return Character(UnicodeScalar(ascii))
        }
        // Digits 0-9 (main keyboard)
        if sc.rawValue >= SDL_SCANCODE_0.rawValue && sc.rawValue <= SDL_SCANCODE_9.rawValue {
            let ascii = UInt8(0x30 + (sc.rawValue - SDL_SCANCODE_0.rawValue))
            return Character(UnicodeScalar(ascii))
        }
        // Period
        if sc == SDL_SCANCODE_PERIOD { return "." }
        // Numpad
        if sc == SDL_SCANCODE_KP_0 { return "0" }
        if sc == SDL_SCANCODE_KP_1 { return "1" }
        if sc == SDL_SCANCODE_KP_2 { return "2" }
        if sc == SDL_SCANCODE_KP_3 { return "3" }
        if sc == SDL_SCANCODE_KP_4 { return "4" }
        if sc == SDL_SCANCODE_KP_5 { return "5" }
        if sc == SDL_SCANCODE_KP_6 { return "6" }
        if sc == SDL_SCANCODE_KP_7 { return "7" }
        if sc == SDL_SCANCODE_KP_8 { return "8" }
        if sc == SDL_SCANCODE_KP_9 { return "9" }
        if sc == SDL_SCANCODE_KP_PERIOD { return "." }
        return nil
    }

    /// Draw a dashed rectangle using short line segments.
    private func drawDashedRect(
        _ drawList: UnsafeMutablePointer<ImDrawList>?,
        minX: Float, minY: Float, maxX: Float, maxY: Float,
        color: UInt32, dashLen: Float, gapLen: Float, thickness: Float
    ) {
        // Helper to draw dashed line segment
        func dashLine(_ x1: Float, _ y1: Float, _ x2: Float, _ y2: Float) {
            let dx = x2 - x1
            let dy = y2 - y1
            let len = sqrt(dx * dx + dy * dy)
            guard len > 0 else { return }
            let ux = dx / len
            let uy = dy / len
            var pos: Float = 0
            let cycle = dashLen + gapLen
            while pos < len {
                let segLen = min(dashLen, len - pos)
                ImDrawListAddLine(drawList,
                    ImVec2(x: x1 + ux * pos, y: y1 + uy * pos),
                    ImVec2(x: x1 + ux * (pos + segLen), y: y1 + uy * (pos + segLen)),
                    color, thickness)
                pos += cycle
            }
        }
        dashLine(minX, minY, maxX, minY)  // top
        dashLine(maxX, minY, maxX, maxY)  // right
        dashLine(maxX, maxY, minX, maxY)  // bottom
        dashLine(minX, maxY, minX, minY)  // left
    }
}
