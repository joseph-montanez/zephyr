import ZephyrCore
import Foundation
import ImGui

// MARK: - LayerPanelUI
//
// Renders the Layers panel as a floating or docked ImGui window.
// Each layer is one full-width row with visibility, color, name, and
// properties controls drawn inside the same interaction target.

@MainActor
struct LayerPanelUI {
    static var _editingLayerHandle: UUID? = nil
    static var _editingDocumentID: ObjectIdentifier? = nil
    static var _editingLayerNameBuf: [CChar] = []
    static var _isDockedBySlot: [WindowSlotID: Bool] = [:]
    static var _searchText: String = ""
    static var _searchBuf: [CChar] = []
    static var _cachedCountsDocumentID: ObjectIdentifier? = nil
    static var _cachedCountsRevision: UInt64 = .max
    static var _cachedCounts: [UUID: Int] = [:]

    /// Read the shared persisted settings each frame so LAYERSORT
    /// commands take effect immediately in an already-open panel.
    private static func sortSettings() -> LayerSortSettings {
        LayerSortSettings.load()
    }

    private static func applySort(_ settings: LayerSortSettings) {
        settings.save()
    }

    private static func entityCounts(for doc: CADDocument) -> [UUID: Int] {
        if _cachedCountsDocumentID == ObjectIdentifier(doc),
           _cachedCountsRevision == doc.editRevision {
            return _cachedCounts
        }
        _cachedCounts = LayerSortPolicy.entityCounts(in: doc)
        _cachedCountsDocumentID = ObjectIdentifier(doc)
        _cachedCountsRevision = doc.editRevision
        return _cachedCounts
    }

    /// Flat visible layer order (uncapped): host layers first, then
    /// xref-dependent layers grouped by owning xref. Follows the shared
    /// sort settings (LAYERSORT command / sort strip) and name search —
    /// the same order the rows render in.
    private static func orderedVisibleLayers(for doc: CADDocument) -> [Layer] {
        let layers = LayerManagerUI.displayLayers(for: doc)
        let settings = sortSettings()
        let counts = settings.key == .used ? entityCounts(for: doc) : [:]
        let search = _searchText.trimmingCharacters(
            in: .whitespacesAndNewlines)
        func visibleLayers(_ list: [Layer]) -> [Layer] {
            let sorted = LayerSortPolicy.sorted(
                list, entityCounts: counts, settings: settings)
            guard !search.isEmpty else { return sorted }
            return sorted.filter {
                $0.name.localizedCaseInsensitiveContains(search)
            }
        }
        var ordered = visibleLayers(
            layers.filter { !doc.isXrefDependentLayer($0) })
        let dependent = layers.filter { doc.isXrefDependentLayer($0) }
        let owners = Array(Set(dependent.compactMap {
            doc.xrefOwnerBlockName(forLayerName: $0.name)
        })).sorted()
        for owner in owners {
            ordered.append(contentsOf: visibleLayers(dependent.filter {
                doc.xrefOwnerBlockName(forLayerName: $0.name) == owner
            }))
        }
        return ordered
    }

    /// Panel-scoped keys: Ctrl+A selects all visible layers, F2 starts
    /// rename for a single selected layer. Only when the Layers window
    /// is focused and no text field is active, so typing in search or
    /// rename and the global entity Ctrl+A are never disturbed.
    private static func handlePanelKeys(document doc: CADDocument) {
        guard _editingLayerHandle == nil else { return }
        guard let io = ImGuiGetIO() else { return }
        if io.pointee.WantTextInput { return }
        let focused = ImGuiIsWindowFocused(ImGuiFocusedFlags(
            ImGuiFocusedFlags_RootAndChildWindows.rawValue))
        guard focused else { return }
        let ctrl = io.pointee.KeyCtrl || io.pointee.KeySuper
        if ctrl && ImGuiIsKeyPressed(
            ImGuiKey(ImGuiKey_A.rawValue), false) {
            LayerManagerUI.selection.selectAll(
                in: LayerManagerUI.visibleOrder)
            LayerManagerUI.notice =
                "Selected \(LayerManagerUI.selection.count) layers."
        } else if ImGuiIsKeyPressed(
            ImGuiKey(ImGuiKey_F2.rawValue), false) {
            let picked = LayerManagerUI.selection.selected
            if picked.count == 1, let handle = picked.first {
                _editingLayerHandle = handle
                _editingDocumentID = ObjectIdentifier(doc)
                _editingLayerNameBuf = []
            }
        }
    }

    /// Ctrl/Shift state for row clicks (Cmd counts as Ctrl on macOS).
    private static func clickModifiers() -> (ctrl: Bool, shift: Bool) {
        guard let io = ImGuiGetIO() else { return (false, false) }
        return (
            io.pointee.KeyCtrl || io.pointee.KeySuper,
            io.pointee.KeyShift)
    }

    static func render(engine: PhrostEngine, document: CADDocument) {
        let doc = document
        let layers = LayerManagerUI.displayLayers(for: doc)
        let fontSize = ImGuiGetFontSize()
        let panelW: Float = fontSize * 18
        let layerRowH = LayerPanelPolicy(
            frameHeight: ImGuiGetFrameHeight()).rowHeight
        let minRows = max(Float(layers.count), 3)
        let panelH = max(100, layerRowH * minRows + 60)

        ImGuiSetNextWindowPos(
            ImVec2(x: 4, y: AppLayout.belowChromeY + 4),
            Int32(ImGuiCond_FirstUseEver.rawValue),
            ImVec2(x: 0, y: 0))
        ImGuiSetNextWindowSize(
            ImVec2(x: panelW, y: max(panelH, 80)),
            Int32(ImGuiCond_FirstUseEver.rawValue))

        let wasDocked = _isDockedBySlot[engine.ui.frameSlot] ?? false
        ImGuiPushStyleColor(
            Int32(ImGuiCol_WindowBg.rawValue),
            wasDocked ? engine.ui.theme.panelBg : engine.ui.theme.panelBgDim)
        ImGuiPushStyleVar(
            Int32(ImGuiStyleVar_WindowBorderSize.rawValue),
            wasDocked ? 0.0 : 1.0)
        // Zero horizontal padding lets the selectable rows span the panel.
        ImGuiPushStyleVar(
            Int32(ImGuiStyleVar_WindowPadding.rawValue),
            ImVec2(x: 0, y: 8))

        var opened = true
        var flags: Int32 = 0
        if wasDocked {
            flags |= Int32(ImGuiWindowFlags_NoTitleBar.rawValue)
        }

        let entered = wasDocked
            ? igBegin("Layers##LayersPanel", nil, flags)
            : igBegin("Layers##LayersPanel", &opened, flags)
        _isDockedBySlot[engine.ui.frameSlot] = ImGuiIsWindowDocked()
        AppLayout.reportCurrentDockedPanel(engine: engine)

        if entered {

            if !wasDocked && !opened {
                engine.ui.layersPanelVisible = false
            } else {
                renderHeader(engine: engine, document: doc, isDocked: wasDocked)
                renderSortStrip(engine: engine)
                LayerManagerUI.searchText = _searchText
                // Flat visible order (uncapped): selection commands and
                // Shift-range math use this, never the render window.
                let ordered = orderedVisibleLayers(for: doc)
                LayerManagerUI.visibleOrder = ordered.map(\.handle)
                LayerManagerUI.ensureSelection(for: doc)
                _ = LayerManagerUI.renderStrips(engine: engine, document: doc)

                if ordered.isEmpty {
                    ImGuiSetCursorPosX(10)
                    ImGuiTextV(layers.isEmpty ? "(no layers)" : "(no matches)")
                } else {
                    // Host layers first; xref-dependent layers grouped
                    // under a header per owning xref.
                    // Direct iteration — avoid ImGuiListClipper due to arm64e C struct ABI mismatch.
                    var groupCounts: [String: Int] = [:]
                    for layer in ordered {
                        if let owner = doc.xrefOwnerBlockName(
                            forLayerName: layer.name) {
                            groupCounts[owner, default: 0] += 1
                        }
                    }
                    var emittedOwners = Set<String>()
                    var rendered = 0
                    for (displayIndex, layer) in ordered.enumerated() {
                        if rendered >= LayerManagerUI.renderRowLimit { break }
                        if let owner = doc.xrefOwnerBlockName(
                            forLayerName: layer.name),
                           !emittedOwners.contains(owner) {
                            emittedOwners.insert(owner)
                            let headerPos = ImGuiGetCursorScreenPos()
                            PanelWidgets.drawIcon(
                                "xref",
                                drawList: ImGuiGetWindowDrawList(),
                                center: ImVec2(
                                    x: headerPos.x + 14,
                                    y: headerPos.y
                                        + ImGuiGetTextLineHeight() * 0.5),
                                size: 14, color: engine.ui.theme.textDim)
                            ImGuiSetCursorPosX(26)
                            ImGuiPushStyleColor(
                                Int32(ImGuiCol_Text.rawValue),
                                engine.ui.theme.textDim)
                            ImGuiTextV(
                                "Xref: \(owner) (\(groupCounts[owner] ?? 0))")
                            ImGuiPopStyleColor(1)
                        }
                        renderLayerRow(
                            engine: engine,
                            document: doc,
                            layer: layer,
                            index: displayIndex,
                            rowHeight: layerRowH,
                            fontSize: fontSize)
                        rendered += 1
                    }
                }
                handlePanelKeys(document: doc)
            }
        }

        igEnd()
        ImGuiPopStyleVar(2)
        ImGuiPopStyleColor(1)
    }

    private static func renderHeader(
        engine: PhrostEngine,
        document: CADDocument,
        isDocked: Bool
    ) {
        ImGuiSetCursorPosX(0)
        let headerY = igGetCursorPos().y
        let headerWidth = ImGuiGetContentRegionAvail().x

        // A docked panel already has a "Layers" tab label.
        if !isDocked {
            ImGuiSetCursorPos(ImVec2(x: 10, y: headerY))
            ImGuiPushStyleColor(
                Int32(ImGuiCol_Text.rawValue),
                engine.ui.theme.textDim)
            ImGuiTextV("LAYERS")
            ImGuiPopStyleColor(1)
        }

        let policy = LayerPanelPolicy(frameHeight: ImGuiGetFrameHeight())
        let buttonSize = policy.toolbarButtonSize
        ImGuiSetCursorPos(ImVec2(
            x: max(0, headerWidth - buttonSize - 6), y: headerY))
        if PanelWidgets.iconButton(
            id: "LPMAddLayer", icon: "plus", tooltip: "Add a new layer",
            theme: engine.ui.theme, size: buttonSize) {
            document.addLayer(Layer(name: document.uniqueLayerName()))
        }

        ImGuiSetCursorPos(ImVec2(
            x: 0,
            y: headerY + max(ImGuiGetFrameHeight(), buttonSize) + 4))
    }

    /// Search + sort row shared with the LAYERSORT command. Reads
    /// settings fresh each frame, so commands take effect immediately
    /// here. Sort markers are menu check marks and drawn triangles —
    /// the UI font has no glyphs for the old Unicode arrows.
    private static func renderSortStrip(engine: PhrostEngine) {
        // Explicit theme colors: the global gold hover/active pair
        // (brandGoldHover/Active) behind near-white text is unreadable
        // on dark themes, so this strip uses mid-tone control colors
        // that keep textPrimary readable in every state and theme.
        let theme = engine.ui.theme
        ImGuiPushStyleColor(Int32(ImGuiCol_Button.rawValue), theme.frameBg)
        ImGuiPushStyleColor(Int32(ImGuiCol_ButtonHovered.rawValue), theme.activeBg)
        ImGuiPushStyleColor(Int32(ImGuiCol_ButtonActive.rawValue), theme.activeBg)
        ImGuiPushStyleColor(Int32(ImGuiCol_Text.rawValue), theme.textPrimary)
        ImGuiPushStyleColor(Int32(ImGuiCol_FrameBg.rawValue), theme.frameBg)
        ImGuiPushStyleColor(Int32(ImGuiCol_FrameBgHovered.rawValue), theme.activeBg)
        ImGuiPushStyleColor(Int32(ImGuiCol_FrameBgActive.rawValue), theme.activeBg)
        ImGuiPushStyleColor(Int32(ImGuiCol_Header.rawValue), theme.activeBg)
        ImGuiPushStyleColor(Int32(ImGuiCol_HeaderHovered.rawValue), theme.activeBg)
        ImGuiPushStyleColor(Int32(ImGuiCol_HeaderActive.rawValue), theme.activeBg)
        ImGuiPushStyleColor(Int32(ImGuiCol_PopupBg.rawValue), theme.panelBg)
        defer { ImGuiPopStyleColor(11) }

        let settings = sortSettings()
        let policy = LayerPanelPolicy(frameHeight: ImGuiGetFrameHeight())
        let buttonSize = policy.toolbarButtonSize

        let bufSize = 128
        if _searchBuf.count != bufSize {
            var buffer = [CChar](repeating: 0, count: bufSize)
            let bytes = _searchText.utf8CString
            for i in 0..<min(bytes.count, bufSize - 1) { buffer[i] = bytes[i] }
            _searchBuf = buffer
        }
        let sortWidth = PanelWidgets.labelButtonWidth(
            icon: "sort", label: settings.key.displayName,
            size: buttonSize, chevron: true)
        let clearWidth: Float = _searchText.isEmpty ? 0 : buttonSize + 4
        ImGuiSetCursorPosX(6)
        let searchWidth = max(
            60, ImGuiGetContentRegionAvail().x - 12 - sortWidth - 4
                - clearWidth)
        ImGuiSetNextItemWidth(searchWidth)
        if igInputTextWithHint("##LayerSearch", "Filter layers...",
                               &_searchBuf, bufSize, 0, nil, nil) {
            _searchText = _searchBuf.withUnsafeBufferPointer { pointer in String(cString: pointer.baseAddress!) }
        }
        if !_searchText.isEmpty {
            ImGuiSameLine(0, 4)
            if PanelWidgets.iconButton(
                id: "LayerSearchClear", icon: "close",
                tooltip: "Clear search", theme: theme, size: buttonSize) {
                _searchText = ""
                _searchBuf = []
            }
        }
        ImGuiSameLine(0, 4)
        if PanelWidgets.labelButton(
            id: "LayerSortMenuBtn", icon: "sort",
            label: settings.key.displayName,
            tooltip: "Sort order (LAYERSORT)",
            theme: theme, size: buttonSize, chevron: true) {
            ImGuiOpenPopup("##LayerSortMenu", 0)
        }
        if ImGuiBeginPopup("##LayerSortMenu", 0) {
            for key in LayerSortKey.allCases {
                if igMenuItem_Bool(
                    key.displayName, nil, settings.key == key, true) {
                    applySort(settings.selecting(key))
                }
            }
            ImGuiSeparator()
            if igMenuItem_Bool(settings.ascending ? "Descending" : "Ascending", nil, false, true) {
                applySort(LayerSortSettings(key: settings.key, ascending: !settings.ascending))
            }
            ImGuiEndPopup()
        }
    }

    private static func renderLayerRow(
        engine: PhrostEngine,
        document: CADDocument,
        layer: Layer,
        index: Int,
        rowHeight: Float,
        fontSize: Float
    ) {
        ImGuiPushID(Int32(index))
        defer { ImGuiPopID() }

        if _editingLayerHandle == layer.handle
            && _editingDocumentID == ObjectIdentifier(document) {
            renderRenameField(document: document, layer: layer, rowHeight: rowHeight)
        } else {
            renderSelectableRow(
                engine: engine,
                document: document,
                layer: layer,
                index: index,
                rowHeight: rowHeight,
                fontSize: fontSize)
        }

        renderColorPopup(document: document, layer: layer, index: index)
        renderPropertiesPopup(document: document, layer: layer, index: index)
    }

    private static func renderSelectableRow(
        engine: PhrostEngine,
        document: CADDocument,
        layer: Layer,
        index: Int,
        rowHeight: Float,
        fontSize: Float
    ) {
        let isActive = document.activeLayerID == layer.handle
        let isSelected = LayerManagerUI.selection.selected.contains(
            layer.handle)

        ImGuiSetCursorPosX(0)
        ImGuiPushStyleColor(
            Int32(ImGuiCol_Header.rawValue),
            engine.ui.theme.activeBg)
        ImGuiPushStyleColor(
            Int32(ImGuiCol_HeaderHovered.rawValue),
            engine.ui.theme.brandGoldHover)
        ImGuiPushStyleColor(
            Int32(ImGuiCol_HeaderActive.rawValue),
            engine.ui.theme.brandGoldActive)
        let clicked = ImGuiSelectable(
            "##LayerRow\(index)",
            isSelected,
            Int32(ImGuiSelectableFlags_AllowDoubleClick.rawValue),
            ImVec2(x: ImGuiGetContentRegionAvail().x, y: rowHeight))
        ImGuiPopStyleColor(3)

        let rowMin = ImGuiGetItemRectMin()
        let rowMax = ImGuiGetItemRectMax()
        let hovered = ImGuiIsItemHovered(0)
        let mouse = ImGuiGetMousePos()
        // Status (current-layer check) | eye | swatch | name | props.
        // Zones come from the shared policy so drawing, hit-testing,
        // and the rename field can never drift apart.
        let policy = LayerPanelPolicy(frameHeight: ImGuiGetFrameHeight())
        let zones = policy.rowZones
        let statusMaxX = rowMin.x + zones.statusEnd
        let eyeMaxX = rowMin.x + zones.eyeEnd
        let swatchMaxX = rowMin.x + zones.swatchEnd
        let propsMinX = rowMax.x - zones.propsWidth

        if clicked {
            let mods = clickModifiers()
            if mouse.x < statusMaxX {
                LayerManagerUI.selection.click(
                    handle: layer.handle,
                    in: LayerManagerUI.visibleOrder,
                    ctrl: mods.ctrl, shift: mods.shift)
            } else if mouse.x < eyeMaxX {
                toggleRowVisibility(document: document, layer: layer)
            } else if mouse.x < swatchMaxX {
                ImGuiOpenPopup("##LayerColorPopup\(layer.handle.uuidString)", 0)
            } else if mouse.x >= propsMinX {
                ImGuiOpenPopup("##LayerPropsPopup\(layer.handle.uuidString)", 0)
            } else {
                LayerManagerUI.selection.click(
                    handle: layer.handle,
                    in: LayerManagerUI.visibleOrder,
                    ctrl: mods.ctrl, shift: mods.shift)
            }
        }

        // AutoCAD parity: double-click (status or name zone) makes the
        // layer current. Single clicks only ever change the selection.
        let inSetCurrentZone = mouse.x < statusMaxX
            || (mouse.x >= swatchMaxX && mouse.x < propsMinX)
        if hovered
            && inSetCurrentZone
            && ImGuiIsMouseDoubleClicked(
                ImGuiMouseButton(ImGuiMouseButton_Left.rawValue))
        {
            document.activeLayerID = layer.handle
            LayerManagerUI.notice = "Current layer: '\(layer.name)'."
        }

        let theme = engine.ui.theme
        let textColor = igGetColorU32_Vec4(
            hovered
                ? theme.rowHoverText
                : theme.textPrimary)
        let drawList = ImGuiGetWindowDrawList()!
        let textY = rowMin.y + (rowHeight - fontSize) * 0.5
        let centerY = rowMin.y + rowHeight * 0.5
        let iconSize = policy.rowIconSize

        // Current-layer check (drawn; the UI font has no check glyph).
        if isActive {
            PanelWidgets.drawIcon(
                "check", drawList: drawList,
                center: ImVec2(x: rowMin.x + zones.statusEnd * 0.5, y: centerY),
                size: iconSize * 0.9, color: theme.brandGold)
        }
        PanelWidgets.drawIcon(
            layer.isVisible ? "eye" : "eye-off", drawList: drawList,
            center: ImVec2(
                x: rowMin.x + (zones.statusEnd + zones.eyeEnd) * 0.5,
                y: centerY),
            size: iconSize,
            color: layer.isVisible
                ? (hovered ? theme.rowHoverText : theme.textPrimary)
                : theme.textDim)

        let swatchColor = ImVec4(
            x: Float(layer.color.r) / 255,
            y: Float(layer.color.g) / 255,
            z: Float(layer.color.b) / 255,
            w: 1)
        let swatchMin = ImVec2(
            x: rowMin.x + zones.swatchRect.x0, y: rowMin.y + 4 * policy.scale)
        let swatchMax = ImVec2(
            x: rowMin.x + zones.swatchRect.x1, y: rowMax.y - 4 * policy.scale)
        ImDrawListAddRectFilled(
            drawList, swatchMin, swatchMax,
            igGetColorU32_Vec4(swatchColor), 2, 0)
        ImDrawListAddRect(
            drawList, swatchMin, swatchMax,
            igGetColorU32_Vec4(theme.borderDim), 2, 1.0, 0)

        // State indicators right-aligned before the props cell.
        let vpFrozen = !LayerManagerUI.vpMarker(for: layer.handle).isEmpty
        var indicators: [(icon: String, label: String)] = []
        if layer.isFrozen { indicators.append(("freeze", "Frozen")) }
        if vpFrozen { indicators.append(("vp-freeze", "VP frozen")) }
        if layer.isLocked { indicators.append(("lock", "Locked")) }
        if !layer.isPlottable { indicators.append(("no-plot", "No plot")) }
        let indicatorsWidth = Float(indicators.count) * zones.indicatorWidth
        for (i, indicator) in indicators.enumerated() {
            let cx = propsMinX - indicatorsWidth
                + zones.indicatorWidth * (Float(i) + 0.5)
            PanelWidgets.drawIcon(
                indicator.icon, drawList: drawList,
                center: ImVec2(x: cx, y: centerY),
                size: iconSize * 0.85, color: theme.textDim)
        }

        let nameColor: ImU32
        if isActive {
            nameColor = igGetColorU32_Vec4(theme.brandGold)
        } else if !layer.isVisible {
            nameColor = igGetColorU32_Vec4(theme.textDim)
        } else {
            nameColor = textColor
        }
        let nameMaxWidth = max(
            0, propsMinX - indicatorsWidth - (rowMin.x + zones.nameStart) - 4)
        ImDrawListAddText(
            drawList,
            ImVec2(x: rowMin.x + zones.nameStart, y: textY),
            nameColor,
            fittedName(layer.name, maxWidth: nameMaxWidth),
            nil)
        PanelWidgets.drawIcon(
            "props", drawList: drawList,
            center: ImVec2(
                x: propsMinX + zones.propsWidth * 0.5, y: centerY),
            size: iconSize,
            color: hovered ? theme.rowHoverText : theme.textDim)

        if hovered && mouse.x < statusMaxX {
            ImGuiBeginTooltip()
            ImGuiTextV(isActive
                ? "Current layer"
                : "Double-click to make current")
            ImGuiEndTooltip()
        } else if hovered && mouse.x < eyeMaxX {
            ImGuiBeginTooltip()
            ImGuiTextV(layer.isVisible ? "Hide layer" : "Show layer")
            ImGuiEndTooltip()
        } else if hovered && mouse.x >= propsMinX {
            ImGuiBeginTooltip()
            ImGuiTextV("Edit properties")
            ImGuiEndTooltip()
        } else if hovered && !indicators.isEmpty
            && mouse.x >= propsMinX - indicatorsWidth {
            ImGuiBeginTooltip()
            ImGuiTextV(indicators.map(\.label).joined(separator: " · "))
            ImGuiEndTooltip()
        }

        if igBeginPopupContextItem(
            "##LayerRowCtx",
            Int32(ImGuiPopupFlags_MouseButtonRight.rawValue)) {
            // Right-clicking an unselected row selects it first, so
            // Set Current and Rename act on the row under the cursor.
            if !LayerManagerUI.selection.selected.contains(layer.handle) {
                LayerManagerUI.selection.click(
                    handle: layer.handle,
                    in: LayerManagerUI.visibleOrder,
                    ctrl: false, shift: false)
            }
            renderRowContextMenu(
                engine: engine, document: document, layer: layer)
            ImGuiEndPopup()
        }
    }

    /// Eye click: toggles the whole selection in one undo step when the
    /// row belongs to a multi-selection, else the single layer.
    private static func toggleRowVisibility(
        document doc: CADDocument, layer: Layer
    ) {
        let picked = LayerManagerUI.selection
        guard picked.selected.contains(layer.handle),
              picked.count > 1 else {
            doc.setLayerVisible(layer.handle, visible: !layer.isVisible)
            return
        }
        let target = LayerManagerUI.targetHandles(for: doc)
        let handles: [UUID]
        var skippedNote = ""
        if layer.isVisible {
            let part = LayerSelectionModel.partitionExcludingCurrent(
                target.handles, current: doc.activeLayerID)
            handles = part.targets
            if part.skippedCurrent,
               let current = doc.activeLayerID,
               let name = doc.layer(for: current)?.name {
                skippedNote = " · skipped current '\(name)'"
            }
        } else {
            handles = target.handles
        }
        guard !handles.isEmpty else {
            LayerManagerUI.notice =
                "Bulk visibility: only the current layer selected."
            return
        }
        switch LayerTransactionService().setVisibleBulk(
            in: doc, handles: handles, visible: !layer.isVisible) {
        case .success(let n):
            LayerManagerUI.notice =
                "Bulk visibility: \(n) layers\(skippedNote)."
        case .failure(let error):
            LayerManagerUI.notice = "Bulk visibility: \(error.description)"
        }
    }

    /// Right-click menu for a layer row: Set Current, Rename, the
    /// shared selection commands, bulk toggles, and bulk delete.
    private static func renderRowContextMenu(
        engine: PhrostEngine, document doc: CADDocument, layer: Layer
    ) {
        if igMenuItem_Bool("Set Current", nil, false, true) {
            doc.activeLayerID = layer.handle
            LayerManagerUI.notice = "Current layer: '\(layer.name)'."
        }
        if igMenuItem_Bool("Rename (F2)", nil, false, true) {
            _editingLayerHandle = layer.handle
            _editingDocumentID = ObjectIdentifier(doc)
            _editingLayerNameBuf = []
        }
        ImGuiSeparator()
        LayerManagerUI.renderSelectionMenu(document: doc)
        ImGuiSeparator()
        let service = LayerTransactionService()
        if igMenuItem_Bool("On", nil, false, true) {
            LayerManagerUI.applyTarget(doc, "Bulk On") {
                service.setVisibleBulk(in: doc, handles: $0, visible: true)
            }
        }
        if igMenuItem_Bool("Off", nil, false, true) {
            LayerManagerUI.applyTargetExcludingCurrent(doc, "Bulk Off") {
                service.setVisibleBulk(in: doc, handles: $0, visible: false)
            }
        }
        if igMenuItem_Bool("Freeze", nil, false, true) {
            LayerManagerUI.applyTargetExcludingCurrent(doc, "Bulk Freeze") {
                service.setFrozenBulk(in: doc, handles: $0, frozen: true)
            }
        }
        if igMenuItem_Bool("Thaw", nil, false, true) {
            LayerManagerUI.applyTarget(doc, "Bulk Thaw") {
                service.setFrozenBulk(in: doc, handles: $0, frozen: false)
            }
        }
        if igMenuItem_Bool("Lock", nil, false, true) {
            LayerManagerUI.applyTarget(doc, "Bulk Lock") {
                service.setLockedBulk(in: doc, handles: $0, locked: true)
            }
        }
        if igMenuItem_Bool("Unlock", nil, false, true) {
            LayerManagerUI.applyTarget(doc, "Bulk Unlock") {
                service.setLockedBulk(in: doc, handles: $0, locked: false)
            }
        }
        ImGuiSeparator()
        if igMenuItem_Bool(
            "Delete Selected...", nil, false,
            !LayerManagerUI.selection.isEmpty) {
            ImGuiOpenPopup("##LPMDeleteConfirm", 0)
        }
    }

    private static func fittedName(_ name: String, maxWidth: Float) -> String {
        if ImGuiCalcTextSize(name, nil, false, -1).x <= maxWidth {
            return name
        }

        var fitted = name
        while !fitted.isEmpty {
            fitted.removeLast()
            let candidate = fitted + "..."
            if ImGuiCalcTextSize(candidate, nil, false, -1).x <= maxWidth {
                return candidate
            }
        }
        return ""
    }

    private static func renderRenameField(
        document: CADDocument,
        layer: Layer,
        rowHeight: Float
    ) {
        let bufSize = 128
        if _editingLayerNameBuf.count != bufSize {
            _editingLayerNameBuf = {
                var buffer = [CChar](repeating: 0, count: bufSize)
                let bytes = layer.name.utf8CString
                let length = min(bytes.count, bufSize - 1)
                for i in 0..<length {
                    buffer[i] = bytes[i]
                }
                return buffer
            }()
        }

        let policy = LayerPanelPolicy(frameHeight: ImGuiGetFrameHeight())
        ImGuiSetCursorPosX(policy.rowZones.nameStart - 4 * policy.scale)
        ImGuiPushItemWidth(-12)
        ImGuiSetKeyboardFocusHere(0)
        let submitted = _editingLayerNameBuf.withUnsafeMutableBufferPointer {
            buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            return igInputText(
                "##LayerRename",
                base,
                bufSize,
                Int32(ImGuiInputTextFlags_EnterReturnsTrue.rawValue)
                    | Int32(ImGuiInputTextFlags_AutoSelectAll.rawValue),
                { _ in 0 },
                nil)
        }
        ImGuiPopItemWidth()

        if submitted {
            let newName = _editingLayerNameBuf.withUnsafeBufferPointer {
                pointer -> String in
                let bytes = UnsafeRawBufferPointer(pointer).prefix { $0 != 0 }
                return String(decoding: bytes, as: UTF8.self)
            }.trimmingCharacters(in: .whitespaces)

            if !newName.isEmpty && newName != layer.name {
                document.renameLayer(handle: layer.handle, name: newName)
            }
            _editingLayerHandle = nil
            _editingDocumentID = nil
            _editingLayerNameBuf = []
        } else if ImGuiIsKeyPressed(
            ImGuiKey(ImGuiKey_Escape.rawValue),
            false)
        {
            _editingLayerHandle = nil
            _editingDocumentID = nil
            _editingLayerNameBuf = []
        }

        let usedHeight = ImGuiGetItemRectMax().y - ImGuiGetItemRectMin().y
        if usedHeight < rowHeight {
            ImGuiDummy(ImVec2(x: 0, y: rowHeight - usedHeight))
        }
    }

    private static func renderColorPopup(
        document: CADDocument,
        layer: Layer,
        index: Int
    ) {
        if ImGuiBeginPopup("##LayerColorPopup\(layer.handle.uuidString)", 0) {
            var color: [Float] = [
                Float(layer.color.r) / 255,
                Float(layer.color.g) / 255,
                Float(layer.color.b) / 255,
            ]
            if igColorEdit3("##LayerColorEdit\(layer.handle.uuidString)", &color, 0) {
                document.setLayerColor(
                    layer.handle,
                    color: ColorRGBA(
                        r: UInt8(max(0, min(255, Int(color[0] * 255)))),
                        g: UInt8(max(0, min(255, Int(color[1] * 255)))),
                        b: UInt8(max(0, min(255, Int(color[2] * 255)))),
                        a: 255))
            }
            ImGuiEndPopup()
        }
    }

    private static func renderPropertiesPopup(
        document: CADDocument,
        layer: Layer,
        index: Int
    ) {
        if ImGuiBeginPopup("##LayerPropsPopup\(layer.handle.uuidString)", 0) {
            ImGuiTextV("Properties: \(layer.name)")
            ImGuiSeparator()

            var lineWeight = Float(layer.lineWeight)
            if igSliderFloat(
                "Line Weight",
                &lineWeight,
                0,
                2,
                "%.2f mm",
                0)
            {
                document.setLayerLineWeight(
                    layer.handle,
                    lineWeight: Double(lineWeight))
            }

            var opacity = Float(layer.opacity)
            if igSliderFloat("Opacity", &opacity, 0, 1, "%.2f", 0) {
                document.setLayerOpacity(
                    layer.handle,
                    opacity: Double(opacity))
            }

            let types = ["CONTINUOUS", "DASHED", "DOTTED", "DASHDOT"]
            var typeIndex = Int32(types.firstIndex(of: layer.lineType) ?? 0)
            if igCombo_Str(
                "Line Type",
                &typeIndex,
                "CONTINUOUS\0DASHED\0DOTTED\0DASHDOT\0\0",
                -1)
            {
                document.setLayerLineType(
                    layer.handle,
                    lineType: types[Int(typeIndex)])
            }

            ImGuiEndPopup()
        }
    }
}
