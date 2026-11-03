import ZephyrCore
import Foundation
import ImGui

// MARK: - StatusBarUI
//
// Renders the status bar anchored to the bottom of the window.
// Displays two sets of information:
//   Left side: Tab name, dirty marker, active layer, entity count,
//              undo/redo depth, pan mode indicator
//   Right side: FPS counter, primitive count, sprite count, camera zoom
//
// Left-side text is computed from the tab/view shown in the window
// being rendered (see `StatusBarUIPolicy`), never from the global
// active tab: each OS window reports its own drawing.

@MainActor
struct StatusBarUI {
    /// Renders the status bar at the bottom edge.
    /// - Parameters:
    ///   - engine: The engine instance.
    ///   - io: ImGui IO pointer for FPS and display metrics.
    ///   - dw: Display width.
    ///   - dh: Display height.
    static func render(
        engine: PhrostEngine, io: UnsafeMutablePointer<ImGuiIO>,
        dw: Float, dh: Float,
        shownTab: DocumentTab?, shownViewIndex: Int
    ) {
        // Per-window status: filename/view/layer/entities describe the
        // drawing this window (or focused pane) shows. The old code read
        // the one active tab into a single shared cache, so every OS
        // window reported the active drawing.
        let info = StatusBarUIPolicy.shownInfo(tab: shownTab, viewIndex: shownViewIndex)
        let saveState = shownTab.flatMap { engine.tabManager.saveStateByTabID[$0.id] }

        let statusLeft: String
        if let ss = saveState {
            let pct = Int(ss.progress * 100)
            if case .failed(let msg) = ss.status {
                statusLeft = "Save failed: \(msg)"
                // Auto-clear after 3 seconds (clearing is active-tab scoped).
                if let failedAt = ss.failedAt, Date().timeIntervalSince(failedAt) > 3,
                   shownTab?.id == engine.tabManager.activeTab?.id {
                    engine.tabManager.clearSaveError()
                }
            } else {
                statusLeft = "\(ss.statusText) \(pct)%"
            }
        } else {
            // Build snap tracking indicators (app-global snap settings).
            var trackingParts: [String] = []
            if engine.snap.polarTrackingEnabled {
                trackingParts.append("POLAR(\(Int(engine.snap.polarAngleIncrement))°)")
            }
            if engine.snap.objectSnapTrackingEnabled {
                let tpCount = engine.snap.snapTrackingEngine.trackingPoints.count
                trackingParts.append(tpCount > 0 ? "OTRACK(\(tpCount))" : "OTRACK")
            }
            if engine.snap.extensionSnapEnabled {
                trackingParts.append("EXT")
            }
            if engine.snap.orthoEnabled {
                trackingParts.append("ORTHO")
            }
            let trackingStr = trackingParts.isEmpty ? "" : "  ·  " + trackingParts.joined(separator: "  ·  ")
            var layerSuffix = ""
            if let tab = shownTab, !tab.drawingViews.isEmpty {
                let clamped = max(0, min(shownViewIndex, tab.drawingViews.count - 1))
                layerSuffix = LayerManagerModel.statusBarSuffix(
                    in: tab.drawingViews[clamped].document)
            }
            statusLeft = StatusBarUIPolicy.leftText(
                info: info, trackingSuffix: trackingStr + layerSuffix)
        }

        let barH = AppLayout.statusBarHeight
        let barY = dh - barH

        ImGuiSetNextWindowPos(
            ImVec2(x: 0, y: barY),
            Int32(ImGuiCond_Always.rawValue),
            ImVec2(x: 0, y: 0))
        ImGuiSetNextWindowSize(
            ImVec2(x: dw, y: barH),
            Int32(ImGuiCond_Always.rawValue))

        ImGuiPushStyleVarX(Int32(ImGuiStyleVar_WindowPadding.rawValue), 16)
        ImGuiPushStyleVarY(Int32(ImGuiStyleVar_WindowPadding.rawValue), 6)
        ImGuiPushStyleColor(Int32(ImGuiCol_WindowBg.rawValue), engine.ui.theme.panelBg) // Navy background
        ImGuiPushStyleColor(Int32(ImGuiCol_Text.rawValue), engine.ui.theme.textDim) // Dim text

        var opened = true
        let flags: Int32 = 1 | 2 | 4 | 8 | 256
        if igBegin("##StatusBar", &opened, flags) {

            ImGuiSetCursorPosX(16)
            ImGuiTextV(statusLeft)

            // Xref attention indicator (broken/stale external references).
            if let shownTab,
               XrefPalettePolicy.hasWarning(store: shownTab.xrefStore)
                || XrefPalettePolicy.hasMediaWarning(store: shownTab.mediaStore) {
                ImGuiSameLine(0, 8)
                if igSmallButton("XREF ⚠") {
                    engine.ui.xrefPanelVisible = true
                }
            }

            // Save failure indicator
            if let ss = saveState, case .failed = ss.status {
                ImGuiSameLine(0, 8)
                let redColor = ImVec4(x: 1, y: 0.3, z: 0.3, w: 1)
                ImGuiPushStyleColor(Int32(ImGuiCol_Text.rawValue), redColor)
                ImGuiTextV("✕")
                ImGuiPopStyleColor(1)
            }

            // Right side: Coordinates (focused pane's transform while split).
            let coordCam: CameraTransform = {
                guard engine.mainPanes.isSplit,
                      let canvasF = engine.ui.drawingViewportRect else {
                    return engine.camera.currentTransform(windowWidth: Int32(dw), windowHeight: Int32(dh))
                }
                let canvas = PaneRect(x: canvasF.x, y: canvasF.y, w: canvasF.w, h: canvasF.h)
                let leaves = engine.mainPanes.leafRects(canvas: canvas)
                guard let focused = leaves.first(where: { $0.id == engine.mainPanes.focusedLeafID }) else {
                    return engine.camera.currentTransform(windowWidth: Int32(dw), windowHeight: Int32(dh))
                }
                return engine.camera.transformForSubRect(
                    originX: Double(focused.rect.x), originY: Double(focused.rect.y),
                    width: Int32(focused.rect.w), height: Int32(focused.rect.h))
            }()
            let mousePos = EngineCameraManager.screenToWorld(screenX: io.pointee.MousePos.x, screenY: io.pointee.MousePos.y, cam: coordCam)
            let coordText = String(format: "%.3f, %.3f", mousePos.0, mousePos.1)
            let textSize = ImGuiCalcTextSize(coordText, nil, false, -1)
            
            let rx = dw - textSize.x - 16
            if rx > 0 { ImGuiSetCursorPosX(rx) }
            ImGuiTextV(coordText)
        }
        igEnd()

        ImGuiPopStyleColor(2)
        ImGuiPopStyleVar(2)
    }
}
