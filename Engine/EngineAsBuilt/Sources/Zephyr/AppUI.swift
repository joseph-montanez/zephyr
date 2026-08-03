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
    private static var _tabClosePendingID: UUID?
    private static var _tabClosePopupRequested = false
    private static var _windowClosePending = false

    static func requestTabCloseConfirmation(tabID: UUID) {
        _tabClosePendingID = tabID
        _tabClosePopupRequested = true
    }

    static func requestWindowClose(engine: PhrostEngine) -> Bool {
        guard engine.tabManager.tabs.contains(where: { $0.hasUnsavedChanges }) else {
            return true
        }
        _windowClosePending = true
        return false
    }

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
        let showsDrawingViewTabs = (engine.tabManager.activeTab?.drawingViews.count ?? 0) > 1
            && engine.tabManager.activeTab?.editingBlockID == nil
        let bottomOffset = AppLayout.statusBarHeight
            + (showsDrawingViewTabs ? AppLayout.drawingViewTabBarHeight : 0)
        let workH = dh - topOffset - bottomOffset
        engine.ui.beginDrawingViewportFrame(
            x: 0,
            y: topOffset,
            width: dw,
            height: workH)

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

        // 6c. Associative array contextual ribbon.
        ArrayRibbonUI.renderIfNeeded(engine: engine, displayWidth: dw)

        // 6d. Data table contextual ribbon and in-canvas cell editor.
        DataTableRibbonUI.renderIfNeeded(engine: engine, displayWidth: dw)

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

        if engine.ui.styleManagerActive {
            StyleManagerUI.render(engine: engine, dw: dw, dh: dh)
        }
        if engine.ui.leaderStyleManagerActive {
            LeaderStyleManagerUI.render(engine: engine, dw: dw, dh: dh)
        }

        // 9b. Text editor modal dialog (when creating/editing text).
        if engine.textManager.isEditorActive {
            let result = TextEditorUI.render(state: &engine.textManager.editorState, engine: engine, dw: dw, dh: dh)
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

        // 10. Drawing view tabs and status bar at the bottom.
        if showsDrawingViewTabs {
            DrawingViewTabBarUI.render(engine: engine, dw: dw, dh: dh)
        }
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

            let editingArraySource = engine.tabManager.editingArrayHandle != nil
            let closePopupTitle = editingArraySource
                ? "Close Array Source##BlockClose"
                : "Close Block Editor##BlockClose"
            ImGuiOpenPopup(closePopupTitle, Int32(ImGuiPopupFlags_None.rawValue))

            prepareAutoSizedModal(preferredWidth: 460, minimumHeight: 160, displayWidth: dw, engine: engine)

            var popupOpen = true
            if ImGuiBeginPopupModal(closePopupTitle, &popupOpen,
                                    Int32(ImGuiWindowFlags_NoSavedSettings.rawValue
                                        | ImGuiWindowFlags_AlwaysAutoResize.rawValue)) {
                defer { ImGuiEndPopup() }

                if !popupOpen {
                    engine.ui.blockClosePending = false
                } else {
                    if editingArraySource {
                        ImGuiTextWrappedV("Save changes to the array source before closing?")
                    } else {
                        ImGuiTextWrappedV("Save changes to block \"\(blockName)\" before closing?")
                    }

                    igSeparator()
                    let uiScale = max(0.75, engine.effectiveUiScale)
                    let buttonGap = 8.0 * uiScale
                    let buttonH = max(ImGuiGetFrameHeight(), 36.0 * uiScale)
                    ImGuiDummy(ImVec2(x: 0, y: 4.0 * uiScale))
                    let buttonW = max(72.0 * uiScale, (ImGuiGetContentRegionAvail().x - buttonGap * 2.0) / 3.0)

                    if igButton("Save", ImVec2(x: buttonW, y: buttonH)) {
                        engine.tabManager.exitBlockEditor(saveChanges: true)
                        engine.ui.blockClosePending = false
                        ImGuiCloseCurrentPopup()
                    }
                    ImGuiSameLine(0, buttonGap)
                    if igButton("Discard", ImVec2(x: buttonW, y: buttonH)) {
                        engine.tabManager.exitBlockEditor(saveChanges: false)
                        engine.ui.blockClosePending = false
                        ImGuiCloseCurrentPopup()
                    }
                    ImGuiSameLine(0, buttonGap)
                    if igButton("Cancel", ImVec2(x: buttonW, y: buttonH)) {
                        engine.ui.blockClosePending = false
                        ImGuiCloseCurrentPopup()
                    }
                }
            }
        }

        renderTabCloseConfirmation(engine: engine, dw: dw)
        renderWindowCloseConfirmation(engine: engine, dw: dw)

        // 12. Radial Navigation Tool (Artrage style)
        if engine.ui.radialNavVisible {
            RadialNavUI.render(engine: engine, dw: dw, dh: dh)
        }
    }


    private static func prepareAutoSizedModal(
        preferredWidth: Float,
        minimumHeight: Float,
        displayWidth: Float,
        engine: PhrostEngine
    ) {
        let io = ImGuiGetIO()!.pointee
        let uiScale = max(0.75, engine.effectiveUiScale)
        let availableW = max(180.0, displayWidth - 32.0 * uiScale)
        let modalW = min(preferredWidth * uiScale, availableW)
        let maxH = max(120.0, io.DisplaySize.y - 48.0 * uiScale)
        let minH = min(maxH, minimumHeight * uiScale)

        ImGuiSetNextWindowPos(
            ImVec2(x: displayWidth * 0.5, y: io.DisplaySize.y * 0.5),
            Int32(ImGuiCond_Appearing.rawValue),
            ImVec2(x: 0.5, y: 0.5))
        ImGuiSetNextWindowSize(
            ImVec2(x: modalW, y: minH),
            Int32(ImGuiCond_Appearing.rawValue))
        ImGuiSetNextWindowSizeConstraints(
            ImVec2(x: modalW, y: minH),
            ImVec2(x: modalW, y: maxH),
            { _ in },
            nil)
    }

    private static func renderTabCloseConfirmation(engine: PhrostEngine, dw: Float) {
        if _tabClosePopupRequested {
            _tabClosePopupRequested = false
            ImGuiOpenPopup("Discard Changes##RequestedTabClose", Int32(ImGuiPopupFlags_None.rawValue))
        }

        prepareAutoSizedModal(preferredWidth: 460, minimumHeight: 160, displayWidth: dw, engine: engine)

        var popupOpen = true
        if ImGuiBeginPopupModal("Discard Changes##RequestedTabClose", &popupOpen,
                                Int32(ImGuiWindowFlags_NoSavedSettings.rawValue
                                    | ImGuiWindowFlags_AlwaysAutoResize.rawValue)) {
            defer { ImGuiEndPopup() }

            if !popupOpen {
                _tabClosePendingID = nil
                return
            }

            guard let tabID = _tabClosePendingID,
                  let index = engine.tabManager.indexOfTab(id: tabID) else {
                _tabClosePendingID = nil
                ImGuiCloseCurrentPopup()
                return
            }

            let tabName = engine.tabManager.tabs[index].displayName
            ImGuiTextWrappedV("Discard unsaved changes to \"\(tabName)\"?")
            igSeparator()
            let uiScale = max(0.75, engine.effectiveUiScale)
            let buttonGap = 8.0 * uiScale
            let buttonH = max(ImGuiGetFrameHeight(), 36.0 * uiScale)
            ImGuiDummy(ImVec2(x: 0, y: 4.0 * uiScale))
            let buttonW = max(120.0 * uiScale, (ImGuiGetContentRegionAvail().x - buttonGap) / 2.0)

            if igButton("Discard Changes", ImVec2(x: buttonW, y: buttonH)) {
                _ = engine.tabManager.closeTab(at: index)
                _tabClosePendingID = nil
                ImGuiCloseCurrentPopup()
            }
            ImGuiSameLine(0, buttonGap)
            if igButton("Cancel", ImVec2(x: buttonW, y: buttonH)) {
                _tabClosePendingID = nil
                ImGuiCloseCurrentPopup()
            }
        }
    }

    private static func renderWindowCloseConfirmation(engine: PhrostEngine, dw: Float) {
        guard _windowClosePending else { return }

        let dirtyTabs = engine.tabManager.tabs.filter { $0.hasUnsavedChanges }
        if dirtyTabs.isEmpty {
            _windowClosePending = false
            engine.stop()
            return
        }

        ImGuiOpenPopup("Unsaved Changes##WindowClose", Int32(ImGuiPopupFlags_None.rawValue))

        prepareAutoSizedModal(preferredWidth: 560, minimumHeight: 180, displayWidth: dw, engine: engine)

        var popupOpen = true
        if ImGuiBeginPopupModal("Unsaved Changes##WindowClose", &popupOpen,
                                Int32(ImGuiWindowFlags_NoSavedSettings.rawValue
                                    | ImGuiWindowFlags_AlwaysAutoResize.rawValue)) {
            defer { ImGuiEndPopup() }

            if !popupOpen {
                _windowClosePending = false
                return
            }

            let names = dirtyTabs.prefix(4).map(\.displayName).joined(separator: ", ")
            let remaining = max(0, dirtyTabs.count - 4)
            ImGuiTextWrappedV("Unsaved changes will be lost in:")
            ImGuiTextWrappedV(remaining > 0 ? "\(names), and \(remaining) more" : names)
            igSeparator()
            let uiScale = max(0.75, engine.effectiveUiScale)
            let buttonGap = 8.0 * uiScale
            let buttonH = max(ImGuiGetFrameHeight(), 36.0 * uiScale)
            ImGuiDummy(ImVec2(x: 0, y: 4.0 * uiScale))

            let available = ImGuiGetContentRegionAvail().x
            let discardMinW = ImGuiCalcTextSize("Discard Changes & Exit", nil, false, -1).x + 28.0 * uiScale
            let cancelMinW = ImGuiCalcTextSize("Cancel", nil, false, -1).x + 28.0 * uiScale
            let buttonsFitOneRow = discardMinW + cancelMinW + buttonGap <= available
            let discardW = buttonsFitOneRow
                ? max(discardMinW, (available - buttonGap) * 0.64)
                : available
            let cancelW = buttonsFitOneRow ? available - buttonGap - discardW : available

            if igButton("Discard Changes & Exit", ImVec2(x: discardW, y: buttonH)) {
                _windowClosePending = false
                ImGuiCloseCurrentPopup()
                engine.stop()
            }
            if buttonsFitOneRow {
                ImGuiSameLine(0, buttonGap)
            } else {
                ImGuiDummy(ImVec2(x: 0, y: buttonGap))
            }
            if igButton("Cancel", ImVec2(x: cancelW, y: buttonH)) {
                _windowClosePending = false
                ImGuiCloseCurrentPopup()
            }
        }
    }

    // MARK: - Hatch editing ribbon

    private struct HatchEditRegion {
        var outer: [Vector3]
        var holes: [[Vector3]]
        var outerPath: CADPolyline?
        var holePaths: [CADPolyline]
    }

    private struct HatchEditPayload {
        var fillType: Int32
        var patternName: String
        var gradientName: String
        var scale: Double
        var angle: Double
        var primaryColor: ColorRGBA?
        var backgroundColor: ColorRGBA?
        var secondaryColor: ColorRGBA?
        var regions: [HatchEditRegion]
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

        let geometryFillType = hatchGeometryFillType(entity)
        let needsGeometryRepair = geometryFillType != nil && geometryFillType != payload.fillType
        guard settings.closeRequested || settings != oldSettings || needsGeometryRepair else { return }

        let newPatternKey = hatchPatternKey(from: settings)
        let newDXFPatternName = settings.fillType == 0
            ? DXFHatchGenerator.patternExportName(for: newPatternKey)
            : newPatternKey
        let newGeometry = buildHatchGeometry(
            regions: payload.regions,
            settings: settings,
            patternName: newPatternKey)

        var newEntity = entity
        let originalPattern = patternNameFromXData(entity)
        newEntity.xdata["zephyr.hatchPatternKey"] = .string(newPatternKey)
        newEntity.xdata["dxf.hatchPatternName"] = .string(newDXFPatternName)
        newEntity.xdata["dxf.hatchPatternType"] = .string(DXFHatchGenerator.patternKindName(for: newPatternKey))
        newEntity.xdata["dxf.hatchScale"] = .double(Double(settings.scale))
        newEntity.xdata["dxf.hatchAngle"] = .double(Double(settings.angle))
        newEntity.xdata["dxf.hatchSpacing"] = .double(DXFHatchGenerator.effectiveSpacing(patternName: newPatternKey, scale: Double(settings.scale)))
        newEntity.xdata["dxf.hatchIsGradient"] = .bool(settings.fillType == 2)
        let definitionType = settings.fillType == 3
            ? 0
            : DXFHatchGenerator.patternDefinitionType(for: newPatternKey)
        newEntity.xdata["dxf.hatchPatternDefinitionType"] = .int(definitionType)
        if originalPattern?.uppercased() != newDXFPatternName.uppercased() || settings.fillType != 0 {
            newEntity.xdata.removeValue(forKey: "dxf.hatchPatternLines")
        }
        if settings.fillType == 2 {
            let c1 = settings.primaryColor ?? ColorRGBA(r: 255, g: 255, b: 255, a: 255)
            let c2 = settings.secondaryColor ?? c1
            newEntity.xdata["dxf.hatchGradientName"] = .string(settings.gradientName)
            newEntity.xdata["dxf.hatchGradientAngle"] = .double(Double(settings.angle))
            newEntity.xdata["dxf.hatchGradientSingleColor"] = .bool(false)
            newEntity.xdata["dxf.hatchGradientTint"] = .double(0.0)
            newEntity.xdata["dxf.hatchGradientStops"] = .string(gradientStopsJSON(c1, c2))
        } else {
            newEntity.xdata.removeValue(forKey: "dxf.hatchGradientName")
            newEntity.xdata.removeValue(forKey: "dxf.hatchGradientAngle")
            newEntity.xdata.removeValue(forKey: "dxf.hatchGradientShift")
            newEntity.xdata.removeValue(forKey: "dxf.hatchGradientTint")
            newEntity.xdata.removeValue(forKey: "dxf.hatchGradientSingleColor")
            newEntity.xdata.removeValue(forKey: "dxf.hatchGradientStops")
        }
        newEntity.localGeometry = newGeometry

        if settings.closeRequested {
            engine.document.updateEntity(newEntity)
            engine.cadSelection.clearSelection()
        } else {
            engine.document.updateEntityLive(newEntity)
            engine.tabManager.markActiveDirty()
        }
    }

    private static func gradientStopsJSON(_ first: ColorRGBA, _ second: ColorRGBA) -> String {
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

    private static func hatchEditPayload(from entity: CADEntity) -> HatchEditPayload? {
        guard let geometry = entity.localGeometry else { return nil }

        let carrierPaths = geometry.compactMap { primitive -> CADPolyline? in
            guard case .polyline(let path, let color) = primitive,
                  path.isHatchBoundaryCarrier,
                  color?.a == 0 else { return nil }
            return path
        }
        let carrierRegions = classifyBoundaryPaths(carrierPaths)

        let gradients = geometry.compactMap { primitive -> (outer: [Vector3], holes: [[Vector3]], name: String, angle: Double, c1: ColorRGBA, c2: ColorRGBA)? in
            guard case .gradient(let outer, let holes, let name, let angle, let c1, let c2) = primitive else { return nil }
            return (outer, holes, name, angle, c1, c2)
        }
        if let first = gradients.first {
            let regions = !carrierRegions.isEmpty
                ? carrierRegions
                : gradients.map {
                    HatchEditRegion(
                        outer: normalizedLoop($0.outer),
                        holes: $0.holes.map { normalizedLoop($0) }.filter { $0.count >= 3 },
                        outerPath: nil,
                        holePaths: [])
                }
            guard !regions.isEmpty else { return nil }
            return HatchEditPayload(
                fillType: 2,
                patternName: editablePatternNameFromXData(entity) ?? "ANSI31",
                gradientName: first.name,
                scale: 1.0,
                angle: first.angle,
                primaryColor: first.c1,
                backgroundColor: nil,
                secondaryColor: first.c2,
                regions: regions)
        }

        let hatchPaths = geometry.compactMap { primitive -> (region: HatchEditRegion, pattern: String, scale: Double, angle: Double, color: ColorRGBA?, background: ColorRGBA?)? in
            guard case .hatchPath(let boundary, let holes, let pattern, let scale, let angle, let color, let background) = primitive else { return nil }
            return (
                HatchEditRegion(
                    outer: normalizedLoop(boundary.tessellatedPoints()),
                    holes: holes.map { normalizedLoop($0.tessellatedPoints()) }.filter { $0.count >= 3 },
                    outerPath: boundary,
                    holePaths: holes),
                pattern, scale, angle, color, background)
        }

        let legacyHatches = geometry.compactMap { primitive -> (region: HatchEditRegion, pattern: String, scale: Double, angle: Double, color: ColorRGBA?, background: ColorRGBA?)? in
            guard case .hatch(let boundary, let pattern, let scale, let angle, let color, let background) = primitive else { return nil }
            let loops = splitConnectedHatchBoundary(boundary)
            guard loops.outer.count >= 3 else { return nil }
            return (
                HatchEditRegion(outer: loops.outer, holes: loops.holes, outerPath: nil, holePaths: []),
                pattern, scale, angle, color, background)
        }

        let allHatches = hatchPaths + legacyHatches
        if let first = allHatches.first {
            let rawPattern = first.pattern.isEmpty
                ? (editablePatternNameFromXData(entity) ?? "SOLID")
                : first.pattern
            let exportedPattern = DXFHatchGenerator.patternExportName(for: rawPattern)
            let fillType: Int32 = exportedPattern == "USER" ? 3 : (exportedPattern == "SOLID" ? 1 : 0)
            return HatchEditPayload(
                fillType: fillType,
                patternName: exportedPattern == "SOLID" || exportedPattern == "GRADIENT" || exportedPattern == "USER" ? "ANSI31" : rawPattern,
                gradientName: "LINEAR",
                scale: first.scale,
                angle: first.angle,
                primaryColor: first.color,
                backgroundColor: first.background,
                secondaryColor: nil,
                regions: allHatches.map { $0.region })
        }

        let complexPolygons = geometry.compactMap { primitive -> (outer: [Vector3], holes: [[Vector3]], color: ColorRGBA?)? in
            guard case .fillComplexPolygon(let outer, let holes, let color) = primitive else { return nil }
            return (outer, holes, color)
        }
        if !complexPolygons.isEmpty || isHatchEntityByXData(entity) {
            let regions: [HatchEditRegion]
            if !carrierRegions.isEmpty {
                regions = carrierRegions
            } else {
                regions = complexPolygons.map {
                    HatchEditRegion(
                        outer: normalizedLoop($0.outer),
                        holes: $0.holes.map { normalizedLoop($0) }.filter { $0.count >= 3 },
                        outerPath: nil,
                        holePaths: [])
                }
            }
            guard !regions.isEmpty else { return nil }
            let storedFillType = hatchFillTypeFromXData(entity) ?? 1
            return HatchEditPayload(
                fillType: storedFillType,
                patternName: editablePatternNameFromXData(entity) ?? "ANSI31",
                gradientName: hatchGradientNameFromXData(entity) ?? "LINEAR",
                scale: hatchDoubleFromXData(entity, key: "dxf.hatchScale") ?? 1.0,
                angle: hatchDoubleFromXData(entity, key: "dxf.hatchAngle") ?? 0.0,
                primaryColor: complexPolygons.first?.color,
                backgroundColor: nil,
                secondaryColor: nil,
                regions: regions)
        }

        return nil
    }

    private static func buildHatchGeometry(
        regions: [HatchEditRegion],
        settings: HatchRibbonUI.Settings,
        patternName: String
    ) -> [CADPrimitive] {
        let scale = Double(settings.scale)
        let angle = Double(settings.angle)
        var primitives: [CADPrimitive] = []

        for region in regions {
            let cleanOuter = normalizedLoop(region.outer)
            let cleanHoles = region.holes.map { normalizedLoop($0) }.filter { $0.count >= 3 }
            guard cleanOuter.count >= 3 else { continue }

            switch settings.fillType {
            case 2:
                let c1 = settings.primaryColor ?? ColorRGBA(r: 255, g: 255, b: 255, a: 255)
                let c2 = settings.secondaryColor ?? c1
                primitives.append(.gradient(
                    outer: cleanOuter,
                    holes: cleanHoles,
                    gradientName: settings.gradientName,
                    angle: angle,
                    color1: c1,
                    color2: c2))

            case 1:
                primitives.append(.fillComplexPolygon(
                    outer: cleanOuter,
                    holes: cleanHoles,
                    color: settings.primaryColor))

            default:
                if settings.fillType == 0, let background = settings.backgroundColor {
                    primitives.append(.fillComplexPolygon(
                        outer: cleanOuter,
                        holes: cleanHoles,
                        color: background))
                }
                if let outerPath = region.outerPath {
                    primitives.append(.hatchPath(
                        boundary: outerPath,
                        holes: region.holePaths,
                        pattern: patternName,
                        scale: scale,
                        angle: angle,
                        color: settings.primaryColor,
                        backgroundColor: nil))
                } else {
                    let patternBoundary = cleanHoles.isEmpty
                        ? cleanOuter
                        : DXFHatchGenerator.connectHoles(outer: cleanOuter, holes: cleanHoles)
                    primitives.append(.hatch(
                        boundary: patternBoundary,
                        pattern: patternName,
                        scale: scale,
                        angle: angle,
                        color: settings.primaryColor,
                        backgroundColor: nil))
                }
            }
        }

        if settings.fillType == 1 || settings.fillType == 2 {
            for region in regions {
                if var outerPath = region.outerPath {
                    outerPath.isHatchBoundaryCarrier = true
                    primitives.append(.polyline(path: outerPath, color: .transparent))
                }
                for sourceHole in region.holePaths {
                    var holePath = sourceHole
                    holePath.isHatchBoundaryCarrier = true
                    primitives.append(.polyline(path: holePath, color: .transparent))
                }
            }
        }
        return primitives
    }

    private static func classifyBoundaryPaths(_ paths: [CADPolyline]) -> [HatchEditRegion] {
        let candidates = paths.compactMap { path -> (path: CADPolyline, points: [Vector3], area: Double)? in
            let points = normalizedLoop(path.tessellatedPoints())
            guard points.count >= 3 else { return nil }
            return (path, points, abs(loopArea(points)))
        }
        guard !candidates.isEmpty else { return [] }

        var parent = Array<Int?>(repeating: nil, count: candidates.count)
        for child in candidates.indices {
            let probe = loopProbe(candidates[child].points)
            var best: Int?
            var bestArea = Double.infinity
            for possibleParent in candidates.indices where possibleParent != child {
                guard candidates[possibleParent].area > candidates[child].area + 1e-9 else { continue }
                let parentPoints = candidates[possibleParent].points
                guard pointInLoop(probe, parentPoints)
                    || candidates[child].points.contains(where: { pointInLoop($0, parentPoints) }) else { continue }
                if candidates[possibleParent].area < bestArea {
                    best = possibleParent
                    bestArea = candidates[possibleParent].area
                }
            }
            parent[child] = best
        }

        func depth(_ index: Int) -> Int {
            var count = 0
            var cursor = parent[index]
            var visited = Set<Int>()
            while let current = cursor, visited.insert(current).inserted {
                count += 1
                cursor = parent[current]
            }
            return count
        }

        let depths = candidates.indices.map(depth)
        var children = Array(repeating: [Int](), count: candidates.count)
        for index in candidates.indices {
            if let p = parent[index] { children[p].append(index) }
        }

        return candidates.indices
            .filter { depths[$0] % 2 == 0 }
            .sorted { candidates[$0].area > candidates[$1].area }
            .map { outerIndex in
                let holeIndices = children[outerIndex]
                    .filter { depths[$0] == depths[outerIndex] + 1 }
                    .sorted { candidates[$0].area > candidates[$1].area }
                return HatchEditRegion(
                    outer: candidates[outerIndex].points,
                    holes: holeIndices.map { candidates[$0].points },
                    outerPath: candidates[outerIndex].path,
                    holePaths: holeIndices.map { candidates[$0].path })
            }
    }

    private static func loopProbe(_ points: [Vector3]) -> Vector3 {
        guard let first = points.first else { return .zero }
        let center = points.reduce(Vector3.zero, +) / Double(points.count)
        if pointInLoop(center, points) { return center }
        guard points.count > 1 else { return first }
        return Vector3(
            x: first.x + (points[1].x - first.x) * 1e-6,
            y: first.y + (points[1].y - first.y) * 1e-6,
            z: first.z)
    }

    private static func pointInLoop(_ point: Vector3, _ polygon: [Vector3]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i]
            let b = polygon[j]
            if ((a.y > point.y) != (b.y > point.y))
                && point.x < (b.x - a.x) * (point.y - a.y) / ((b.y - a.y) == 0 ? 1e-20 : (b.y - a.y)) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }


    private static func hatchGeometryFillType(_ entity: CADEntity) -> Int32? {
        guard let geometry = entity.localGeometry else { return nil }
        if geometry.contains(where: {
            if case .gradient = $0 { return true }
            return false
        }) { return 2 }
        if geometry.contains(where: {
            switch $0 {
            case .hatch, .hatchPath: return true
            default: return false
            }
        }) {
            let pattern = patternNameFromXData(entity) ?? "ANSI31"
            return pattern == "USER" ? 3 : 0
        }
        if geometry.contains(where: {
            if case .fillComplexPolygon = $0 { return true }
            return false
        }) { return 1 }
        return nil
    }

    private static func hatchFillTypeFromXData(_ entity: CADEntity) -> Int32? {
        if case .bool(true)? = entity.xdata["dxf.hatchIsGradient"] { return 2 }
        guard let pattern = patternNameFromXData(entity) else { return nil }
        switch pattern {
        case "GRADIENT": return 2
        case "SOLID": return 1
        case "USER": return 3
        default: return 0
        }
    }

    private static func hatchGradientNameFromXData(_ entity: CADEntity) -> String? {
        guard case .string(let value)? = entity.xdata["dxf.hatchGradientName"] else { return nil }
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return name.isEmpty ? nil : name
    }

    private static func hatchDoubleFromXData(_ entity: CADEntity, key: String) -> Double? {
        switch entity.xdata[key] {
        case .double(let value)?: return value
        case .int(let value)?: return Double(value)
        default: return nil
        }
    }

    private static func hatchPatternKey(from settings: HatchRibbonUI.Settings) -> String {
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
        if case .string(let value)? = entity.xdata["zephyr.hatchPatternKey"] {
            let key = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if !key.isEmpty, key != "SOLID", key != "GRADIENT", key != "USER" {
                return key
            }
        }
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