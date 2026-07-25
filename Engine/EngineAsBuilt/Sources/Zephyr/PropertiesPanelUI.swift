import ZephyrCore
import Foundation
import ImGui

// MARK: - PropertiesPanelUI
//
// Renders the floating Properties inspector panel for the currently selected
// entity. Displays comprehensive information organized in collapsible sections:
//
// Sections:
//   1. General — Handle (UUID), assigned layer, parent block with Edit button
//   2. Layer Properties — Color, line weight, line type, visibility
//   3. Entity Overrides — Per-entity XData that overrides layer defaults
//      (line type, line weight, color, draw order, etc.)
//   4. Transform — Position, rotation (degrees), scale
//   5. Bounding Box — World-space min/max and size
//   6. Geometry — Resolved primitives (delegates to GeometryPanelUI)
//   7. XData — Any remaining custom extended data key-value pairs
//
// The panel auto-closes when the selection becomes invalid (entity deleted
// or deselected).

@MainActor
struct PropertiesPanelUI {
    /// Track docking state of this window.
    static var _isDocked: Bool = false
    /// Tracks previous frame's showPropertiesPanel flag to detect re-open.
    static var _wasVisible: Bool = false
    /// Renders the properties panel if the engine's showPropertiesPanel flag is set.
    /// Auto-closes when the selected entity is no longer valid.
    /// - Parameter engine: The engine instance.
    static func render(engine: PhrostEngine) {
        guard engine.ui.showPropertiesPanel else {
            _wasVisible = false
            return
        }

        let doc = engine.document
        // Validate the selection — if the entity no longer exists, dismiss the panel.
        guard let handle = engine.cadSelection.lastSelectedHandle,
              let entity = doc.entity(for: handle)
        else {
            _wasVisible = false
            engine.ui.showPropertiesPanel = false
            return
        }

        let selectedHandles = engine.cadSelection.selectedHandles
        let isMultiSelect = selectedHandles.count > 1

        let layer = doc.layer(for: entity.layerID)
        let block = entity.blockID.flatMap { doc.block(for: $0) }
        // Resolve entity to renderable primitives (decomposes complex entities).
        let geometry = doc.resolvedGeometry(for: entity) ?? []

        ImGuiSetNextWindowSize(
            ImVec2(x: ImGuiGetFontSize() * 24, y: ImGuiGetFontSize() * 36),
            Int32(ImGuiCond_Appearing.rawValue))
        // Also position the panel at a visible default location when it first appears,
        // so it isn't placed at (0,0) or behind the dockspace.
        ImGuiSetNextWindowPos(
            ImVec2(x: ImGuiGetFontSize() * 4, y: AppLayout.topChromeHeight + AppLayout.tabBarHeight + ImGuiGetFontSize() * 2),
            Int32(ImGuiCond_Appearing.rawValue),
            ImVec2(x: 0, y: 0))

        // When the panel is re-opened after being closed, reset docking state
        // so it doesn't get stuck in an invisible docked tab.
        if !_wasVisible {
            _isDocked = false
        }
        _wasVisible = true

        let isDocked = _isDocked
        var flags = Int32(ImGuiWindowFlags_NoSavedSettings.rawValue)
        if isDocked {
            flags |= Int32(ImGuiWindowFlags_NoTitleBar.rawValue)
        }

        var opened = true
        let entered: Bool
        if isDocked {
            ImGuiPushStyleColor(Int32(ImGuiCol_WindowBg.rawValue), engine.ui.theme.panelBg)
            ImGuiPushStyleVar(Int32(ImGuiStyleVar_WindowBorderSize.rawValue), 0.0)
            entered = igBegin("Properties##PropsPanel", nil, flags)
        } else {
            ImGuiPushStyleColor(Int32(ImGuiCol_WindowBg.rawValue), engine.ui.theme.panelBgDim)
            ImGuiPushStyleVar(Int32(ImGuiStyleVar_WindowBorderSize.rawValue), 1.0)
            entered = igBegin("Properties##PropsPanel", &opened, flags)
        }
        _isDocked = ImGuiIsWindowDocked()
        AppLayout.reportCurrentDockedPanel(engine: engine)

        guard entered else {
            print("[PropsPanel] igBegin returned false, isDocked=\(isDocked), ImGuiIsWindowDocked=\(ImGuiIsWindowDocked())")
            ImGuiEnd()
            ImGuiPopStyleVar(1)
            ImGuiPopStyleColor(1)
            return
        }
        print("[PropsPanel] igBegin returned true, isDocked=\(ImGuiIsWindowDocked()), handle=\(entity.handle)")
        defer {
            ImGuiEnd()
            ImGuiPopStyleVar(1)
            ImGuiPopStyleColor(1)
        }

        if !isDocked && !opened {
            engine.ui.showPropertiesPanel = false
            return
        }

        // Selection count indicator (multi-select only)
        if isMultiSelect {
            ImGuiTextV("\(selectedHandles.count) entities selected — changes apply to all")
            igSeparator()
        }

        // Section 1: General — handle, layer, block
        if ImGuiCollapsingHeader("General", Int32(ImGuiTreeNodeFlags_DefaultOpen.rawValue)) {
            let uuidStr = entity.handle.uuidString
            let shortUUID = String(uuidStr.prefix(12)) + "..."
            ImGuiTextV("Handle: \(shortUUID)")

            let layerName = layer?.name ?? "?"
            if let ly = layer {
                let hexColor = String(
                    format: "#%02X%02X%02X", ly.color.r, ly.color.g, ly.color.b)
                ImGuiTextV("Layer: \(layerName)  [\(hexColor)]")
            } else {
                ImGuiTextV("Layer: \(layerName)")
            }

            let blockName = block?.name ?? "\u{2014}"
            ImGuiTextV("Block: \(blockName)")
            if let blockID = block?.handle {
                ImGuiSameLine(0, 8)
                if igSmallButton("Edit Block") {
                    engine.tabManager.enterBlockEditor(blockID: blockID)
                    engine.cadSelection.clearSelection()
                }
            }
            if entity.xdata["dxf.text"] != nil
                || entity.leaderData?.value.contentType == .mtext {
                ImGuiSameLine(0, 8)
                if igSmallButton("Edit Text") {
                    if entity.leaderData != nil {
                        engine.cadSelection.selectLeaderContent(entity.handle)
                    }
                    engine.commandProcessor.executeCommand("DDEDIT")
                }
            }
            igSeparator()
        }

        // Section 2: Layer Properties (if the entity has a layer assignment)
        if let ly = layer {
            if ImGuiCollapsingHeader("Layer Properties", Int32(ImGuiTreeNodeFlags_None.rawValue)) {
                let hexColor = String(
                    format: "#%02X%02X%02X", ly.color.r, ly.color.g, ly.color.b)
                ImGuiTextV("Color: \(hexColor)")
                ImGuiTextV("Opacity: \(String(format: "%.0f", ly.opacity * 100))%%")
                ImGuiTextV("LineWeight: \(String(format: "%.3f", ly.lineWeight)) mm")
                ImGuiTextV("LineType: \(ly.lineType)")
                ImGuiTextV("Visible: \(ly.isVisible ? "Yes" : "No")")
                igSeparator()
            }
        }

        // Section 3: Entity Overrides — editable controls with BYLAYER toggle
        if ImGuiCollapsingHeader("Entity Overrides", Int32(ImGuiTreeNodeFlags_DefaultOpen.rawValue)) {
            let layerColor = layer?.color ?? .white
            let layerLW = layer?.lineWeight ?? 0.25
            let layerLT = layer?.lineType ?? "CONTINUOUS"

            // --- Layer reassignment ---
            let currentLayerName = layer?.name ?? "?"
            if isMultiSelect {
                ImGuiTextV("Layer: \(currentLayerName) (\(selectedHandles.count) entities)")
            }
            if ImGuiBeginCombo("##EntityLayer", currentLayerName, 0) {
                let allLayers = engine.document.allLayers.sorted { $0.name < $1.name }
                for ly in allLayers {
                    let selected = ly.handle == entity.layerID
                    if ImGuiSelectable(ly.name, selected, 0, ImVec2(x: 0, y: 0)) {
                        engine.document.reassignEntities(handles: selectedHandles, to: ly.handle)
                    }
                    if selected {
                        ImGuiSetItemDefaultFocus()
                    }
                }
                ImGuiEndCombo()
            }
            igSeparator()

            // --- Color override ---
            let hasColorOverride = entity.xdata["dxf.color"] != nil
            var useColorOverride = hasColorOverride
            if ImGuiCheckbox("Use color override", &useColorOverride) {
                if useColorOverride {
                    // Enable: write current layer color as default to ALL selected entities
                    let hex = String(format: "#%02X%02X%02X", layerColor.r, layerColor.g, layerColor.b)
                    engine.document.setXDataForAll(handles: selectedHandles, key: "dxf.color", value: .string(hex))
                } else {
                    engine.document.removeXDataForAll(handles: selectedHandles, key: "dxf.color")
                }
            }
            if useColorOverride {
                let currentHex: String
                if let cv = entity.xdata["dxf.color"], case .string(let s) = cv { currentHex = s }
                else { currentHex = String(format: "#%02X%02X%02X", layerColor.r, layerColor.g, layerColor.b) }
                var col = Self.hexToFloatArray(currentHex)
                if igColorEdit3("##EntityColor", &col, 0) {
                    let hex = String(format: "#%02X%02X%02X",
                        Int(max(0, min(255, col[0] * 255))),
                        Int(max(0, min(255, col[1] * 255))),
                        Int(max(0, min(255, col[2] * 255))))
                    engine.document.setXDataForAll(handles: selectedHandles, key: "dxf.color", value: .string(hex))
                }
            }

            // --- Line weight override ---
            let hasLWOverride = entity.xdata["dxf.lineWeight"] != nil
            var useLWOverride = hasLWOverride
            if ImGuiCheckbox("Use line weight override", &useLWOverride) {
                if useLWOverride {
                    engine.document.setXDataForAll(handles: selectedHandles, key: "dxf.lineWeight", value: .double(layerLW))
                } else {
                    engine.document.removeXDataForAll(handles: selectedHandles, key: "dxf.lineWeight")
                }
            }
            if useLWOverride {
                let currentLW = entity.xdata["dxf.lineWeight"].flatMap { v -> Double? in
                    if case .double(let d) = v { return d }
                    return nil
                } ?? layerLW
                var lw = Float(currentLW)
                ImGuiPushItemWidth(ImGuiGetFontSize() * 6)
                if ImGuiInputFloat("##EntityLW", &lw, 0.05, 0.25, "%.3f mm", 0) {
                    engine.document.setXDataForAll(handles: selectedHandles, key: "dxf.lineWeight", value: .double(Double(max(0, lw))))
                }
                ImGuiPopItemWidth()
            }

            // --- Line type override ---
            let hasLTOverride = entity.xdata["dxf.lineType"] != nil
            var useLTOverride = hasLTOverride
            if ImGuiCheckbox("Use line type override", &useLTOverride) {
                if useLTOverride {
                    engine.document.setXDataForAll(handles: selectedHandles, key: "dxf.lineType", value: .string(layerLT))
                } else {
                    engine.document.removeXDataForAll(handles: selectedHandles, key: "dxf.lineType")
                }
            }
            if useLTOverride {
                let currentLT = entity.xdata["dxf.lineType"].flatMap { v -> String? in
                    if case .string(let s) = v { return s }
                    return nil
                } ?? layerLT
                let lineTypes: [String] = ["CONTINUOUS", "DASHED", "HIDDEN", "DASHDOT", "DOT", "CENTER", "PHANTOM"]
                if ImGuiBeginCombo("##EntityLT", currentLT, 0) {
                    for lt in lineTypes {
                        let selected = (lt == currentLT)
                        if ImGuiSelectable(lt, selected, 0, ImVec2(x: 0, y: 0)) {
                            engine.document.setXDataForAll(handles: selectedHandles, key: "dxf.lineType", value: .string(lt))
                        }
                        if selected {
                            ImGuiSetItemDefaultFocus()
                        }
                    }
                    ImGuiEndCombo()
                }
            }

            // --- Draw order ---
            var isDefaultOrder = entity.drawOrder == Int.max
            if ImGuiCheckbox("Default draw order", &isDefaultOrder) {
                if isDefaultOrder {
                    engine.document.setDrawOrderForAll(handles: selectedHandles, to: Int.max)
                } else {
                    engine.document.setDrawOrderForAll(handles: selectedHandles, to: 0)
                }
            }
            if !isDefaultOrder {
                var drawOrder = Int32(clamping: entity.drawOrder)
                ImGuiPushItemWidth(ImGuiGetFontSize() * 4)
                if ImGuiInputInt("Draw order", &drawOrder, 1, 10, 0) {
                    engine.document.setDrawOrderForAll(handles: selectedHandles, to: Int(drawOrder))
                }
                ImGuiPopItemWidth()
            }

            igSeparator()
        }

        // Section 4: Transform — position, rotation (in degrees), scale
        if ImGuiCollapsingHeader("Transform", Int32(ImGuiTreeNodeFlags_DefaultOpen.rawValue)) {
            let pos = entity.transform.position
            let rot = entity.transform.rotation * 180.0 / .pi
            let scl = entity.transform.scale
            ImGuiTextV("Position: (\(String(format: "%.2f", pos.x)), \(String(format: "%.2f", pos.y)), \(String(format: "%.2f", pos.z)))")
            ImGuiTextV("Rotation: \(String(format: "%.1f", rot))\u{00B0}")
            ImGuiTextV("Scale: (\(String(format: "%.2f", scl.x)), \(String(format: "%.2f", scl.y)), \(String(format: "%.2f", scl.z)))")
            igSeparator()
        }


        if entity.leaderData != nil {
            renderLeaderSection(entity: entity, engine: engine)
        }

        // Section 5.5: Dimension Properties
        if let dimBox = entity.dimensionMetadata {
            if ImGuiCollapsingHeader("Dimension Properties", Int32(ImGuiTreeNodeFlags_DefaultOpen.rawValue)) {
                let metadata = dimBox.value
                var style = metadata.styleOverrides ?? engine.document.dimensionStyles[metadata.styleName] ?? CADDimensionStyle.default
                var changed = false
                
                // Text Override
                let textOverride = metadata.textOverride ?? ""
                let bufSize = 256
                var buffer = [CChar](repeating: 0, count: bufSize)
                let bytes = textOverride.utf8CString
                for i in 0..<min(bytes.count, bufSize - 1) {
                    buffer[i] = bytes[i]
                }
                
                var submitted = false
                ImGuiPushItemWidth(-1)
                ImGuiTextV("Text Override:")
                buffer.withUnsafeMutableBufferPointer { b -> Void in
                    if let base = b.baseAddress {
                        if igInputText("##DimTextOverride", base, bufSize, Int32(ImGuiInputTextFlags_EnterReturnsTrue.rawValue), nil, nil) {
                            submitted = true
                        }
                    }
                }
                ImGuiPopItemWidth()
                
                if submitted || ImGuiIsItemDeactivatedAfterEdit() {
                    let newText = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
                    var newMeta = metadata
                    // empty string means clear the override
                    newMeta = CADDimensionMetadata(
                        styleName: metadata.styleName,
                        type: metadata.type,
                        measurement: metadata.measurement,
                        defPoint: metadata.defPoint,
                        defPoint2: metadata.defPoint2,
                        defPoint3: metadata.defPoint3,
                        defPoint4: metadata.defPoint4,
                        defPoint5: metadata.defPoint5,
                        textMidpoint: metadata.textMidpoint,
                        textOverride: newText.isEmpty ? nil : newText,
                        rotationAngle: metadata.rotationAngle,
                        textRotationAngle: metadata.textRotationAngle,
                        flags: metadata.flags,
                        styleOverrides: metadata.styleOverrides
                    )
                    var newEntity = entity
                    newEntity.dimensionMetadata = CADDimensionMetadataBox(newMeta)
                    DimensionPrimitives.updateDimensionBlock(for: &newEntity, in: engine.document)
                    engine.document.updateEntity(newEntity)
                }
                
                // Text Style
                ImGuiTextV("Text Style:")
                ImGuiPushItemWidth(-1)
                if ImGuiBeginCombo("##DimTextStyle", style.textStyle, 0) {
                    for ts in engine.document.textStyleFonts.keys.sorted() {
                        let selected = (ts == style.textStyle)
                        if ImGuiSelectable(ts, selected, 0, ImVec2(x: 0, y: 0)) {
                            style.textStyle = ts
                            changed = true
                        }
                        if selected { ImGuiSetItemDefaultFocus() }
                    }
                    ImGuiEndCombo()
                }
                ImGuiPopItemWidth()
                
                // Text Height
                var textHeight = Float(style.textHeight)
                if ImGuiInputFloat("Text Height", &textHeight, 0.1, 1.0, "%.3f", 0) {
                    style.textHeight = Double(max(0.1, textHeight))
                    changed = true
                }
                
                // Arrow Size
                var arrowSize = Float(style.arrowSize)
                if ImGuiInputFloat("Arrow Size", &arrowSize, 0.1, 1.0, "%.3f", 0) {
                    style.arrowSize = Double(max(0.1, arrowSize))
                    changed = true
                }

                let firstArrow = style.resolvedFirstArrowhead
                let firstArrowLabel = firstArrow == .userArrow
                    ? (style.firstArrowBlockName ?? firstArrow.displayName)
                    : firstArrow.displayName
                ImGuiTextV("Arrow 1:")
                ImGuiPushItemWidth(-1)
                if ImGuiBeginCombo("##DimArrow1", firstArrowLabel, 0) {
                    for arrow in CADDimensionArrowhead.allCases where arrow != .userArrow || firstArrow == .userArrow {
                        let selected = arrow == firstArrow
                        let label = arrow == .userArrow
                            ? (style.firstArrowBlockName ?? arrow.displayName)
                            : arrow.displayName
                        if ImGuiSelectable(label, selected, 0, ImVec2(x: 0, y: 0)) {
                            style.firstArrowhead = arrow
                            if arrow != .userArrow { style.firstArrowBlockName = nil }
                            changed = true
                        }
                        if selected { ImGuiSetItemDefaultFocus() }
                    }
                    ImGuiEndCombo()
                }
                ImGuiPopItemWidth()

                let secondArrow = style.resolvedSecondArrowhead
                let secondArrowLabel = secondArrow == .userArrow
                    ? (style.secondArrowBlockName ?? secondArrow.displayName)
                    : secondArrow.displayName
                ImGuiTextV("Arrow 2:")
                ImGuiPushItemWidth(-1)
                if ImGuiBeginCombo("##DimArrow2", secondArrowLabel, 0) {
                    for arrow in CADDimensionArrowhead.allCases where arrow != .userArrow || secondArrow == .userArrow {
                        let selected = arrow == secondArrow
                        let label = arrow == .userArrow
                            ? (style.secondArrowBlockName ?? arrow.displayName)
                            : arrow.displayName
                        if ImGuiSelectable(label, selected, 0, ImVec2(x: 0, y: 0)) {
                            style.secondArrowhead = arrow
                            if arrow != .userArrow { style.secondArrowBlockName = nil }
                            changed = true
                        }
                        if selected { ImGuiSetItemDefaultFocus() }
                    }
                    ImGuiEndCombo()
                }
                ImGuiPopItemWidth()
                
                if changed {
                    var newMeta = metadata
                    newMeta.styleOverrides = style
                    var newEntity = entity
                    newEntity.dimensionMetadata = CADDimensionMetadataBox(newMeta)
                    DimensionPrimitives.updateDimensionBlock(for: &newEntity, in: engine.document)
                    engine.document.updateEntity(newEntity)
                }
                igSeparator()
            }
        }

        if ImGuiCollapsingHeader("Bounding Box", Int32(ImGuiTreeNodeFlags_None.rawValue)) {
            if let bb = entity.worldBoundingBox {
                ImGuiTextV("Min: (\(String(format: "%.2f", bb.min.x)), \(String(format: "%.2f", bb.min.y)), \(String(format: "%.2f", bb.min.z)))")
                ImGuiTextV("Max: (\(String(format: "%.2f", bb.max.x)), \(String(format: "%.2f", bb.max.y)), \(String(format: "%.2f", bb.max.z)))")
                let sz = bb.size
                ImGuiTextV("Size: (\(String(format: "%.2f", sz.x)), \(String(format: "%.2f", sz.y)), \(String(format: "%.2f", sz.z)))")
            } else {
                ImGuiTextV("N/A")
            }
            igSeparator()
        }

        // Section 6: Geometry — editable Length for single-line entities
        // (only for top-level, non-block, single-select entities)
        if selectedHandles.count == 1,
           entity.blockID == nil,
           let localGeom = entity.localGeometry,
           localGeom.count == 1,
           case .line(let lineStart, let lineEnd, let lineColor) = localGeom[0]
        {
            let currentLength = hypot(lineEnd.x - lineStart.x, lineEnd.y - lineStart.y)
            ImGuiTextV("Length: \(String(format: "%.4f", currentLength))")

            var draftLength = currentLength
            ImGuiPushItemWidth(ImGuiGetFontSize() * 8)
            let changed = ImGuiInputDouble("##LineLength", &draftLength, 0.0, 0.0, "%.4f", Int32(ImGuiInputTextFlags_EnterReturnsTrue.rawValue))
            ImGuiPopItemWidth()

            let deactivated = ImGuiIsItemDeactivatedAfterEdit()
            let committed = changed || deactivated
            if committed && abs(draftLength - currentLength) > 1e-9 && draftLength > 1e-9 {
                // Compute new endpoint preserving start point and original color.
                let dx = lineEnd.x - lineStart.x
                let dy = lineEnd.y - lineStart.y
                let oldLen = hypot(dx, dy)
                let dir: (x: Double, y: Double)
                if oldLen > 1e-9 {
                    dir = (dx / oldLen, dy / oldLen)
                } else {
                    dir = (1, 0)  // default direction for zero-length line
                }
                let newEnd = Vector3(
                    x: lineStart.x + dir.x * draftLength,
                    y: lineStart.y + dir.y * draftLength,
                    z: 0
                )
                let newLine = CADPrimitive.line(start: lineStart, end: newEnd, color: lineColor)
                engine.document.updateEntityGeometry(for: handle, geometry: [newLine])
                engine.tabManager.markActiveDirty()
            }
            igSeparator()
        }

        // Section 6 (continued): Geometry tree — delegates to GeometryPanelUI for resolved primitives
        GeometryPanelUI.render(geometry: geometry)

        // Section 6b: Hatch / Gradient properties
        renderHatchSection(entity: entity, engine: engine, geometry: geometry)

        // Section 7: Remaining XData entries not shown in the overrides section
        let shownOverrideKeys: Set<String> = [
            "dxf.lineType", "dxf.lineWeight", "dxf.lineTypeScale",
            "dxf.polylineWidth", "dxf.color", "dxf.drawOrder"]
        let remainingXData = entity.xdata.filter { !shownOverrideKeys.contains($0.key) }
        if !remainingXData.isEmpty {
            if ImGuiCollapsingHeader("XData", Int32(ImGuiTreeNodeFlags_None.rawValue)) {
                for (key, val) in remainingXData.sorted(by: { $0.key < $1.key }) {
                    let valStr: String
                    switch val {
                    case .string(let s): valStr = s
                    case .double(let d): valStr = String(format: "%.4f", d)
                    case .int(let i):    valStr = "\(i)"
                    case .bool(let b):   valStr = b ? "true" : "false"
                    case .date(let d):   valStr = "\(d)"
                    }
                    ImGuiTextV("\(key): \(valStr)")
                }
                igSeparator()
            }
        }
    }

    private static func renderLeaderSection(
        entity: CADEntity,
        engine: PhrostEngine
    ) {
        guard let box = entity.leaderData,
              ImGuiCollapsingHeader(
                "Leader Properties",
                Int32(ImGuiTreeNodeFlags_DefaultOpen.rawValue)) else { return }

        var data = box.value
        var style = data.styleOverrides
            ?? engine.document.leaderStyle(named: data.styleName)
            ?? .standard
        var changed = false

        ImGuiTextV("Style: \(data.styleName)")
        switch data.contentType {
        case .none: ImGuiTextV("Content: None")
        case .mtext: ImGuiTextV("Content: MText")
        case .block: ImGuiTextV("Content: Block")
        }

        if data.contentType == .mtext && ImGuiButton("Edit Leader Text", ImVec2(x: 0, y: 0)) {
            engine.cadSelection.selectLeaderContent(entity.handle)
            engine.commandProcessor.executeCommand("DDEDIT")
        }

        let pathLabel: String
        switch style.pathType {
        case .straight: pathLabel = "Straight"
        case .spline: pathLabel = "Spline"
        case .none: pathLabel = "None"
        }
        if ImGuiBeginCombo("Leader line", pathLabel, 0) {
            let choices: [(CADLeaderPathType, String)] = [
                (.straight, "Straight"),
                (.spline, "Spline"),
                (.none, "None")
            ]
            for choice in choices {
                let selected = choice.0 == style.pathType
                if ImGuiSelectable(choice.1, selected, 0, ImVec2(x: 0, y: 0)) {
                    style.pathType = choice.0
                    changed = true
                }
                if selected { ImGuiSetItemDefaultFocus() }
            }
            ImGuiEndCombo()
        }

        var arrowEnabled = style.arrowEnabled
        if ImGuiCheckbox("Arrowhead enabled", &arrowEnabled) {
            style.arrowEnabled = arrowEnabled
            changed = true
        }
        let currentArrowhead = style.arrowhead ?? .closedFilled
        if ImGuiBeginCombo("Arrowhead", leaderArrowheadLabel(currentArrowhead), 0) {
            for arrowhead in CADLeaderArrowhead.allCases {
                let selected = arrowhead == currentArrowhead
                if ImGuiSelectable(leaderArrowheadLabel(arrowhead), selected, 0, ImVec2(x: 0, y: 0)) {
                    style.arrowhead = arrowhead
                    style.arrowEnabled = arrowhead != .none
                    if arrowhead != .custom { style.arrowBlockName = nil }
                    changed = true
                }
                if selected { ImGuiSetItemDefaultFocus() }
            }
            ImGuiEndCombo()
        }
        if style.arrowhead == .custom {
            let blockName = style.arrowBlockName ?? "Select block"
            if ImGuiBeginCombo("Arrow block", blockName, 0) {
                for block in engine.document.allBlocks
                    .filter({ !$0.name.isEmpty })
                    .sorted(by: { $0.name < $1.name }) {
                    let selected = block.name.caseInsensitiveCompare(style.arrowBlockName ?? "") == .orderedSame
                    if ImGuiSelectable(block.name, selected, 0, ImVec2(x: 0, y: 0)) {
                        style.arrowBlockName = block.name
                        changed = true
                    }
                    if selected { ImGuiSetItemDefaultFocus() }
                }
                ImGuiEndCombo()
            }
        }
        var arrowSize = Float(style.arrowSize)
        if ImGuiInputFloat("Arrow size", &arrowSize, 0.1, 1.0, "%.3f", 0) {
            style.arrowSize = Double(max(0, arrowSize))
            changed = true
        }

        var landingEnabled = style.landingEnabled
        if ImGuiCheckbox("Landing enabled", &landingEnabled) {
            style.landingEnabled = landingEnabled
            changed = true
        }
        var doglegEnabled = style.doglegEnabled
        if ImGuiCheckbox("Dogleg enabled", &doglegEnabled) {
            style.doglegEnabled = doglegEnabled
            changed = true
        }
        var doglegLength = Float(style.doglegLength)
        if ImGuiInputFloat("Dogleg length", &doglegLength, 0.1, 1.0, "%.3f", 0) {
            let newLength = Double(max(0, doglegLength))
            style.doglegLength = newLength
            for index in data.branches.indices where data.branches[index].doglegLength != nil {
                data.branches[index].doglegLength = newLength
            }
            changed = true
        }
        let previousContentGap = style.contentGap
        var contentGap = Float(style.contentGap)
        if ImGuiInputFloat("Content gap", &contentGap, 0.1, 1.0, "%.3f", 0) {
            style.contentGap = Double(max(0, contentGap))
            changed = true
        }
        var extendToText = style.extendLeaderToText ?? false
        if ImGuiCheckbox("Extend leader to text", &extendToText) {
            style.extendLeaderToText = extendToText
            changed = true
        }

        if data.contentType == .mtext {
            var textHeight = Float(style.textHeight)
            if ImGuiInputFloat("Text height", &textHeight, 0.1, 1.0, "%.3f", 0) {
                style.textHeight = Double(max(0.0001, textHeight))
                changed = true
            }
            if ImGuiBeginCombo("Text style", style.textStyleName, 0) {
                for textStyle in engine.document.textStyles.values.sorted(by: { $0.name < $1.name }) {
                    let selected = textStyle.name.caseInsensitiveCompare(style.textStyleName) == .orderedSame
                    if ImGuiSelectable(textStyle.name, selected, 0, ImVec2(x: 0, y: 0)) {
                        style.textStyleName = textStyle.name
                        changed = true
                    }
                    if selected { ImGuiSetItemDefaultFocus() }
                }
                ImGuiEndCombo()
            }
            let textAlignment = style.textAlignment ?? .left
            if ImGuiBeginCombo("Text alignment", leaderTextAlignmentLabel(textAlignment), 0) {
                for alignment in CADLeaderTextAlignment.allCases {
                    let selected = alignment == textAlignment
                    if ImGuiSelectable(leaderTextAlignmentLabel(alignment), selected, 0, ImVec2(x: 0, y: 0)) {
                        style.textAlignment = alignment
                        changed = true
                    }
                    if selected { ImGuiSetItemDefaultFocus() }
                }
                ImGuiEndCombo()
            }
            let textAttachment = data.textAttachment
                ?? style.leftAttachment
                ?? .middleOfTop
            if ImGuiBeginCombo("Text attachment", leaderTextAttachmentLabel(textAttachment), 0) {
                for attachment in CADLeaderTextAttachment.allCases {
                    let selected = attachment == textAttachment
                    if ImGuiSelectable(leaderTextAttachmentLabel(attachment), selected, 0, ImVec2(x: 0, y: 0)) {
                        data.textAttachment = attachment
                        changed = true
                    }
                    if selected { ImGuiSetItemDefaultFocus() }
                }
                ImGuiEndCombo()
            }
            let textAngleType = style.textAngleType ?? .insertAngle
            if ImGuiBeginCombo("Text angle", leaderTextAngleLabel(textAngleType), 0) {
                for angleType in CADLeaderTextAngleType.allCases {
                    let selected = angleType == textAngleType
                    if ImGuiSelectable(leaderTextAngleLabel(angleType), selected, 0, ImVec2(x: 0, y: 0)) {
                        style.textAngleType = angleType
                        changed = true
                    }
                    if selected { ImGuiSetItemDefaultFocus() }
                }
                ImGuiEndCombo()
            }
            let attachmentDirection = style.textAttachmentDirection ?? .horizontal
            if ImGuiBeginCombo("Attachment direction", leaderAttachmentDirectionLabel(attachmentDirection), 0) {
                for direction in CADLeaderTextAttachmentDirection.allCases {
                    let selected = direction == attachmentDirection
                    if ImGuiSelectable(leaderAttachmentDirectionLabel(direction), selected, 0, ImVec2(x: 0, y: 0)) {
                        style.textAttachmentDirection = direction
                        changed = true
                    }
                    if selected { ImGuiSetItemDefaultFocus() }
                }
                ImGuiEndCombo()
            }
            var alwaysLeft = style.alwaysLeftJustify ?? false
            if ImGuiCheckbox("Always left justify", &alwaysLeft) {
                style.alwaysLeftJustify = alwaysLeft
                changed = true
            }
            var frameEnabled = style.textFrameEnabled
            if ImGuiCheckbox("Text frame", &frameEnabled) {
                style.textFrameEnabled = frameEnabled
                changed = true
            }
            var rotationDegrees = Float(data.contentRotation * 180.0 / .pi)
            if ImGuiInputFloat("Text rotation", &rotationDegrees, 1, 15, "%.1f deg", 0) {
                data.contentRotation = Double(rotationDegrees) * .pi / 180.0
                changed = true
            }
        }

        if changed {
            let gapDelta = style.contentGap - previousContentGap
            if data.contentType != .none,
               abs(gapDelta) > 1e-9,
               let direction = leaderContentDirection(data: data) {
                data.contentPosition = data.contentPosition + direction * gapDelta
            }
            data.styleOverrides = style
            var updatedEntity = entity
            updatedEntity.leaderData = CADLeaderDataBox(data)
            updatedEntity = engine.document.regeneratedLeaderEntity(updatedEntity)
            engine.document.updateEntity(updatedEntity)
            engine.tabManager.markActiveDirty()
        }
        igSeparator()
    }


    private static func leaderArrowheadLabel(_ value: CADLeaderArrowhead) -> String {
        switch value {
        case .none: return "None"
        case .closedFilled: return "Closed filled"
        case .closedBlank: return "Closed blank"
        case .open: return "Open"
        case .dot: return "Dot"
        case .dotBlank: return "Dot blank"
        case .architecturalTick: return "Architectural tick"
        case .oblique: return "Oblique"
        case .originIndicator: return "Origin indicator"
        case .boxFilled: return "Box filled"
        case .boxBlank: return "Box blank"
        case .custom: return "Custom block"
        }
    }

    private static func leaderTextAlignmentLabel(_ value: CADLeaderTextAlignment) -> String {
        switch value {
        case .left: return "Left"
        case .center: return "Center"
        case .right: return "Right"
        }
    }

    private static func leaderTextAngleLabel(_ value: CADLeaderTextAngleType) -> String {
        switch value {
        case .insertAngle: return "Insert angle"
        case .horizontal: return "Horizontal"
        case .alwaysRightReading: return "Always right-reading"
        }
    }

    private static func leaderAttachmentDirectionLabel(
        _ value: CADLeaderTextAttachmentDirection
    ) -> String {
        value == .horizontal ? "Horizontal" : "Vertical"
    }

    private static func leaderTextAttachmentLabel(_ value: CADLeaderTextAttachment) -> String {
        switch value {
        case .topOfTop: return "Top of top line"
        case .middleOfTop: return "Middle of top line"
        case .middle: return "Middle"
        case .middleOfBottom: return "Middle of bottom line"
        case .bottomOfBottom: return "Bottom of bottom line"
        case .bottomLine: return "Bottom line"
        case .bottomOfTopLine: return "Bottom of top line"
        case .bottomOfTop: return "Bottom of top"
        case .allLine: return "All lines"
        case .center: return "Center"
        case .linedCenter: return "Underline/overline center"
        }
    }

    private static func leaderContentDirection(data: CADLeaderData) -> Vector3? {
        guard let branch = data.branches.first,
              let last = branch.vertices.last else { return nil }

        if let doglegDirection = branch.doglegDirection?.normalized,
           doglegDirection.magnitudeSquared > 1e-18 {
            return doglegDirection
        }

        let towardContent = (data.contentPosition - last).normalized
        if towardContent.magnitudeSquared > 1e-18 {
            return towardContent
        }

        return Vector3(x: 1, y: 0, z: 0)
    }

    // MARK: - Hatch / Gradient properties

    /// Render Hatch / Gradient properties for the selected entity.
    private static func renderHatchSection(entity: CADEntity, engine: PhrostEngine, geometry: [CADPrimitive]) {
        for (primitiveIndex, prim) in geometry.enumerated() {
            switch prim {
            case .hatch(let boundary, let pattern, let scale, let angle, let color, let backgroundColor):
                guard ImGuiCollapsingHeader("Hatch", Int32(ImGuiTreeNodeFlags_DefaultOpen.rawValue)) else { continue }

                ImGuiTextV("Pattern")
                ImGuiSameLine(0, 8)
                let pats = ["SOLID"] + DXFHatchGenerator.predefinedPatterns.keys.sorted()
                let currentPat = pattern.isEmpty ? "SOLID" : pattern.uppercased()
                ImGuiPushItemWidth(ImGuiGetFontSize() * 8)
                if ImGuiBeginCombo("##PropsHatchPat", currentPat, 0) {
                    for pn in pats {
                        let selected = pn == currentPat
                        if ImGuiSelectable(pn, selected, 0, ImVec2(x: 0, y: 0)) {
                            let newPrim = CADPrimitive.hatch(
                                boundary: boundary, pattern: pn == "SOLID" ? "SOLID" : pn,
                                scale: scale, angle: angle, color: color, backgroundColor: backgroundColor)
                            updateHatchPrimitive(entity: entity, geometry: geometry, index: primitiveIndex, primitive: newPrim, engine: engine)
                            engine.tabManager.markActiveDirty()
                        }
                        if selected { ImGuiSetItemDefaultFocus() }
                    }
                    ImGuiEndCombo()
                }
                ImGuiPopItemWidth()

                var angleDeg = Float(angle * 180.0 / .pi)
                ImGuiTextV("Angle")
                ImGuiSameLine(0, 8)
                ImGuiPushItemWidth(ImGuiGetFontSize() * 5)
                if ImGuiSliderAngle("##PropsHatchAngle", &angleDeg, -180, 180, "%.0f", ImGuiSliderFlags(0)) {
                    let newPrim = CADPrimitive.hatch(boundary: boundary, pattern: pattern, scale: scale, angle: Double(angleDeg), color: color, backgroundColor: backgroundColor)
                    updateHatchPrimitive(entity: entity, geometry: geometry, index: primitiveIndex, primitive: newPrim, engine: engine)
                    engine.tabManager.markActiveDirty()
                }
                ImGuiPopItemWidth()

                var scl = Float(scale)
                ImGuiTextV("Scale")
                ImGuiSameLine(0, 8)
                ImGuiPushItemWidth(ImGuiGetFontSize() * 5)
                if ImGuiInputFloat("##PropsHatchScale", &scl, 0.1, 1.0, "%.2f", 0) {
                    let newPrim = CADPrimitive.hatch(boundary: boundary, pattern: pattern, scale: Double(scl), angle: angle, color: color, backgroundColor: backgroundColor)
                    updateHatchPrimitive(entity: entity, geometry: geometry, index: primitiveIndex, primitive: newPrim, engine: engine)
                    engine.tabManager.markActiveDirty()
                }
                ImGuiPopItemWidth()

                igSeparator()

            case .hatchPath(let boundary, let holes, let pattern, let scale, let angle, let color, let backgroundColor):
                guard ImGuiCollapsingHeader("Hatch", Int32(ImGuiTreeNodeFlags_DefaultOpen.rawValue)) else { continue }

                ImGuiTextV("Pattern")
                ImGuiSameLine(0, 8)
                let pats = ["SOLID"] + DXFHatchGenerator.predefinedPatterns.keys.sorted()
                let currentPat = pattern.isEmpty ? "SOLID" : pattern.uppercased()
                ImGuiPushItemWidth(ImGuiGetFontSize() * 8)
                if ImGuiBeginCombo("##PropsHatchPathPat", currentPat, 0) {
                    for pn in pats {
                        let selected = pn == currentPat
                        if ImGuiSelectable(pn, selected, 0, ImVec2(x: 0, y: 0)) {
                            let newPrim = CADPrimitive.hatchPath(
                                boundary: boundary, holes: holes, pattern: pn == "SOLID" ? "SOLID" : pn,
                                scale: scale, angle: angle, color: color, backgroundColor: backgroundColor)
                            updateHatchPrimitive(entity: entity, geometry: geometry, index: primitiveIndex, primitive: newPrim, engine: engine)
                            engine.tabManager.markActiveDirty()
                        }
                        if selected { ImGuiSetItemDefaultFocus() }
                    }
                    ImGuiEndCombo()
                }
                ImGuiPopItemWidth()

                var angleDeg = Float(angle * 180.0 / .pi)
                ImGuiTextV("Angle")
                ImGuiSameLine(0, 8)
                ImGuiPushItemWidth(ImGuiGetFontSize() * 5)
                if ImGuiSliderAngle("##PropsHatchPathAngle", &angleDeg, -180, 180, "%.0f", ImGuiSliderFlags(0)) {
                    let newPrim = CADPrimitive.hatchPath(boundary: boundary, holes: holes, pattern: pattern, scale: scale, angle: Double(angleDeg), color: color, backgroundColor: backgroundColor)
                    updateHatchPrimitive(entity: entity, geometry: geometry, index: primitiveIndex, primitive: newPrim, engine: engine)
                    engine.tabManager.markActiveDirty()
                }
                ImGuiPopItemWidth()

                var scl = Float(scale)
                ImGuiTextV("Scale")
                ImGuiSameLine(0, 8)
                ImGuiPushItemWidth(ImGuiGetFontSize() * 5)
                if ImGuiInputFloat("##PropsHatchPathScale", &scl, 0.1, 1.0, "%.2f", 0) {
                    let newPrim = CADPrimitive.hatchPath(boundary: boundary, holes: holes, pattern: pattern, scale: Double(scl), angle: angle, color: color, backgroundColor: backgroundColor)
                    updateHatchPrimitive(entity: entity, geometry: geometry, index: primitiveIndex, primitive: newPrim, engine: engine)
                    engine.tabManager.markActiveDirty()
                }
                ImGuiPopItemWidth()

                igSeparator()

            case .gradient(let outer, let holes, let name, let gradAngle, let c1, let c2):
                guard ImGuiCollapsingHeader("Gradient", Int32(ImGuiTreeNodeFlags_DefaultOpen.rawValue)) else { continue }
                ImGuiTextV("Type: \(name)")

                var angleDeg = Float(gradAngle * 180.0 / .pi)
                ImGuiTextV("Angle")
                ImGuiSameLine(0, 8)
                ImGuiPushItemWidth(ImGuiGetFontSize() * 5)
                if ImGuiSliderAngle("##PropsGradAngle", &angleDeg, -180, 180, "%.0f", ImGuiSliderFlags(0)) {
                    let newPrim = CADPrimitive.gradient(outer: outer, holes: holes, gradientName: name, angle: Double(angleDeg), color1: c1, color2: c2)
                    updateHatchPrimitive(entity: entity, geometry: geometry, index: primitiveIndex, primitive: newPrim, engine: engine)
                    engine.tabManager.markActiveDirty()
                }
                ImGuiPopItemWidth()

                igSeparator()

            default:
                break
            }
        }
    }

    private static func updateHatchPrimitive(
        entity: CADEntity,
        geometry: [CADPrimitive],
        index: Int,
        primitive: CADPrimitive,
        engine: PhrostEngine
    ) {
        guard geometry.indices.contains(index) else { return }
        var updatedGeometry = geometry
        updatedGeometry[index] = primitive
        var updatedEntity = entity
        updatedEntity.localGeometry = updatedGeometry

        switch primitive {
        case .hatch(_, let pattern, let scale, let angle, _, _),
             .hatchPath(_, _, let pattern, let scale, let angle, _, _):
            updatedEntity.xdata["dxf.hatchPatternName"] = .string(pattern)
            updatedEntity.xdata["dxf.hatchScale"] = .double(scale)
            updatedEntity.xdata["dxf.hatchAngle"] = .double(angle)
            updatedEntity.xdata["dxf.hatchIsGradient"] = .bool(false)
        case .gradient(_, _, let name, let angle, _, _):
            updatedEntity.xdata["dxf.hatchPatternName"] = .string("GRADIENT")
            updatedEntity.xdata["dxf.hatchIsGradient"] = .bool(true)
            updatedEntity.xdata["dxf.hatchGradientName"] = .string(name)
            updatedEntity.xdata["dxf.hatchGradientAngle"] = .double(angle)
        default:
            break
        }

        engine.document.updateEntity(updatedEntity)
    }

    /// Parse a hex color string like "#FF8000" or "FF8000" into [Float] (0–1 range).
    private static func hexToFloatArray(_ hex: String) -> [Float] {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let val = UInt32(s, radix: 16) else {
            return [1.0, 1.0, 1.0] // default white
        }
        return [
            Float((val >> 16) & 0xFF) / 255.0,
            Float((val >> 8) & 0xFF) / 255.0,
            Float(val & 0xFF) / 255.0
        ]
    }

}