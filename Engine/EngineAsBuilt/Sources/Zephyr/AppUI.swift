import ZephyrCore
import Foundation
import ImGui

// MARK: - AppUI
//
// The top-level UI rendering orchestrator. Called once per frame by the
// engine's ImGui frame callback. It lays out all visible panels, chrome,
// and dialogs in the correct order and handles the mini-toolbar fallback
// when the full toolbar is hidden.
//
// Rendering order matters for z-ordering and docking-like behavior:
//   1. Tab Bar (top)
//   2. Side panels: Layers, Draw Palette
//   3. Toolbar or mini-toolbar
//   4. File dialogs (modal overlays)
//   5. Properties panel
//   6. Block panel
//   7. Command Line (bottom, if active)
//   8. Layer Move dialog (modal, if active)
//   9. Status Bar (very bottom)
//  10. Block Editor Banner (if editing a block)

@MainActor
struct AppUI {
    /// Called once per frame by the engine to render the entire UI.
    /// Orders all panels, chrome, and dialogs in the correct z-order.
    /// - Parameters:
    ///   - engine: The PhrostEngine instance providing state and services.
    static func render(engine: PhrostEngine) {
        // Get the current display size from ImGui's IO context.
        let io = ImGuiGetIO()!
        let dw = io.pointee.DisplaySize.x
        let dh = io.pointee.DisplaySize.y

        // Create a dockspace covering the work area
        let topOffset = AppLayout.topChromeHeight + AppLayout.tabBarHeight
        let bottomOffset = AppLayout.statusBarHeight
        let workH = dh - topOffset - bottomOffset

        ImGuiSetNextWindowPos(ImVec2(x: 0, y: topOffset), Int32(ImGuiCond_Always.rawValue), ImVec2(x: 0, y: 0))
        ImGuiSetNextWindowSize(ImVec2(x: dw, y: workH), Int32(ImGuiCond_Always.rawValue))

        ImGuiPushStyleVar(Int32(ImGuiStyleVar_WindowRounding.rawValue), Float(0.0))
        ImGuiPushStyleVar(Int32(ImGuiStyleVar_WindowBorderSize.rawValue), Float(0.0))
        ImGuiPushStyleVar(Int32(ImGuiStyleVar_WindowPadding.rawValue), ImVec2(x: 0, y: 0))

        let hostFlags: Int32 =
            Int32(ImGuiWindowFlags_NoTitleBar.rawValue) |
            Int32(ImGuiWindowFlags_NoCollapse.rawValue) |
            Int32(ImGuiWindowFlags_NoResize.rawValue) |
            Int32(ImGuiWindowFlags_NoMove.rawValue) |
            Int32(ImGuiWindowFlags_NoBringToFrontOnFocus.rawValue) |
            Int32(ImGuiWindowFlags_NoNavFocus.rawValue) |
            Int32(ImGuiWindowFlags_NoBackground.rawValue)

        var open = true
        if igBegin("MainWorkspace", &open, hostFlags) {
            igDockSpace(igGetID_Str("MainDockSpace"), ImVec2(x: 0, y: 0), Int32(ImGuiDockNodeFlags_PassthruCentralNode.rawValue), nil)
        }
        igEnd()

        ImGuiPopStyleVar(3)

        // 0. Custom Top Chrome (window header)
        if AppLayout.topChromeHeight > 0 {
            TopChromeUI.render(engine: engine, dw: dw)
        }

        // 1. Tab bar at the very top.
        TabBarUI.render(engine: engine, dw: dw)

        // 2. Side panels — Layers on the left.
        if engine.ui.layersPanelVisible {
            LayerPanelUI.render(engine: engine)
        }

        // 3. Draw palette — optional side panel for drawing tools.
        if engine.ui.drawPaletteVisible {
            DrawPaletteUI.render(engine: engine)
        }

        // 4. Toolbar removed in redesign. Functionality moved to command line.

        // 5. File browser dialogs (native-style modal overlays).
        engine.fileBrowser.render(ui: engine.ui)
        engine.saveFileBrowser.render(ui: engine.ui)

        // 6. Properties panel — shows selected entity details.
        PropertiesPanelUI.render(engine: engine)

        // 6b. Hatch editing ribbon — appears when a hatch entity is selected
        //     and no hatch creation command is active.
        if engine.commandProcessor.activeFeatureCommand == nil,
           engine.cadSelection.selectedCount == 1,
           let handle = engine.cadSelection.lastSelectedHandle,
           let entity = engine.document.entity(for: handle) {
            renderHatchEditingRibbonIfNeeded(entity: entity, engine: engine)
        }

        // 7. Block management panel — list/create/edit blocks.
        if engine.ui.blockPanelVisible {
            BlockPanelUI.render(engine: engine)
        }

        // 7b. Data Table panel — list/create/edit ACAD_TABLE entities.
        if engine.ui.dataTablePanelVisible {
            DataTablePanelUI.render(engine: engine)
        }

        // 8. Command line overlay at the bottom (when active via Space key).
        CommandLineUI.render(engine: engine, dw: dw, dh: dh)

        // 9. Layer-move modal dialog (when moving entities between layers).
        if engine.ui.layerMoveActive {
            LayerMoveUI.render(engine: engine, dw: dw, dh: dh)
        }

        // 9b. Text editor modal dialog (when creating/editing text).
        if engine.textManager.isEditorActive {
            let result = TextEditorUI.render(state: &engine.textManager.editorState, dw: dw, dh: dh)
            switch result {
            case .active:
                break // Still open
            case .confirmed:
                print("[AppUI] Text editor confirmed")
                engine.textManager.isEditorActive = false
                engine.textManager.editorResult = result
            case .cancelled:
                print("[AppUI] Text editor cancelled")
                engine.textManager.isEditorActive = false
                engine.textManager.editorResult = result
            }
        }

        // 10. Status bar at the very bottom — shows entity count, FPS, etc.
        StatusBarUI.render(engine: engine, io: io, dw: dw, dh: dh)

        // 11. (Removed: Block editor banner now fully integrated into titlebar)

        // 11b. Block editor close-confirmation popup (Save / Discard / Cancel).
        //      Triggered by the titlebar "Save & Close" button or BCLOSE command.
        if engine.ui.blockClosePending {
            let blockName: String
            if let blockID = engine.tabManager.activeTab?.editingBlockID {
                if let block = engine.tabManager.activeTab?.document.block(for: blockID) {
                    blockName = block.name
                } else if let block = engine.tabManager.activeTab?.parentDocument?.block(for: blockID) {
                    blockName = block.name
                } else {
                    blockName = "Unknown Block"
                }
            } else {
                blockName = "Unknown Block"
            }

            ImGuiOpenPopup("Close Block Editor##BlockClose", Int32(ImGuiPopupFlags_None.rawValue))

            let popupW: Float = 360
            let popupH: Float = 100
            ImGuiSetNextWindowPos(
                ImVec2(x: (dw - popupW) * 0.5, y: 150),
                Int32(ImGuiCond_Appearing.rawValue),
                ImVec2(x: 0, y: 0))
            ImGuiSetNextWindowSize(ImVec2(x: popupW, y: popupH), Int32(ImGuiCond_Appearing.rawValue))

            var popupOpen = true
            if ImGuiBeginPopupModal("Close Block Editor##BlockClose", &popupOpen,
                                    Int32(ImGuiWindowFlags_NoSavedSettings.rawValue)) {
                defer { ImGuiEndPopup() }

                if !popupOpen {
                    engine.ui.blockClosePending = false
                } else {
                    ImGuiTextV("Save changes to block \"\(blockName)\" before closing?")

                    igSeparator()

                    if igSmallButton("Save") {
                        engine.tabManager.exitBlockEditor(saveChanges: true)
                        engine.ui.blockClosePending = false
                        ImGuiCloseCurrentPopup()
                    }
                    ImGuiSameLine(0, 8)
                    if igSmallButton("Discard") {
                        engine.tabManager.exitBlockEditor(saveChanges: false)
                        engine.ui.blockClosePending = false
                        ImGuiCloseCurrentPopup()
                    }
                    ImGuiSameLine(0, 8)
                    if igSmallButton("Cancel") {
                        engine.ui.blockClosePending = false
                        ImGuiCloseCurrentPopup()
                    }
                }
            }
        }

        // 12. Radial Navigation Tool (Artrage style)
        if engine.ui.radialNavVisible {
            RadialNavUI.render(engine: engine, dw: dw, dh: dh)
        }
    }

    // MARK: - Hatch editing ribbon

    private struct HatchEditPayload {
        var fillType: Int32
        var patternName: String
        var gradientName: String
        var scale: Double
        var angle: Double
        var primaryColor: ColorRGBA?
        var backgroundColor: ColorRGBA?
        var secondaryColor: ColorRGBA?
        var outer: [Vector3]
        var holes: [[Vector3]]
    }

    private static func renderHatchEditingRibbonIfNeeded(entity: CADEntity, engine: PhrostEngine) {
        guard let payload = hatchEditPayload(from: entity) else { return }

        var settings = HatchRibbonUI.Settings(
            fillType: payload.fillType,
            patternName: payload.patternName,
            gradientName: payload.gradientName,
            scale: Float(payload.scale),
            angle: Float(payload.angle),
            primaryColor: payload.primaryColor,
            backgroundColor: payload.backgroundColor,
            secondaryColor: payload.secondaryColor,
            selectionMode: 0,
            showModeSection: false
        )
        let oldSettings = settings
        HatchRibbonUI.render(&settings, engine: engine)

        guard settings.closeRequested || settings != oldSettings else { return }

        let newPattern = hatchPatternName(from: settings)
        let newGeometry = buildHatchGeometry(
            outer: payload.outer,
            holes: payload.holes,
            settings: settings,
            patternName: newPattern)

        var newEntity = entity
        newEntity.xdata["dxf.hatchPatternName"] = .string(newPattern)
        newEntity.xdata["dxf.hatchPatternType"] = .string(DXFHatchGenerator.patternKindName(for: newPattern))
        newEntity.xdata["dxf.hatchScale"] = .double(Double(settings.scale))
        newEntity.xdata["dxf.hatchAngle"] = .double(Double(settings.angle))
        newEntity.xdata["dxf.hatchSpacing"] = .double(DXFHatchGenerator.effectiveSpacing(patternName: newPattern, scale: Double(settings.scale)))
        newEntity.localGeometry = newGeometry

        if settings.closeRequested {
            engine.document.updateEntity(newEntity)
            engine.cadSelection.clearSelection()
        } else {
            engine.document.updateEntityLive(newEntity)
            engine.tabManager.markActiveDirty()
        }
    }

    private static func hatchEditPayload(from entity: CADEntity) -> HatchEditPayload? {
        guard let geometry = entity.localGeometry else { return nil }

        if let gradient = geometry.compactMap({ prim -> HatchEditPayload? in
            guard case .gradient(let outer, let holes, let name, let angle, let c1, let c2) = prim else { return nil }
            return HatchEditPayload(
                fillType: 2,
                patternName: editablePatternNameFromXData(entity) ?? "ANSI31",
                gradientName: name,
                scale: 1.0,
                angle: angle,
                primaryColor: c1,
                backgroundColor: nil,
                secondaryColor: c2,
                outer: normalizedLoop(outer),
                holes: holes.map { normalizedLoop($0) }.filter { $0.count >= 3 })
        }).first {
            return gradient
        }

        let hatch = geometry.compactMap { prim -> (boundary: [Vector3], pattern: String, scale: Double, angle: Double, color: ColorRGBA?, background: ColorRGBA?)? in
            guard case .hatch(let boundary, let pattern, let scale, let angle, let color, let background) = prim else { return nil }
            return (boundary, pattern, scale, angle, color, background)
        }.first

        let complex = geometry.compactMap { prim -> (outer: [Vector3], holes: [[Vector3]], color: ColorRGBA?)? in
            guard case .fillComplexPolygon(let outer, let holes, let color) = prim else { return nil }
            return (outer, holes, color)
        }.first

        let transparentLoops = geometry.compactMap { prim -> [Vector3]? in
            guard case .polygon(let points, let color) = prim, color?.a == 0 else { return nil }
            return normalizedLoop(points)
        }.filter { $0.count >= 3 }

        let loops: (outer: [Vector3], holes: [[Vector3]])
        if let complex {
            loops = (normalizedLoop(complex.outer), complex.holes.map { normalizedLoop($0) }.filter { $0.count >= 3 })
        } else if !transparentLoops.isEmpty {
            loops = classifyLoops(transparentLoops)
        } else if let hatch {
            loops = splitConnectedHatchBoundary(hatch.boundary)
        } else {
            return nil
        }

        guard loops.outer.count >= 3 else { return nil }

        if let hatch {
            let rawPattern = patternNameFromXData(entity) ?? hatch.pattern
            let pattern = rawPattern.isEmpty ? "SOLID" : rawPattern.uppercased()
            let fillType: Int32 = {
                if pattern == "USER" { return 3 }
                if pattern == "SOLID" { return 1 }
                return 0
            }()
            return HatchEditPayload(
                fillType: fillType,
                patternName: pattern == "SOLID" || pattern == "GRADIENT" || pattern == "USER" ? "ANSI31" : pattern,
                gradientName: "LINEAR",
                scale: hatch.scale,
                angle: hatch.angle,
                primaryColor: hatch.color,
                backgroundColor: complex?.color ?? hatch.background,
                secondaryColor: nil,
                outer: loops.outer,
                holes: loops.holes)
        }

        guard complex != nil || isHatchEntityByXData(entity) else { return nil }
        return HatchEditPayload(
            fillType: 1,
            patternName: editablePatternNameFromXData(entity) ?? "ANSI31",
            gradientName: "LINEAR",
            scale: 1.0,
            angle: 0.0,
            primaryColor: complex?.color,
            backgroundColor: nil,
            secondaryColor: nil,
            outer: loops.outer,
            holes: loops.holes)
    }

    private static func buildHatchGeometry(
        outer: [Vector3],
        holes: [[Vector3]],
        settings: HatchRibbonUI.Settings,
        patternName: String
    ) -> [CADPrimitive] {
        let cleanOuter = normalizedLoop(outer)
        let cleanHoles = holes.map { normalizedLoop($0) }.filter { $0.count >= 3 }
        let scale = Double(settings.scale)
        let angle = Double(settings.angle)

        switch settings.fillType {
        case 2:
            let c1 = settings.primaryColor ?? ColorRGBA(r: 255, g: 255, b: 255, a: 255)
            let c2 = settings.secondaryColor ?? ColorRGBA(r: 255, g: 255, b: 255, a: 255)
            return [.gradient(
                outer: cleanOuter,
                holes: cleanHoles,
                gradientName: settings.gradientName,
                angle: angle,
                color1: c1,
                color2: c2)]
        case 1:
            return [.fillComplexPolygon(outer: cleanOuter, holes: cleanHoles, color: settings.primaryColor)]
        default:
            var prims: [CADPrimitive] = []
            if settings.fillType == 0, let bg = settings.backgroundColor {
                prims.append(.fillComplexPolygon(outer: cleanOuter, holes: cleanHoles, color: bg))
            }
            let patternBoundary = cleanHoles.isEmpty
                ? cleanOuter
                : DXFHatchGenerator.connectHoles(outer: cleanOuter, holes: cleanHoles)
            prims.append(.hatch(
                boundary: patternBoundary,
                pattern: patternName,
                scale: scale,
                angle: angle,
                color: settings.primaryColor,
                backgroundColor: nil))
            return prims
        }
    }

    private static func hatchPatternName(from settings: HatchRibbonUI.Settings) -> String {
        switch settings.fillType {
        case 1: return "SOLID"
        case 2: return "GRADIENT"
        case 3: return "USER"
        default:
            let p = settings.patternName.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            return p.isEmpty ? "ANSI31" : p
        }
    }

    private static func patternNameFromXData(_ entity: CADEntity) -> String? {
        guard case .string(let value)? = entity.xdata["dxf.hatchPatternName"] else { return nil }
        let pattern = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return pattern.isEmpty ? nil : pattern
    }

    private static func editablePatternNameFromXData(_ entity: CADEntity) -> String? {
        guard let pattern = patternNameFromXData(entity), pattern != "SOLID", pattern != "GRADIENT", pattern != "USER" else { return nil }
        return pattern
    }

    private static func isHatchEntityByXData(_ entity: CADEntity) -> Bool {
        entity.xdata.keys.contains { $0.hasPrefix("dxf.hatch") }
    }

    private static func classifyLoops(_ loops: [[Vector3]]) -> (outer: [Vector3], holes: [[Vector3]]) {
        guard let outerIndex = loops.indices.max(by: { abs(loopArea(loops[$0])) < abs(loopArea(loops[$1])) }) else {
            return ([], [])
        }
        let outer = normalizedLoop(loops[outerIndex])
        let holes = loops.indices.filter { $0 != outerIndex }.map { normalizedLoop(loops[$0]) }.filter { $0.count >= 3 }
        return (outer, holes)
    }

    private static func splitConnectedHatchBoundary(_ boundary: [Vector3]) -> (outer: [Vector3], holes: [[Vector3]]) {
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

    private static func normalizedLoop(_ loop: [Vector3]) -> [Vector3] {
        var points = removeConsecutiveDuplicates(loop)
        if points.count > 1, let first = points.first, let last = points.last, nearlyEqual(first, last) {
            points.removeLast()
        }
        return points
    }

    private static func removeConsecutiveDuplicates(_ loop: [Vector3]) -> [Vector3] {
        var result: [Vector3] = []
        for point in loop {
            if let last = result.last, nearlyEqual(last, point) { continue }
            result.append(point)
        }
        return result
    }

    private static func nearlyEqual(_ a: Vector3, _ b: Vector3) -> Bool {
        let dx = a.x - b.x
        let dy = a.y - b.y
        let dz = a.z - b.z
        return dx * dx + dy * dy + dz * dz < 1e-12
    }

    private static func loopArea(_ loop: [Vector3]) -> Double {
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

}