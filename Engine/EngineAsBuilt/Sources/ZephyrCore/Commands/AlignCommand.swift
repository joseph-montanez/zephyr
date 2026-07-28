import Foundation
import CSDL3
import ImGui
import SwiftSDL

// =========================================================================
// MARK: - AlignCommand
//
// AutoCAD ALIGN command — combines move, rotate, and optionally scale into a
// single interactive operation. The user selects objects, then specifies two
// pairs of points (source → destination). The command computes the translation,
// rotation, and optional scaling needed to align the source points with the
// destination points, then applies that transform to all selected entities.
//
// State machine (6 steps):
//   1. "Specify first source point"       → store S1
//   2. "Specify first destination point"  → store D1
//   3. "Specify second source point"      → store S2
//   4. "Specify second destination point" → store D2
//   5. "Scale objects based on alignment points? [Yes/No]" → store scaleObjects
//   6. Execute — compute combined Transform3D → apply → push undo → finish
//
// Edge cases:
//   - S1 == S2 (source coincident): error, restart from step 1
//   - D1 == D2 (dest coincident): pure move (no rotation, no scale)
//   - scaleObjects == false: rotation only, scale factor = 1
// =========================================================================

@MainActor
public final class AlignCommand: FeatureCommand {

    // MARK: - State Machine

    enum AlignStep: Int, CaseIterable {
        case idle             // not started
        case selectObjects    // select objects when ALIGN starts without preselection
        case askSourcePoint1  // "Specify first source point"
        case askDestPoint1    // "Specify first destination point"
        case askSourcePoint2  // "Specify second source point"
        case askDestPoint2    // "Specify second destination point"
        case askScale         // "Scale objects based on alignment points? [Yes/No]"
        case applying         // (transient — apply and finish)
    }

    // MARK: - Stored State

    private var step: AlignStep = .idle
    private var s1: Vector3?  // first source point
    private var s2: Vector3?  // second source point
    private var d1: Vector3?  // first destination point
    private var d2: Vector3?  // second destination point
    private var scaleObjects: Bool = false  // defaults to false (Enter/right-click = No)
    private var currentMouseX: Double = 0
    private var currentMouseY: Double = 0

    // MARK: - Computed Geometry

    /// Source vector (S2 - S1).
    private var sourceVector: Vector3 {
        guard let s1, let s2 else { return .zero }
        return Vector3(x: s2.x - s1.x, y: s2.y - s1.y, z: 0)
    }

    /// Destination vector (D2 - D1).
    private var destVector: Vector3 {
        guard let d1, let d2 else { return .zero }
        return Vector3(x: d2.x - d1.x, y: d2.y - d1.y, z: 0)
    }

    /// Length of source vector.
    private var sourceLength: Double {
        let sv = sourceVector
        return sqrt(sv.x * sv.x + sv.y * sv.y)
    }

    /// Length of destination vector.
    private var destLength: Double {
        let dv = destVector
        return sqrt(dv.x * dv.x + dv.y * dv.y)
    }

    /// Rotation angle (radians) from source to destination orientation.
    private var rotationAngle: Double {
        let sv = sourceVector
        let dv = destVector
        let alpha = atan2(sv.y, sv.x)
        let beta = atan2(dv.y, dv.x)
        return beta - alpha
    }

    /// Scale factor (ld / ls), or 1.0 if not scaling or source length is zero.
    private var scaleFactor: Double {
        let ls = sourceLength
        let ld = destLength
        guard ls > 1e-9 else { return 1.0 }
        return scaleObjects ? ld / ls : 1.0
    }

    public init() {}

    // MARK: - FeatureCommand

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        resetState()
        if engine.cadSelection.hasSelection {
            step = .askSourcePoint1
            processor.commandPrompt = "Specify first source point"
        } else {
            step = .selectObjects
            processor.commandPrompt = "Select objects to align, then press Enter"
        }
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        resetState()
        step = .idle
        processor.commandPrompt = nil
    }

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        switch step {
        case .idle:
            return .finished

        case .selectObjects:
            let threshold = 8.0 / max(engine.camera.zoom, 0.001)
            guard let handle = engine.cadSelection.hitTest(
                worldX: worldX,
                worldY: worldY,
                document: engine.document,
                threshold: threshold,
                simplifyComplexBlocks: engine.simplifyComplexBlocks
            ) else {
                return .handled
            }

            let shiftHeld = engine.io?.pointee.KeyShift ?? false
            if shiftHeld {
                engine.cadSelection.removeFromSelection(handle)
            } else {
                engine.cadSelection.addToSelection(handle)
            }
            processor.commandPrompt = "Select objects to align, then press Enter (\(engine.cadSelection.selectedCount) selected)"
            return .handled

        case .askSourcePoint1:
            s1 = Vector3(x: worldX, y: worldY, z: 0)
            step = .askDestPoint1
            processor.commandPrompt = "Specify first destination point"
            return .continue

        case .askDestPoint1:
            d1 = Vector3(x: worldX, y: worldY, z: 0)
            step = .askSourcePoint2
            processor.commandPrompt = "Specify second source point"
            return .continue

        case .askSourcePoint2:
            s2 = Vector3(x: worldX, y: worldY, z: 0)
            step = .askDestPoint2
            processor.commandPrompt = "Specify second destination point"
            return .continue

        case .askDestPoint2:
            d2 = Vector3(x: worldX, y: worldY, z: 0)
            step = .askScale
            processor.commandPrompt = "Scale objects based on alignment points? [Yes/No] <No>:"
            return .continue

        case .askScale:
            // Confirm scale choice (handled via handleCommandText for Y/Yes or Enter/No)
            return .continue

        case .applying:
            return .finished
        }
    }

    public func handleMouseMotion(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        currentMouseX = worldX
        currentMouseY = worldY
    }

    public func handleKeyDown(
        scancode: SDL_Scancode,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        switch scancode {
        case SDL_SCANCODE_ESCAPE:
            return .finished

        case SDL_SCANCODE_RETURN, SDL_SCANCODE_KP_ENTER:
            return handleEnterKey(engine: engine, processor: processor)

        case SDL_SCANCODE_Y where step == .askScale:
            scaleObjects = true
            return applyAndFinish(engine: engine, processor: processor)

        case SDL_SCANCODE_N where step == .askScale:
            scaleObjects = false
            return applyAndFinish(engine: engine, processor: processor)

        default:
            return .continue
        }
    }

    public func handleCommandText(
        _ text: String,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()

        switch step {
        case .askScale:
            // Accept "Y" or "Yes" for scaling
            if trimmed == "y" || trimmed == "yes" {
                scaleObjects = true
                return applyAndFinish(engine: engine, processor: processor)
            }
            // "N" or "No" — keep scaleObjects = false
            if trimmed == "n" || trimmed == "no" {
                scaleObjects = false
                return applyAndFinish(engine: engine, processor: processor)
            }
            // Anything else: ignore, stay on this step
            return .continue

        default:
            return .continue
        }
    }

    public var isSnappingEnabled: Bool {
        step != .selectObjects && step != .askScale
    }

    public func getDrawingSnapPoints() -> [Vector3] {
        var points: [Vector3] = []
        if let s1 { points.append(s1) }
        if let s2 { points.append(s2) }
        if let d1 { points.append(d1) }
        if let d2 { points.append(d2) }
        return points
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {
        guard step != .idle, step != .applying else { return }

        guard let drawList = igGetForegroundDrawList_ViewportPtr(nil) else { return }

        // Colors matching AutoCAD convention:
        //   Source points: green
        //   Destination points: red / orange
        let greenColor = igGetColorU32_Vec4(ImVec4(x: 0.0, y: 0.8, z: 0.2, w: 1.0))
        let redColor = igGetColorU32_Vec4(ImVec4(x: 0.9, y: 0.2, z: 0.2, w: 1.0))
        let blueColor = igGetColorU32_Vec4(ImVec4(x: 0.3, y: 0.4, z: 0.9, w: 1.0))
        let orangeColor = igGetColorU32_Vec4(ImVec4(x: 0.9, y: 0.6, z: 0.2, w: 1.0))
        let dashedColor = igGetColorU32_Vec4(ImVec4(x: 0.6, y: 0.6, z: 0.6, w: 0.8))

        switch step {
        case .selectObjects:
            break

        case .askSourcePoint1:
            let cursorScreen = EngineCameraManager.worldToScreen(
                worldX: currentMouseX,
                worldY: currentMouseY,
                cam: cam
            )
            ImDrawListAddCircle(
                drawList,
                ImVec2(x: cursorScreen.x, y: cursorScreen.y),
                5.0,
                greenColor,
                0,
                1.5
            )

        case .askDestPoint1:
            guard let s1 else { return }
            let s1Screen = EngineCameraManager.worldToScreen(worldX: s1.x, worldY: s1.y, cam: cam)
            // Draw solid line from S1 to cursor
            let cursorScreen = EngineCameraManager.worldToScreen(worldX: currentMouseX, worldY: currentMouseY, cam: cam)
            ImDrawListAddLine(drawList, ImVec2(x: s1Screen.x, y: s1Screen.y),
                                    ImVec2(x: cursorScreen.x, y: cursorScreen.y),
                                    dashedColor, 1.0)
            // Draw filled green circle at S1
            drawFilledCircle(drawList: drawList, screenX: s1Screen.x, screenY: s1Screen.y,
                             radius: 4.0, color: greenColor)
            // Label
            drawPointLabel(drawList: drawList, screenX: s1Screen.x, screenY: s1Screen.y,
                           label: "S1", color: greenColor)

        case .askSourcePoint2:
            guard let s1, let d1 else { return }
            let s1Screen = EngineCameraManager.worldToScreen(worldX: s1.x, worldY: s1.y, cam: cam)
            let d1Screen = EngineCameraManager.worldToScreen(worldX: d1.x, worldY: d1.y, cam: cam)
            let cursorScreen = EngineCameraManager.worldToScreen(worldX: currentMouseX, worldY: currentMouseY, cam: cam)

            // Solid line S1→D1
            ImDrawListAddLine(drawList, ImVec2(x: s1Screen.x, y: s1Screen.y),
                                    ImVec2(x: d1Screen.x, y: d1Screen.y),
                                    greenColor, 1.5)

            // Dashed line from cursor (preview)
            ImDrawListAddLine(drawList, ImVec2(x: s1Screen.x, y: s1Screen.y),
                                    ImVec2(x: cursorScreen.x, y: cursorScreen.y),
                                    dashedColor, 1.0)

            // Filled circles
            drawFilledCircle(drawList: drawList, screenX: s1Screen.x, screenY: s1Screen.y,
                             radius: 4.0, color: greenColor)
            drawFilledCircle(drawList: drawList, screenX: d1Screen.x, screenY: d1Screen.y,
                             radius: 4.0, color: redColor)

            // Labels
            drawPointLabel(drawList: drawList, screenX: s1Screen.x, screenY: s1Screen.y,
                           label: "S1", color: greenColor)
            drawPointLabel(drawList: drawList, screenX: d1Screen.x, screenY: d1Screen.y,
                           label: "D1", color: redColor)

        case .askDestPoint2:
            guard let s1, let d1, let s2 else { return }
            let s1Screen = EngineCameraManager.worldToScreen(worldX: s1.x, worldY: s1.y, cam: cam)
            let d1Screen = EngineCameraManager.worldToScreen(worldX: d1.x, worldY: d1.y, cam: cam)
            let s2Screen = EngineCameraManager.worldToScreen(worldX: s2.x, worldY: s2.y, cam: cam)
            let cursorScreen = EngineCameraManager.worldToScreen(worldX: currentMouseX, worldY: currentMouseY, cam: cam)

            // Solid lines: S1→D1 and S2→(current cursor)
            ImDrawListAddLine(drawList, ImVec2(x: s1Screen.x, y: s1Screen.y),
                                    ImVec2(x: d1Screen.x, y: d1Screen.y),
                                    greenColor, 1.5)
            ImDrawListAddLine(drawList, ImVec2(x: s2Screen.x, y: s2Screen.y),
                                    ImVec2(x: cursorScreen.x, y: cursorScreen.y),
                                    dashedColor, 1.0)

            // Filled circles
            drawFilledCircle(drawList: drawList, screenX: s1Screen.x, screenY: s1Screen.y,
                             radius: 4.0, color: greenColor)
            drawFilledCircle(drawList: drawList, screenX: d1Screen.x, screenY: d1Screen.y,
                             radius: 4.0, color: redColor)
            drawFilledCircle(drawList: drawList, screenX: s2Screen.x, screenY: s2Screen.y,
                             radius: 4.0, color: blueColor)

            // Labels
            drawPointLabel(drawList: drawList, screenX: s1Screen.x, screenY: s1Screen.y,
                           label: "S1", color: greenColor)
            drawPointLabel(drawList: drawList, screenX: d1Screen.x, screenY: d1Screen.y,
                           label: "D1", color: redColor)
            drawPointLabel(drawList: drawList, screenX: s2Screen.x, screenY: s2Screen.y,
                           label: "S2", color: blueColor)

        case .askScale:
            guard let s1, let d1, let s2, let d2 else { return }
            let s1Screen = EngineCameraManager.worldToScreen(worldX: s1.x, worldY: s1.y, cam: cam)
            let d1Screen = EngineCameraManager.worldToScreen(worldX: d1.x, worldY: d1.y, cam: cam)
            let s2Screen = EngineCameraManager.worldToScreen(worldX: s2.x, worldY: s2.y, cam: cam)
            let d2Screen = EngineCameraManager.worldToScreen(worldX: d2.x, worldY: d2.y, cam: cam)

            // Solid lines: S1→D1 and S2→D2
            ImDrawListAddLine(drawList, ImVec2(x: s1Screen.x, y: s1Screen.y),
                                    ImVec2(x: d1Screen.x, y: d1Screen.y),
                                    greenColor, 1.5)
            ImDrawListAddLine(drawList, ImVec2(x: s2Screen.x, y: s2Screen.y),
                                    ImVec2(x: d2Screen.x, y: d2Screen.y),
                                    orangeColor, 1.5)

            // Filled circles
            drawFilledCircle(drawList: drawList, screenX: s1Screen.x, screenY: s1Screen.y,
                             radius: 5.0, color: greenColor)
            drawFilledCircle(drawList: drawList, screenX: d1Screen.x, screenY: d1Screen.y,
                             radius: 5.0, color: redColor)
            drawFilledCircle(drawList: drawList, screenX: s2Screen.x, screenY: s2Screen.y,
                             radius: 5.0, color: blueColor)
            drawFilledCircle(drawList: drawList, screenX: d2Screen.x, screenY: d2Screen.y,
                             radius: 5.0, color: orangeColor)

            // Labels
            drawPointLabel(drawList: drawList, screenX: s1Screen.x, screenY: s1Screen.y,
                           label: "S1", color: greenColor)
            drawPointLabel(drawList: drawList, screenX: d1Screen.x, screenY: d1Screen.y,
                           label: "D1", color: redColor)
            drawPointLabel(drawList: drawList, screenX: s2Screen.x, screenY: s2Screen.y,
                           label: "S2", color: blueColor)
            drawPointLabel(drawList: drawList, screenX: d2Screen.x, screenY: d2Screen.y,
                           label: "D2", color: orangeColor)

            // If scaling is enabled, show a ghosted preview of the transform
            if scaleObjects {
                renderScalePreview(drawList: drawList, engine: engine, cam: cam)
            }

            drawScaleChoicePrompt(
                drawList: drawList,
                anchorX: d2Screen.x,
                anchorY: d2Screen.y,
                engine: engine
            )

        case .idle, .applying:
            break
        }
    }

    public func renderImGui(engine: PhrostEngine) {
        // No special ImGui dialogs needed.
    }
}

// MARK: - Private Helpers

extension AlignCommand {

    private func resetState() {
        step = .idle
        s1 = nil
        s2 = nil
        d1 = nil
        d2 = nil
        scaleObjects = false
        currentMouseX = 0
        currentMouseY = 0
    }

    private func handleEnterKey(
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        switch step {
        case .selectObjects:
            guard engine.cadSelection.hasSelection else {
                processor.commandPrompt = "Select at least one object to align, then press Enter"
                return .handled
            }
            step = .askSourcePoint1
            processor.commandPrompt = "Specify first source point"
            return .handled

        case .askSourcePoint1, .askDestPoint1, .askSourcePoint2, .askDestPoint2:
            // Enter at any point-picking step: treat as if the user clicked at current cursor position.
            // This allows numeric entry via the command line instead of mouse clicks.
            let worldX = currentMouseX
            let worldY = currentMouseY
            switch step {
            case .askSourcePoint1:
                s1 = Vector3(x: worldX, y: worldY, z: 0)
                step = .askDestPoint1
                processor.commandPrompt = "Specify first destination point"
            case .askDestPoint1:
                d1 = Vector3(x: worldX, y: worldY, z: 0)
                step = .askSourcePoint2
                processor.commandPrompt = "Specify second source point"
            case .askSourcePoint2:
                s2 = Vector3(x: worldX, y: worldY, z: 0)
                step = .askDestPoint2
                processor.commandPrompt = "Specify second destination point"
            case .askDestPoint2:
                d2 = Vector3(x: worldX, y: worldY, z: 0)
                step = .askScale
                processor.commandPrompt = "Scale objects based on alignment points? [Yes/No] <No>:"
            default:
                break
            }
            return .continue

        case .askScale:
            // Enter at scale prompt: default to "No" (no scaling)
            scaleObjects = false
            return applyAndFinish(engine: engine, processor: processor)

        case .idle, .applying:
            return .finished
        }
    }

    /// Compute the combined Transform3D from two source/destination point pairs.
    private func computeTransform() -> Transform3D? {
        guard let s1, let d1, s2 != nil, d2 != nil else { return nil }

        let sv = sourceVector
        let dv = destVector
        let ls = sourceLength
        let ld = destLength

        // Edge case: source points are coincident — cannot compute rotation or scale.
        if ls < 1e-9 {
            print("[CAD] ALIGN: Source points are coincident — cannot compute rotation.")
            return nil
        }

        // Edge case: destination points are coincident — pure move (no rotation, no scale).
        if ld < 1e-9 {
            let translation = Transform3D.translated(by: Vector3(x: d1.x - s1.x, y: d1.y - s1.y, z: 0))
            return translation
        }

        // Source angle and destination angle
        let alpha = atan2(sv.y, sv.x)
        let beta = atan2(dv.y, dv.x)
        let theta = beta - alpha

        // Scale factor
        let sf = scaleObjects ? ld / ls : 1.0

        // Construct combined transform: T = Translation(D1) × Scale × Rotation × Translation(-S1)
        let s1ToOrigin = Transform3D.translated(by: Vector3(x: -s1.x, y: -s1.y, z: 0))
        let rotation = Transform3D.rotated(by: theta)
        let scaleMatrix = Transform3D.scaled(by: Vector3(x: sf, y: sf, z: 1))
        let originToD1 = Transform3D.translated(by: Vector3(x: d1.x, y: d1.y, z: 0))

        return originToD1.multiplying(by: scaleMatrix.multiplying(by: rotation.multiplying(by: s1ToOrigin)))
    }

    /// Apply the computed transform to all selected entities and finish.
    private func applyAndFinish(
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        guard let s1, let s2, let d1, let d2 else {
            resetState()
            processor.clearCommand()
            return .finished
        }

        // Check for coincident source points (error case).
        let ls = sourceLength
        if ls < 1e-9 {
            print("[CAD] ALIGN: Source points are coincident — cannot compute rotation.")
            resetState()
            processor.clearCommand()
            return .finished
        }

        let ld = destLength

        // Apply the transform to all selected entities
        let handles = engine.cadSelection.selectedHandles

        // Update document entities (pushes undo)
        engine.document.alignEntities(
            handles: handles,
            sourcePoint1: s1,
            sourcePoint2: s2,
            destPoint1: d1,
            destPoint2: d2,
            scaleObjects: scaleObjects
        )

        // Update grips
        engine.interaction.cachedGripGeneration = -1

        // Print status message
        if ld < 1e-9 {
            print("[CAD] ALIGN: Destination points are coincident — performing move only.")
        } else if !scaleObjects {
            print("[CAD] ALIGN: Rotated without scaling. \(Int(handles.count)) entities aligned.")
        } else {
            let sf = scaleFactor
            print("[CAD] ALIGN: Aligned with scale factor \(String(format: "%.4f", sf)). \(Int(handles.count)) entities aligned.")
        }

        // Clean up
        resetState()
        processor.clearCommand()
        return .finished
    }

    // MARK: - Overlay Drawing Helpers

    private func drawFilledCircle(drawList: UnsafeMutablePointer<ImDrawList>, screenX: Float, screenY: Float,
                                   radius: Float, color: ImU32) {
        ImDrawListAddCircleFilled(drawList, ImVec2(x: screenX, y: screenY), radius, color, 0)
    }

    private func drawPointLabel(drawList: UnsafeMutablePointer<ImDrawList>, screenX: Float, screenY: Float,
                                 label: String, color: ImU32) {
        // Draw label offset from the point
        let labelX = screenX + 8.0
        let labelY = screenY - 12.0
        ImDrawListAddText(drawList, ImVec2(x: labelX, y: labelY), color, label, nil)
    }

    private func drawScaleChoicePrompt(
        drawList: UnsafeMutablePointer<ImDrawList>,
        anchorX: Float,
        anchorY: Float,
        engine: PhrostEngine
    ) {
        let ratio = sourceLength > 1e-9 ? destLength / sourceLength : 1.0
        let title = "Scale objects to alignment points?"
        let yesText = "Y  Scale to \(String(format: "%.4f", ratio))x"
        let noText = "N / Enter  Keep current size"

        let titleSize = ImGuiCalcTextSize(title, nil, false, -1)
        let yesSize = ImGuiCalcTextSize(yesText, nil, false, -1)
        let noSize = ImGuiCalcTextSize(noText, nil, false, -1)
        let paddingX: Float = 12.0
        let paddingY: Float = 9.0
        let lineGap: Float = 4.0
        let width = max(titleSize.x, max(yesSize.x, noSize.x)) + paddingX * 2.0
        let height = titleSize.y + yesSize.y + noSize.y + lineGap * 2.0 + paddingY * 2.0

        let io = ImGuiGetIO()
        let displaySize = io?.pointee.DisplaySize ?? ImVec2(x: 1920, y: 1080)
        var x = anchorX + 18.0
        var y = anchorY + 18.0
        if x + width > displaySize.x - 8.0 {
            x = anchorX - width - 18.0
        }
        if y + height > displaySize.y - 8.0 {
            y = anchorY - height - 18.0
        }
        x = max(8.0, x)
        y = max(8.0, y)

        let panel = engine.ui.theme.panelBg
        let backgroundColor = igGetColorU32_Vec4(
            ImVec4(x: panel.x, y: panel.y, z: panel.z, w: 0.96)
        )
        let borderColor = igGetColorU32_Vec4(engine.ui.theme.brandGold)
        let titleColor = igGetColorU32_Vec4(engine.ui.theme.textPrimary)
        let yesColor = igGetColorU32_Vec4(engine.ui.theme.brandGold)
        let noColor = igGetColorU32_Vec4(engine.ui.theme.textDim)
        let minPoint = ImVec2(x: x, y: y)
        let maxPoint = ImVec2(x: x + width, y: y + height)

        ImDrawListAddRectFilled(drawList, minPoint, maxPoint, backgroundColor, 6.0, 0)
        ImDrawListAddRect(drawList, minPoint, maxPoint, borderColor, 6.0, 1.0, 0)

        var textY = y + paddingY
        ImDrawListAddText(
            drawList,
            ImVec2(x: x + paddingX, y: textY),
            titleColor,
            title,
            nil
        )
        textY += titleSize.y + lineGap
        ImDrawListAddText(
            drawList,
            ImVec2(x: x + paddingX, y: textY),
            yesColor,
            yesText,
            nil
        )
        textY += yesSize.y + lineGap
        ImDrawListAddText(
            drawList,
            ImVec2(x: x + paddingX, y: textY),
            noColor,
            noText,
            nil
        )
    }

    /// Render a ghosted preview of the selection at the computed transform (for scale step).
    private func renderScalePreview(drawList: UnsafeMutablePointer<ImDrawList>, engine: PhrostEngine, cam: CameraTransform) {
        guard s1 != nil, s2 != nil, d1 != nil, d2 != nil else { return }

        // Compute the transform (same logic as applyAndFinish but without applying)
        guard let finalTransform = computeTransform() else { return }

        // Draw a semi-transparent outline of each selected entity's bounding box
        // at the transformed position. This gives the user a preview of the result.
        for handle in engine.cadSelection.selectedHandles {
            guard let entity = engine.document.entity(for: handle) else { continue }
            guard let bb = entity.worldBoundingBox else { continue }

            // Transform the bounding box corners
            let corners = [
                Vector3(x: bb.min.x, y: bb.min.y, z: bb.min.z),
                Vector3(x: bb.max.x, y: bb.min.y, z: bb.min.z),
                Vector3(x: bb.max.x, y: bb.max.y, z: bb.min.z),
                Vector3(x: bb.min.x, y: bb.max.y, z: bb.min.z)
            ]

            let transformedCorners = corners.map { finalTransform.transformPoint($0) }
            let screenCorners = transformedCorners.map {
                EngineCameraManager.worldToScreen(worldX: $0.x, worldY: $0.y, cam: cam)
            }

            let outlineColor = (UInt32(64) << 24) | (UInt32(0) << 16) | (UInt32(255) << 8) | UInt32(255)
            for i in 0..<screenCorners.count {
                let a = screenCorners[i]
                let b = screenCorners[(i + 1) % screenCorners.count]
                ImDrawListAddLine(
                    drawList,
                    ImVec2(x: a.x, y: a.y),
                    ImVec2(x: b.x, y: b.y),
                    outlineColor,
                    1.0
                )
            }
        }
    }
}
