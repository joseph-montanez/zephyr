import ZephyrCore
import Foundation
import ImGui

@MainActor
struct ArrayRibbonUI {
    static func renderIfNeeded(engine: PhrostEngine, displayWidth: Float) {
        guard engine.commandProcessor.activeFeatureCommand == nil,
              engine.cadSelection.selectedCount == 1,
              let handle = engine.cadSelection.lastSelectedHandle,
              var entity = engine.document.entity(for: handle),
              var array = entity.arrayData
        else { return }

        renderOverlay(entity: entity, array: array, engine: engine)

        let width = min(displayWidth - 32, 1480)
        let y = AppLayout.topChromeHeight + AppLayout.tabBarHeight + 8
        ImGuiSetNextWindowPos(
            ImVec2(x: (displayWidth - width) * 0.5, y: y),
            Int32(ImGuiCond_Always.rawValue),
            ImVec2(x: 0, y: 0))
        ImGuiSetNextWindowSize(ImVec2(x: width, y: 0), Int32(ImGuiCond_Always.rawValue))
        ImGuiPushStyleVar(Int32(ImGuiStyleVar_WindowRounding.rawValue), 2.0)
        ImGuiPushStyleVar(Int32(ImGuiStyleVar_WindowPadding.rawValue), ImVec2(x: 10, y: 8))
        ImGuiPushStyleColor(Int32(ImGuiCol_WindowBg.rawValue), engine.ui.theme.panelBg)

        let flags = Int32(ImGuiWindowFlags_NoTitleBar.rawValue)
            | Int32(ImGuiWindowFlags_NoResize.rawValue)
            | Int32(ImGuiWindowFlags_NoMove.rawValue)
            | Int32(ImGuiWindowFlags_NoScrollbar.rawValue)
            | Int32(ImGuiWindowFlags_NoSavedSettings.rawValue)
            | Int32(ImGuiWindowFlags_AlwaysAutoResize.rawValue)

        var changed = false
        var entityStillExists = true
        if igBegin("##AssociativeArrayRibbon", nil, flags) {
            if let bold = engine.ui.boldFont { ImGuiPushFont(bold, 0) }
            ImGuiTextV(arrayTitle(array.kind))
            if engine.ui.boldFont != nil { ImGuiPopFont() }
            ImGuiSameLine(0, 12)
            divider()
            ImGuiSameLine(0, 12)

            switch array.kind {
            case .rectangular:
                changed = rectangularFields(array: &array)
            case .polar:
                changed = polarFields(array: &array)
            case .path:
                changed = pathFields(array: &array)
            }

            let actionSectionWidth: Float = 340
            if ImGuiGetContentRegionAvail().x < actionSectionWidth {
                let cursor = ImGuiGetCursorScreenPos()
                let window = igGetWindowPos()
                igSetCursorScreenPos(ImVec2(
                    x: window.x + 10,
                    y: cursor.y + ImGuiGetFrameHeight() + 6))
            } else {
                ImGuiSameLine(0, 12)
                divider()
                ImGuiSameLine(0, 12)
            }

            if ribbonButton("Edit Source") {
                if let blockID = entity.blockID {
                    engine.tabManager.enterBlockEditor(blockID: blockID)
                }
            }
            ImGuiSameLine(0, 4)
            if ribbonButton("Reset Items") {
                array.hiddenItems.removeAll()
                changed = true
            }
            ImGuiSameLine(0, 4)
            if ribbonButton("Explode") {
                let newHandles = engine.document.explodeAssociativeArray(handle: handle)
                entityStillExists = newHandles.isEmpty
                engine.cadSelection.clearSelection()
                for newHandle in newHandles { engine.cadSelection.addToSelection(newHandle) }
            }
            ImGuiSameLine(0, 4)
            if ribbonButton("Close Array") {
                engine.cadSelection.clearSelection()
            }
            ImGuiSameLine(0, 8)
            ImGuiDummy(ImVec2(x: 12, y: 1))
        }
        ImGuiEnd()
        ImGuiPopStyleColor(1)
        ImGuiPopStyleVar(2)

        if changed && entityStillExists {
            normalize(&array)
            entity.arrayData = array
            if let blockID = entity.blockID,
               let block = engine.document.block(for: blockID) {
                let path = CADArrayPathResolver.points(
                    for: array,
                    containerTransform: entity.transform,
                    document: engine.document)
                entity.updateArrayCache(
                    sourceBoundingBox: block.localBoundingBox,
                    pathPoints: path)
            }
            engine.document.updateEntity(entity)
        }
    }

    private static func rectangularFields(array: inout CADArrayData) -> Bool {
        var changed = false
        ImGuiTextV("Columns")
        ImGuiSameLine(0, 4)
        changed = inputInt("Columns", value: &array.columns, width: 58) || changed
        ImGuiSameLine(0, 5)
        ImGuiTextV("Between")
        ImGuiSameLine(0, 4)
        changed = inputDouble("ColumnSpacing", value: &array.columnSpacing, width: 82) || changed

        ImGuiSameLine(0, 10)
        divider()
        ImGuiSameLine(0, 10)
        ImGuiTextV("Rows")
        ImGuiSameLine(0, 4)
        changed = inputInt("Rows", value: &array.rows, width: 58) || changed
        ImGuiSameLine(0, 5)
        ImGuiTextV("Between")
        ImGuiSameLine(0, 4)
        changed = inputDouble("RowSpacing", value: &array.rowSpacing, width: 82) || changed

        ImGuiSameLine(0, 10)
        divider()
        ImGuiSameLine(0, 10)
        ImGuiTextV("Levels")
        ImGuiSameLine(0, 4)
        changed = inputInt("Levels", value: &array.levels, width: 58) || changed
        ImGuiSameLine(0, 5)
        ImGuiTextV("Between")
        ImGuiSameLine(0, 4)
        changed = inputDouble("LevelSpacing", value: &array.levelSpacing, width: 82) || changed

        ImGuiSameLine(0, 10)
        ImGuiTextV("Axis")
        ImGuiSameLine(0, 4)
        var degrees = array.axisAngle * 180 / .pi
        if inputDouble("AxisAngle", value: &degrees, width: 70, format: "%.2f°") {
            array.axisAngle = degrees * .pi / 180
            changed = true
        }
        return changed
    }

    private static func polarFields(array: inout CADArrayData) -> Bool {
        var changed = false
        ImGuiTextV("Items")
        ImGuiSameLine(0, 4)
        changed = inputInt("Items", value: &array.itemCount, width: 58) || changed
        ImGuiSameLine(0, 5)
        ImGuiTextV("Fill")
        ImGuiSameLine(0, 4)
        var degrees = array.fillAngle * 180 / .pi
        if inputDouble("FillAngle", value: &degrees, width: 82, format: "%.2f°") {
            array.fillAngle = degrees * .pi / 180
            changed = true
        }
        ImGuiSameLine(0, 5)
        changed = ImGuiCheckbox("Rotate Items", &array.rotateItems) || changed

        ImGuiSameLine(0, 10)
        divider()
        ImGuiSameLine(0, 10)
        ImGuiTextV("Rows")
        ImGuiSameLine(0, 4)
        changed = inputInt("PolarRows", value: &array.rows, width: 58) || changed
        ImGuiSameLine(0, 5)
        ImGuiTextV("Between")
        ImGuiSameLine(0, 4)
        changed = inputDouble("PolarRowSpacing", value: &array.rowSpacing, width: 82) || changed

        ImGuiSameLine(0, 10)
        divider()
        ImGuiSameLine(0, 10)
        ImGuiTextV("Levels")
        ImGuiSameLine(0, 4)
        changed = inputInt("PolarLevels", value: &array.levels, width: 58) || changed
        ImGuiSameLine(0, 5)
        ImGuiTextV("Between")
        ImGuiSameLine(0, 4)
        changed = inputDouble("PolarLevelSpacing", value: &array.levelSpacing, width: 82) || changed
        return changed
    }

    private static func pathFields(array: inout CADArrayData) -> Bool {
        var changed = false
        ImGuiTextV("Method")
        ImGuiSameLine(0, 4)
        ImGuiSetNextItemWidth(92)
        let label = array.pathMethod == .divide ? "Divide" : "Measure"
        if ImGuiBeginCombo("##PathArrayMethod", label, 0) {
            if ImGuiSelectable("Divide", array.pathMethod == .divide, 0, ImVec2(x: 0, y: 0)) {
                array.pathMethod = .divide
                changed = true
            }
            if ImGuiSelectable("Measure", array.pathMethod == .measure, 0, ImVec2(x: 0, y: 0)) {
                array.pathMethod = .measure
                changed = true
            }
            ImGuiEndCombo()
        }
        ImGuiSameLine(0, 6)
        if array.pathMethod == .divide {
            ImGuiTextV("Items")
            ImGuiSameLine(0, 4)
            changed = inputInt("PathItems", value: &array.itemCount, width: 58) || changed
        } else {
            ImGuiTextV("Between")
            ImGuiSameLine(0, 4)
            changed = inputDouble("PathSpacing", value: &array.itemSpacing, width: 82) || changed
        }
        ImGuiSameLine(0, 6)
        changed = ImGuiCheckbox("Align Items", &array.alignItems) || changed
        ImGuiSameLine(0, 6)
        changed = ImGuiCheckbox("Reverse", &array.reversePath) || changed

        ImGuiSameLine(0, 10)
        divider()
        ImGuiSameLine(0, 10)
        ImGuiTextV("Rows")
        ImGuiSameLine(0, 4)
        changed = inputInt("PathRows", value: &array.rows, width: 58) || changed
        ImGuiSameLine(0, 5)
        ImGuiTextV("Between")
        ImGuiSameLine(0, 4)
        changed = inputDouble("PathRowSpacing", value: &array.rowSpacing, width: 82) || changed

        ImGuiSameLine(0, 10)
        divider()
        ImGuiSameLine(0, 10)
        ImGuiTextV("Levels")
        ImGuiSameLine(0, 4)
        changed = inputInt("PathLevels", value: &array.levels, width: 58) || changed
        ImGuiSameLine(0, 5)
        ImGuiTextV("Between")
        ImGuiSameLine(0, 4)
        changed = inputDouble("PathLevelSpacing", value: &array.levelSpacing, width: 82) || changed
        return changed
    }

    private static func inputInt(_ id: String, value: inout Int, width: Float) -> Bool {
        var raw = Int32(clamping: value)
        ImGuiSetNextItemWidth(max(width, 72))
        let changed = ImGuiInputInt("##\(id)", &raw, 1, 10, 0)
        if changed { value = Int(raw) }
        return changed
    }

    private static func inputDouble(
        _ id: String,
        value: inout Double,
        width: Float,
        format: String = "%.4f"
    ) -> Bool {
        ImGuiSetNextItemWidth(width)
        return ImGuiInputDouble("##\(id)", &value, 0, 0, format, 0)
    }

    private static func normalize(_ array: inout CADArrayData) {
        array.columns = max(1, array.columns)
        array.rows = max(1, array.rows)
        array.levels = max(1, array.levels)
        if array.levels > 1 && abs(array.levelSpacing) < 1e-9 {
            array.levelSpacing = 1
        }
        array.itemCount = max(1, array.itemCount)
        array.itemSpacing = max(abs(array.itemSpacing), 1e-9)
    }

    private static func ribbonButton(_ label: String) -> Bool {
        ImGuiButton(label, ImVec2(x: 0, y: 0))
    }

    private static func divider() {
        let p = ImGuiGetCursorScreenPos()
        let h = ImGuiGetFrameHeight()
        ImDrawListAddLine(
            igGetWindowDrawList(),
            ImVec2(x: p.x, y: p.y),
            ImVec2(x: p.x, y: p.y + h),
            igGetColorU32_Vec4(ImVec4(x: 0.45, y: 0.45, z: 0.45, w: 0.7)),
            1)
        ImGuiDummy(ImVec2(x: 1, y: h))
    }

    private static func arrayTitle(_ kind: CADArrayKind) -> String {
        switch kind {
        case .rectangular: return "RECTANGULAR ARRAY"
        case .polar: return "POLAR ARRAY"
        case .path: return "PATH ARRAY"
        }
    }

    private static func renderOverlay(
        entity: CADEntity,
        array: CADArrayData,
        engine: PhrostEngine
    ) {
        guard let box = entity.worldBoundingBox else { return }
        let drawList = igGetForegroundDrawList_ViewportPtr(nil)
        let accent = igGetColorU32_Vec4(engine.ui.theme.brandGold)
        let corners = [
            screen(Vector3(x: box.min.x, y: box.min.y), engine: engine),
            screen(Vector3(x: box.max.x, y: box.min.y), engine: engine),
            screen(Vector3(x: box.max.x, y: box.max.y), engine: engine),
            screen(Vector3(x: box.min.x, y: box.max.y), engine: engine)
        ]
        ImDrawListAddQuad(drawList, corners[0], corners[1], corners[2], corners[3], accent, 1.5)

        if array.kind == .rectangular { return }

        let base = screen(entity.transform.transformPoint(.zero), engine: engine)
        ImDrawListAddRectFilled(
            drawList,
            ImVec2(x: base.x - 5, y: base.y - 5),
            ImVec2(x: base.x + 5, y: base.y + 5),
            accent,
            0,
            0)

        let instances = array.evaluatedInstances(pathPoints: array.cachedPath)
        if instances.count > 1 {
            for instance in [instances[1], instances[instances.count - 1]] {
                let world = entity.transform.multiplying(by: instance.transform).transformPoint(.zero)
                let p = screen(world, engine: engine)
                ImDrawListAddTriangleFilled(
                    drawList,
                    ImVec2(x: p.x, y: p.y - 6),
                    ImVec2(x: p.x + 6, y: p.y + 5),
                    ImVec2(x: p.x - 6, y: p.y + 5),
                    accent)
            }
        }
    }

    private static func screen(_ world: Vector3, engine: PhrostEngine) -> ImVec2 {
        let camera = engine.camera.currentTransform(
            windowWidth: engine.windowWidth,
            windowHeight: engine.windowHeight)
        let point = EngineCameraManager.worldToScreen(
            worldX: world.x,
            worldY: world.y,
            cam: camera)
        return ImVec2(x: point.x, y: point.y)
    }
}
