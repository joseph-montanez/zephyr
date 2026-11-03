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
    static var _isDocked: Bool = false
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

    static func render(engine: PhrostEngine, document: CADDocument) {
        let doc = document
        let layers = LayerManagerUI.displayLayers(for: doc)
        let fontSize = ImGuiGetFontSize()
        let panelW: Float = fontSize * 18
        let layerRowH = ImGuiGetFrameHeightWithSpacing()
        let minRows = max(Float(layers.count), 3)
        let panelH = max(100, layerRowH * minRows + 60)

        ImGuiSetNextWindowPos(
            ImVec2(x: 4, y: AppLayout.belowChromeY + 4),
            Int32(ImGuiCond_FirstUseEver.rawValue),
            ImVec2(x: 0, y: 0))
        ImGuiSetNextWindowSize(
            ImVec2(x: panelW, y: max(panelH, 80)),
            Int32(ImGuiCond_FirstUseEver.rawValue))

        let wasDocked = _isDocked
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
        _isDocked = ImGuiIsWindowDocked()
        AppLayout.reportCurrentDockedPanel(engine: engine)

        if entered {

            if !wasDocked && !opened {
                engine.ui.layersPanelVisible = false
            } else {
                renderHeader(engine: engine, document: doc, isDocked: wasDocked)
                renderSortStrip(engine: engine)
                LayerManagerUI.searchText = _searchText
                _ = LayerManagerUI.renderStrips(engine: engine, document: doc)

                if layers.isEmpty {
                    ImGuiSetCursorPosX(10)
                    ImGuiTextV("(no layers)")
                } else {
                    // Host layers first; xref-dependent layers grouped
                    // under a collapsible header per owning xref.
                    // Direct iteration — avoid ImGuiListClipper due to arm64e C struct ABI mismatch.
                    // Both lists follow the shared sort settings
                    // (LAYERSORT command / sort strip) and name search.
                    let settings = sortSettings()
                    let counts = settings.key == .used ? entityCounts(for: doc) : [:]
                    let search = _searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                    func visibleLayers(_ list: [Layer]) -> [Layer] {
                        let sorted = LayerSortPolicy.sorted(
                            list, entityCounts: counts, settings: settings)
                        guard !search.isEmpty else { return sorted }
                        return sorted.filter {
                            $0.name.localizedCaseInsensitiveContains(search)
                        }
                    }
                    let hostLayers = visibleLayers(
                        layers.filter { !doc.isXrefDependentLayer($0) })
                    for index in 0..<min(hostLayers.count, LayerManagerUI.renderRowLimit) {
                        renderLayerRow(
                            engine: engine,
                            document: doc,
                            layer: hostLayers[index],
                            index: index,
                            rowHeight: layerRowH,
                            fontSize: fontSize)
                    }
                    let dependent = layers.filter { doc.isXrefDependentLayer($0) }
                    let owners = Array(Set(dependent.compactMap {
                        doc.xrefOwnerBlockName(forLayerName: $0.name)
                    })).sorted()
                    var rowIndex = hostLayers.count
                    for owner in owners {
                        let group = visibleLayers(dependent.filter {
                            doc.xrefOwnerBlockName(forLayerName: $0.name) == owner
                        })
                        if group.isEmpty { continue }
                        ImGuiSetCursorPosX(6)
                        ImGuiPushStyleColor(
                            Int32(ImGuiCol_Text.rawValue), engine.ui.theme.textDim)
                        ImGuiTextV("— Xref: \(owner) (\(group.count)) —")
                        ImGuiPopStyleColor(1)
                        if true {
                            for layer in group.prefix(LayerManagerUI.renderRowLimit) {
                                renderLayerRow(
                                    engine: engine,
                                    document: doc,
                                    layer: layer,
                                    index: 10_000 + rowIndex,
                                    rowHeight: layerRowH,
                                    fontSize: fontSize)
                                rowIndex += 1
                            }
                        }
                    }
                }
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

        ImGuiSetCursorPos(ImVec2(x: max(0, headerWidth - 30), y: headerY))
        ImGuiPushStyleColor(
            Int32(ImGuiCol_Button.rawValue),
            engine.ui.theme.panelBg)
        ImGuiPushStyleColor(
            Int32(ImGuiCol_ButtonHovered.rawValue),
            engine.ui.theme.panelBg)
        ImGuiPushStyleColor(
            Int32(ImGuiCol_ButtonActive.rawValue),
            engine.ui.theme.panelBg)
        ImGuiPushStyleColor(
            Int32(ImGuiCol_Text.rawValue),
            engine.ui.theme.textDim)
        if igSmallButton("+") {
            document.addLayer(Layer(name: document.uniqueLayerName()))
        }
        ImGuiPopStyleColor(4)

        if ImGuiIsItemHovered(0) {
            ImGuiBeginTooltip()
            ImGuiTextV("Add a new layer")
            ImGuiEndTooltip()
        }

        ImGuiSetCursorPos(ImVec2(
            x: 0,
            y: headerY + ImGuiGetFrameHeight() + 4))
    }

    /// Sort controls shared with the LAYERSORT command: clickable
    /// On/Color/Name headers, a Sort menu with every key, and a name
    /// search field. Reads settings fresh each frame, so commands
    /// take effect immediately here.
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
        func arrow(_ key: LayerSortKey) -> String {
            guard settings.key == key else { return "" }
            return settings.ascending ? " \u{25B2}" : " \u{25BC}"
        }
        ImGuiSetCursorPosX(6)
        if igSmallButton("On\(arrow(.onOff))##LayerSortOn") {
            applySort(settings.selecting(.onOff))
        }
        ImGuiSameLine(0, 4)
        if igSmallButton("Color\(arrow(.color))##LayerSortColor") {
            applySort(settings.selecting(.color))
        }
        ImGuiSameLine(0, 4)
        if igSmallButton("Name\(arrow(.name))##LayerSortName") {
            applySort(settings.selecting(.name))
        }
        ImGuiSameLine(0, 4)
        if igSmallButton("Sort: \(settings.key.displayName)\(arrow(settings.key)) \u{25BE}##LayerSortMenuBtn") {
            ImGuiOpenPopup("##LayerSortMenu", 0)
        }
        if ImGuiBeginPopup("##LayerSortMenu", 0) {
            for key in LayerSortKey.allCases {
                let marker = settings.key == key ? "\u{2713} " : "  "
                if igMenuItem_Bool("\(marker)\(key.displayName)", nil, false, true) {
                    applySort(settings.selecting(key))
                }
            }
            ImGuiSeparator()
            if igMenuItem_Bool(settings.ascending ? "Descending" : "Ascending", nil, false, true) {
                applySort(LayerSortSettings(key: settings.key, ascending: !settings.ascending))
            }
            ImGuiEndPopup()
        }

        let bufSize = 128
        if _searchBuf.count != bufSize {
            var buffer = [CChar](repeating: 0, count: bufSize)
            let bytes = _searchText.utf8CString
            for i in 0..<min(bytes.count, bufSize - 1) { buffer[i] = bytes[i] }
            _searchBuf = buffer
        }
        ImGuiSetCursorPosX(6)
        ImGuiSetNextItemWidth(max(60, ImGuiGetContentRegionAvail().x - 12))
        if igInputTextWithHint("##LayerSearch", "Filter layers…",
                               &_searchBuf, bufSize, 0, nil, nil) {
            _searchText = _searchBuf.withUnsafeBufferPointer { pointer in String(cString: pointer.baseAddress!) }
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
            isActive,
            Int32(ImGuiSelectableFlags_AllowDoubleClick.rawValue),
            ImVec2(x: ImGuiGetContentRegionAvail().x, y: rowHeight))
        ImGuiPopStyleColor(3)

        let rowMin = ImGuiGetItemRectMin()
        let rowMax = ImGuiGetItemRectMax()
        let hovered = ImGuiIsItemHovered(0)
        let mouse = ImGuiGetMousePos()
        let eyeMaxX = rowMin.x + 34
        let swatchMaxX = rowMin.x + 52
        let propsMinX = rowMax.x - 34

        if clicked {
            if mouse.x < eyeMaxX {
                document.setLayerVisible(
                    layer.handle,
                    visible: !layer.isVisible)
            } else if mouse.x < swatchMaxX {
                ImGuiOpenPopup("##LayerColorPopup\(layer.handle.uuidString)", 0)
            } else if mouse.x >= propsMinX {
                ImGuiOpenPopup("##LayerPropsPopup\(layer.handle.uuidString)", 0)
            } else {
                document.activeLayerID = layer.handle
            }
        }

        if hovered
            && mouse.x >= swatchMaxX
            && mouse.x < propsMinX
            && ImGuiIsMouseDoubleClicked(
                ImGuiMouseButton(ImGuiMouseButton_Left.rawValue))
        {
            _editingLayerHandle = layer.handle
            _editingDocumentID = ObjectIdentifier(document)
            _editingLayerNameBuf = []
        }

        let textColor = igGetColorU32_Vec4(
            hovered
                ? engine.ui.theme.rowHoverText
                : engine.ui.theme.textPrimary)
        let drawList = ImGuiGetWindowDrawList()!
        let textY = rowMin.y + (rowHeight - fontSize) * 0.5

        ImDrawListAddText(
            drawList,
            ImVec2(x: rowMin.x + 12, y: textY),
            textColor,
            layer.isVisible ? "O" : "-",
            nil)

        let swatchColor = ImVec4(
            x: Float(layer.color.r) / 255,
            y: Float(layer.color.g) / 255,
            z: Float(layer.color.b) / 255,
            w: 1)
        ImDrawListAddRectFilled(
            drawList,
            ImVec2(x: rowMin.x + 36, y: rowMin.y + 5),
            ImVec2(x: rowMin.x + 46, y: rowMax.y - 5),
            igGetColorU32_Vec4(swatchColor),
            1,
            0)

        let props = "\(LayerManagerUI.vpMarker(for: layer.handle))="
        let propsWidth = ImGuiCalcTextSize(props, nil, false, -1).x
        let nameMaxWidth = max(0, propsMinX - (rowMin.x + 58) - 4)
        ImDrawListAddText(
            drawList,
            ImVec2(x: rowMin.x + 58, y: textY),
            textColor,
            fittedName(layer.name, maxWidth: nameMaxWidth),
            nil)
        ImDrawListAddText(
            drawList,
            ImVec2(x: rowMax.x - propsWidth - 12, y: textY),
            textColor,
            props,
            nil)

        if hovered && mouse.x < eyeMaxX {
            ImGuiBeginTooltip()
            ImGuiTextV(layer.isVisible ? "Hide layer" : "Show layer")
            ImGuiEndTooltip()
        } else if hovered && mouse.x >= propsMinX {
            ImGuiBeginTooltip()
            ImGuiTextV("Edit properties")
            ImGuiEndTooltip()
        }
    }

    private static func fittedName(_ name: String, maxWidth: Float) -> String {
        if ImGuiCalcTextSize(name, nil, false, -1).x <= maxWidth {
            return name
        }

        var fitted = name
        while !fitted.isEmpty {
            fitted.removeLast()
            let candidate = fitted + "\u{2026}"
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

        ImGuiSetCursorPosX(52)
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
