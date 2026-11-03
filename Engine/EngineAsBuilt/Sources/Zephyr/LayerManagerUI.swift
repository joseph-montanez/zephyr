import ZephyrCore
import Foundation
import ImGui

// MARK: - LayerManagerUI
//
// Layer Properties Manager presentation for the Layers panel. Owns the
// manager toolbar (bulk transactions), the filter/state/viewport scope
// strip, the pickers and dialogs (color, linetype, lineweight,
// transparency, plot style, description, merge, delete, walk, states),
// and the performance-safe scope computation every control shares.
//
// The classic per-row list keeps rendering in `LayerPanelUI`; this type
// supplies its scope (`scopedLayers`), the selected-viewport frozen
// markers (`vpMarker`), and the render cap (`renderRowLimit`). Panel
// search stays the single text scope: `LayerPanelUI` mirrors its search
// box into `searchText` each frame.

@MainActor
struct LayerManagerUI {
    // MARK: Scope state

    static var searchText: String = ""
    static var selectedViewportID: String? = nil
    static var activeFilterName: String? = nil
    static var activeStateName: String? = nil
    static var unreconciledOnly: Bool = false
    static var viewportFrozenOnly: Bool = false
    static var notice: String = ""

    /// Hard cap on rendered rows per layer group. The scope itself is
    /// uncapped (bulk edits hit every in-scope layer); only ImGui row
    /// submission is bounded.
    static let renderRowLimit = 500

    // MARK: Marker cache

    static var _lastVPFrozen: Set<UUID> = []
    static var _lastVPKey: String? = nil

    // MARK: Dialog drafts

    static var _colorRGB: [Float] = [1, 1, 1]
    static var _colorACI: Float = 7
    static var _linetypeIndex: Int32 = 0
    static var _lineweightIndex: Int32 = 6
    static var _transparency: Float = 0
    static var _plotStyleIndex: Int32 = 0
    static var _deleteEraseEntities: Bool = false
    static var _walk: LayerWalkSession? = nil
    static var _textBufs: [String: [CChar]] = [:]
    static var _textValues: [String: String] = [:]

    // MARK: Scope computation

    /// Layers passing the manager scope (filter, state, flags, search),
    /// in the shared sort order. Read-only. Refreshes the viewport
    /// marker cache as a side effect so row markers stay in sync.
    static func displayLayers(for doc: CADDocument) -> [Layer] {
        applyScopeFilters(doc.allLayers, for: doc)
    }

    /// Scope filters shared by the row list (display) and the bulk scope:
    /// named filter, state scope, and the unreconciled/viewport flags.
    /// Search text and sort apply on top. Refreshes the viewport marker
    /// cache as a side effect so row markers stay in sync.
    static func applyScopeFilters(_ layers: [Layer], for doc: CADDocument) -> [Layer] {
        var layers = layers

        if let name = activeFilterName,
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let key = name.trimmingCharacters(
                in: .whitespacesAndNewlines).uppercased()
            if let filter = doc.layerFilters[key] {
                layers = layers.filter { filter.matches($0) }
            } else {
                layers = []
            }
        }

        if let name = activeStateName,
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let key = name.trimmingCharacters(
                in: .whitespacesAndNewlines).uppercased()
            if let state = doc.layerStates[key] {
                let known = Set(state.entries.keys)
                layers = layers.filter {
                    known.contains($0.name.trimmingCharacters(
                        in: .whitespacesAndNewlines).uppercased())
                }
            } else {
                layers = []
            }
        }

        if unreconciledOnly {
            layers = layers.filter { !$0.isReconciled }
        }

        let vpKey = selectedViewportID?.trimmingCharacters(
            in: .whitespacesAndNewlines)
        let hasViewport = vpKey != nil && !(vpKey!.isEmpty)
        if viewportFrozenOnly {
            if hasViewport {
                layers = layers.filter {
                    doc.viewportLayerOverrides[vpKey!]?[
                        ViewportIdentity.layerKey($0.handle)]?.frozen == true
                }
            } else {
                layers = []
            }
        }

        if hasViewport {
            var frozen: Set<UUID> = []
            for layer in layers
                where doc.viewportLayerOverrides[vpKey!]?[
                    ViewportIdentity.layerKey(layer.handle)]?.frozen == true {
                frozen.insert(layer.handle)
            }
            _lastVPFrozen = frozen
            _lastVPKey = vpKey
        } else {
            _lastVPFrozen = []
            _lastVPKey = nil
        }
        return layers
    }

    static func scopedLayers(for doc: CADDocument) -> [Layer] {
        var layers = applyScopeFilters(doc.allLayers, for: doc)

        let search = searchText.trimmingCharacters(
            in: .whitespacesAndNewlines)
        if !search.isEmpty {
            layers = layers.filter {
                $0.name.localizedCaseInsensitiveContains(search)
            }
        }

        let settings = LayerSortSettings.load()
        let counts = settings.key == .used
            ? LayerSortPolicy.entityCounts(in: doc) : [:]
        let sorted = LayerSortPolicy.sorted(
            layers, entityCounts: counts, settings: settings)
        return sorted
    }

    /// Selected-viewport frozen marker for a row ("VP " or "").
    static func vpMarker(for handle: UUID) -> String {
        _lastVPFrozen.contains(handle) ? "VP " : ""
    }

    // MARK: Text-field helper

    static func resetTextField(id: String) {
        _textBufs.removeValue(forKey: id)
        _textValues.removeValue(forKey: id)
    }

    /// Single-line text input bound to a long-lived string value.
    /// Returns the current value.
    static func renderTextField(
        id: String, hint: String, initial: String, width: Float
    ) -> String {
        let bufSize = 128
        if _textBufs[id] == nil {
            var buffer = [CChar](repeating: 0, count: bufSize)
            let bytes = initial.utf8CString
            for i in 0..<min(bytes.count, bufSize - 1) { buffer[i] = bytes[i] }
            _textBufs[id] = buffer
            _textValues[id] = initial
        }
        var buf = _textBufs[id]!
        ImGuiSetNextItemWidth(width)
        if igInputTextWithHint(id, hint, &buf, bufSize, 0, nil, nil) {
            _textValues[id] = buf.withUnsafeBufferPointer { pointer in
                String(cString: pointer.baseAddress!)
            }
        }
        _textBufs[id] = buf
        return _textValues[id] ?? ""
    }

    static func comboItems(_ items: [String]) -> String {
        items.joined(separator: "\0") + "\0\0"
    }

    // MARK: Bulk helper

    static func applyScoped(
        _ doc: CADDocument, _ label: String,
        _ op: ([UUID]) -> Result<Int, LayerEditError>
    ) {
        let handles = scopedLayers(for: doc).map(\.handle)
        guard !handles.isEmpty else {
            notice = "\(label): no layers in scope."
            return
        }
        switch op(handles) {
        case .success(let n):
            notice = "\(label): \(n) layer\(n == 1 ? "" : "s")."
        case .failure(let error):
            notice = "\(label): \(error.description)"
        }
    }

    static func scopedNames(for doc: CADDocument) -> [String] {
        scopedLayers(for: doc).map(\.name)
    }

    // MARK: Strips

    /// Manager toolbar, scope strip, and summary. Call after the sort
    /// strip; refreshes the scope (and marker cache) for the row list.
    @discardableResult
    static func renderStrips(
        engine: PhrostEngine, document doc: CADDocument
    ) -> [Layer] {
        let scoped = scopedLayers(for: doc)
        renderToolbar(engine: engine, document: doc)
        renderScopeStrip(engine: engine, document: doc)
        renderSummary(engine: engine, document: doc, scopedCount: scoped.count)
        renderDialogs(engine: engine, document: doc)
        return scoped
    }

    private static func renderToolbar(
        engine: PhrostEngine, document doc: CADDocument
    ) {
        let service = LayerTransactionService()
        ImGuiSetCursorPosX(6)
        if igSmallButton("On##LPMOn") {
            applyScoped(doc, "Bulk On") {
                service.setVisibleBulk(in: doc, handles: $0, visible: true)
            }
        }
        ImGuiSameLine(0, 4)
        if igSmallButton("Off##LPMOff") {
            applyScoped(doc, "Bulk Off") {
                service.setVisibleBulk(in: doc, handles: $0, visible: false)
            }
        }
        ImGuiSameLine(0, 4)
        if igSmallButton("Freeze##LPMFreeze") {
            applyScoped(doc, "Bulk Freeze") {
                service.setFrozenBulk(in: doc, handles: $0, frozen: true)
            }
        }
        ImGuiSameLine(0, 4)
        if igSmallButton("Thaw##LPMThaw") {
            applyScoped(doc, "Bulk Thaw") {
                service.setFrozenBulk(in: doc, handles: $0, frozen: false)
            }
        }
        ImGuiSameLine(0, 4)
        if igSmallButton("Lock##LPMLock") {
            applyScoped(doc, "Bulk Lock") {
                service.setLockedBulk(in: doc, handles: $0, locked: true)
            }
        }
        ImGuiSameLine(0, 4)
        if igSmallButton("Unlock##LPMUnlock") {
            applyScoped(doc, "Bulk Unlock") {
                service.setLockedBulk(in: doc, handles: $0, locked: false)
            }
        }
        ImGuiSetCursorPosX(6)
        if igSmallButton("Plot##LPMPlot") {
            applyScoped(doc, "Bulk Plot") {
                service.setPlottableBulk(in: doc, handles: $0, plottable: true)
            }
        }
        ImGuiSameLine(0, 4)
        if igSmallButton("NoPlot##LPMNoPlot") {
            applyScoped(doc, "Bulk NoPlot") {
                service.setPlottableBulk(in: doc, handles: $0, plottable: false)
            }
        }
        ImGuiSameLine(0, 4)
        if igSmallButton("VP Frz##LPMVPFrz") {
            if let vp = selectedViewportID, !vp.isEmpty {
                let handles = scopedLayers(for: doc).map(\.handle)
                switch service.setViewportFrozenBulk(
                    in: doc, viewportID: vp,
                    handles: handles, frozen: true) {
                case .success(let n):
                    notice = "VP Freeze: \(n) layers."
                case .failure(let error):
                    notice = "VP Freeze: \(error.description)"
                }
            } else {
                notice = "VP Freeze: pick a viewport first."
            }
        }
        ImGuiSameLine(0, 4)
        if igSmallButton("VP Thaw##LPMVPThaw") {
            if let vp = selectedViewportID, !vp.isEmpty {
                let handles = scopedLayers(for: doc).map(\.handle)
                switch service.setViewportFrozenBulk(
                    in: doc, viewportID: vp,
                    handles: handles, frozen: false) {
                case .success(let n):
                    notice = "VP Thaw: \(n) layers."
                case .failure(let error):
                    notice = "VP Thaw: \(error.description)"
                }
            } else {
                notice = "VP Thaw: pick a viewport first."
            }
        }
        ImGuiSetCursorPosX(6)
        if igSmallButton("Color...##LPMColor") { ImGuiOpenPopup("##LPMColorDlg", 0) }
        ImGuiSameLine(0, 4)
        if igSmallButton("Linetype...##LPMLinetype") { ImGuiOpenPopup("##LPMLinetypeDlg", 0) }
        ImGuiSameLine(0, 4)
        if igSmallButton("Weight...##LPMWeight") { ImGuiOpenPopup("##LPMWeightDlg", 0) }
        ImGuiSameLine(0, 4)
        if igSmallButton("Transp...##LPMTransp") { ImGuiOpenPopup("##LPMTranspDlg", 0) }
        ImGuiSetCursorPosX(6)
        if igSmallButton("PlotStyle...##LPMPlotStyle") { ImGuiOpenPopup("##LPMPlotStyleDlg", 0) }
        ImGuiSameLine(0, 4)
        if igSmallButton("Descr...##LPMDescr") { ImGuiOpenPopup("##LPMDescrDlg", 0) }
        ImGuiSameLine(0, 4)
        if igSmallButton("Merge...##LPMMerge") {
            resetTextField(id: "##LPMMergeTarget")
            ImGuiOpenPopup("##LPMMergeDlg", 0)
        }
        ImGuiSameLine(0, 4)
        if igSmallButton("Delete...##LPMDelete") {
            resetTextField(id: "##LPMDeleteName")
            ImGuiOpenPopup("##LPMDeleteDlg", 0)
        }
        ImGuiSetCursorPosX(6)
        if igSmallButton("Walk...##LPMWalk") { openWalk(for: doc) }
        ImGuiSameLine(0, 4)
        if igSmallButton("States...##LPMStates") {
            resetTextField(id: "##LPMStateName")
            ImGuiOpenPopup("##LPMStatesDlg", 0)
        }
        ImGuiSameLine(0, 4)
        if igSmallButton("LAYERP##LPMLayerP") {
            if LayerTransactionService().restoreLayerPrevious(in: doc) {
                notice = "LAYERP: restored previous layer settings."
            } else {
                notice = "LAYERP: nothing to restore."
            }
        }
        ImGuiSameLine(0, 4)
        if igSmallButton("Reconcile##LPMReconcile") {
            let n = LayerTransactionService().reconcileAllLayers(in: doc)
            notice = "Reconciled \(n) layers."
        }
    }

    private static func renderScopeStrip(
        engine: PhrostEngine, document doc: CADDocument
    ) {
        ImGuiSetCursorPosX(6)
        let vpLabel = "VP: \(selectedViewportID ?? "none")"
        if igSmallButton("\(vpLabel) ##LPMViewportBtn") {
            ImGuiOpenPopup("##LPMViewportMenu", 0)
        }
        if ImGuiBeginPopup("##LPMViewportMenu", 0) {
            if igMenuItem_Bool("(none)", nil, selectedViewportID == nil, true) {
                selectedViewportID = nil
            }
            for key in doc.viewportLayerOverrides.keys.sorted() {
                if igMenuItem_Bool(key, nil, selectedViewportID == key, true) {
                    selectedViewportID = key
                }
            }
            ImGuiEndPopup()
        }
        ImGuiSameLine(0, 4)
        let filterLabel = "Filter: \(activeFilterName ?? "all")"
        if igSmallButton("\(filterLabel) ##LPMFilterBtn") {
            ImGuiOpenPopup("##LPMFilterMenu", 0)
        }
        if ImGuiBeginPopup("##LPMFilterMenu", 0) {
            if igMenuItem_Bool("(all)", nil, activeFilterName == nil, true) {
                activeFilterName = nil
            }
            for name in doc.layerFilters.values.map(\.name).sorted(
                by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }) {
                if igMenuItem_Bool(name, nil, activeFilterName == name, true) {
                    activeFilterName = name
                }
            }
            ImGuiEndPopup()
        }
        ImGuiSameLine(0, 4)
        let stateLabel = "State: \(activeStateName ?? "all")"
        if igSmallButton("\(stateLabel) ##LPMStateBtn") {
            ImGuiOpenPopup("##LPMStateMenu", 0)
        }
        if ImGuiBeginPopup("##LPMStateMenu", 0) {
            if igMenuItem_Bool("(all)", nil, activeStateName == nil, true) {
                activeStateName = nil
            }
            for name in doc.layerStates.values.map(\.name).sorted(
                by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }) {
                if igMenuItem_Bool(name, nil, activeStateName == name, true) {
                    activeStateName = name
                }
            }
            ImGuiEndPopup()
        }
        ImGuiSetCursorPosX(6)
        var unrec = unreconciledOnly
        if ImGuiCheckbox("Unreconciled only", &unrec) {
            unreconciledOnly = unrec
        }
        ImGuiSameLine(0, 8)
        var vpf = viewportFrozenOnly
        if ImGuiCheckbox("VP-frozen only", &vpf) {
            viewportFrozenOnly = vpf
        }
    }

    private static func renderSummary(
        engine: PhrostEngine, document doc: CADDocument, scopedCount: Int
    ) {
        ImGuiSetCursorPosX(6)
        ImGuiPushStyleColor(
            Int32(ImGuiCol_Text.rawValue), engine.ui.theme.textDim)
        var summary = LayerManagerModel.headerSummary(
            in: doc, viewportID: selectedViewportID)
        summary += " · Scope: \(scopedCount)"
        if scopedCount > renderRowLimit {
            summary += " (first \(renderRowLimit) shown)"
        }
        if !notice.isEmpty {
            summary += " · \(notice)"
        }
        ImGuiTextV(summary)
        ImGuiPopStyleColor(1)
    }

    // MARK: Dialogs

    private static func renderDialogs(
        engine: PhrostEngine, document doc: CADDocument
    ) {
        renderColorDialog(document: doc)
        renderLinetypeDialog(document: doc)
        renderLineweightDialog(document: doc)
        renderTransparencyDialog(document: doc)
        renderPlotStyleDialog(document: doc)
        renderDescriptionDialog(document: doc)
        renderMergeDialog(document: doc)
        renderDeleteDialog(document: doc)
        renderWalkDialog(document: doc)
        renderStatesDialog(document: doc)
    }

    private static func renderColorDialog(document doc: CADDocument) {
        if ImGuiBeginPopup("##LPMColorDlg", 0) {
            ImGuiTextV("Bulk color (\(scopedLayers(for: doc).count) in scope)")
            ImGuiSeparator()
            var rgb = _colorRGB
            if igColorEdit3("##LPMColorEdit", &rgb, 0) {
                _colorRGB = rgb
            }
            var aci = _colorACI
            if igSliderFloat("ACI", &aci, 1, 255, "%.0f", 0) {
                _colorACI = aci
            }
            if igSmallButton("Apply ACI##LPMColorACI") {
                let index = Int(_colorACI)
                let color = DXFColorTable.aciToRGBA(Int32(index), color24: -1)
                applyScoped(doc, "Bulk color") {
                    LayerTransactionService().setColorBulk(
                        in: doc, handles: $0, color: color,
                        source: .aci(index))
                }
            }
            ImGuiSameLine(0, 4)
            if igSmallButton("Apply RGB##LPMColorRGB") {
                let color = ColorRGBA(
                    r: UInt8(max(0, min(255, Int(_colorRGB[0] * 255)))),
                    g: UInt8(max(0, min(255, Int(_colorRGB[1] * 255)))),
                    b: UInt8(max(0, min(255, Int(_colorRGB[2] * 255)))),
                    a: 255)
                applyScoped(doc, "Bulk color") {
                    LayerTransactionService().setColorBulk(
                        in: doc, handles: $0, color: color)
                }
            }
            ImGuiEndPopup()
        }
    }

    private static func renderLinetypeDialog(document doc: CADDocument) {
        if ImGuiBeginPopup("##LPMLinetypeDlg", 0) {
            ImGuiTextV("Bulk linetype (\(scopedLayers(for: doc).count) in scope)")
            ImGuiSeparator()
            let names = LayerManagerModel.availableLinetypes(in: doc)
            var index = min(_linetypeIndex, Int32(max(0, names.count - 1)))
            ImGuiSetNextItemWidth(220)
            if igCombo_Str("##LPMLinetypeCombo", &index, comboItems(names), -1) {
                _linetypeIndex = index
            }
            if igSmallButton("Apply##LPMLinetypeApply"), !names.isEmpty {
                let value = names[Int(min(index, Int32(names.count - 1)))]
                applyScoped(doc, "Bulk linetype") {
                    LayerTransactionService().setLineTypeBulk(
                        in: doc, handles: $0, lineType: value)
                }
            }
            ImGuiEndPopup()
        }
    }

    private static func renderLineweightDialog(document doc: CADDocument) {
        if ImGuiBeginPopup("##LPMWeightDlg", 0) {
            ImGuiTextV("Bulk lineweight (\(scopedLayers(for: doc).count) in scope)")
            ImGuiSeparator()
            let names = Layer.fixedLineWeightsMM.map {
                String(format: "%.2f mm", $0)
            }
            var index = min(_lineweightIndex, Int32(names.count - 1))
            ImGuiSetNextItemWidth(220)
            if igCombo_Str("##LPMWeightCombo", &index, comboItems(names), -1) {
                _lineweightIndex = index
            }
            if igSmallButton("Apply##LPMWeightApply") {
                let value = Layer.fixedLineWeightsMM[
                    Int(min(index, Int32(names.count - 1)))]
                applyScoped(doc, "Bulk lineweight") {
                    LayerTransactionService().setLineWeightBulk(
                        in: doc, handles: $0, lineWeight: value)
                }
            }
            ImGuiEndPopup()
        }
    }

    private static func renderTransparencyDialog(document doc: CADDocument) {
        if ImGuiBeginPopup("##LPMTranspDlg", 0) {
            ImGuiTextV("Bulk transparency (\(scopedLayers(for: doc).count) in scope)")
            ImGuiSeparator()
            var value = _transparency
            ImGuiSetNextItemWidth(220)
            if igSliderFloat("Percent", &value, 0, 90, "%.0f", 0) {
                _transparency = value
            }
            if igSmallButton("Apply##LPMTranspApply") {
                let percent = Int(_transparency)
                applyScoped(doc, "Bulk transparency") {
                    LayerTransactionService().setTransparencyBulk(
                        in: doc, handles: $0, transparency: percent)
                }
            }
            ImGuiEndPopup()
        }
    }

    private static func renderPlotStyleDialog(document doc: CADDocument) {
        if ImGuiBeginPopup("##LPMPlotStyleDlg", 0) {
            ImGuiTextV("Bulk plot style (\(scopedLayers(for: doc).count) in scope)")
            ImGuiSeparator()
            let names = LayerManagerModel.availablePlotStyles(in: doc)
            var index = min(_plotStyleIndex, Int32(max(0, names.count - 1)))
            ImGuiSetNextItemWidth(220)
            if igCombo_Str("##LPMPlotStyleCombo", &index, comboItems(names), -1) {
                _plotStyleIndex = index
            }
            if igSmallButton("Apply##LPMPlotStyleApply"), !names.isEmpty {
                let value = names[Int(min(index, Int32(names.count - 1)))]
                applyScoped(doc, "Bulk plot style") {
                    LayerTransactionService().setPlotStyleBulk(
                        in: doc, handles: $0, plotStyleName: value)
                }
            }
            ImGuiEndPopup()
        }
    }

    private static func renderDescriptionDialog(document doc: CADDocument) {
        if ImGuiBeginPopup("##LPMDescrDlg", 0) {
            ImGuiTextV("Bulk description (\(scopedLayers(for: doc).count) in scope)")
            ImGuiSeparator()
            let value = renderTextField(
                id: "##LPMDescrText", hint: "Description…",
                initial: "", width: 260)
            if igSmallButton("Apply##LPMDescrApply") {
                applyScoped(doc, "Bulk description") {
                    LayerTransactionService().setDescriptionBulk(
                        in: doc, handles: $0, description: value)
                }
            }
            ImGuiEndPopup()
        }
    }

    private static func renderMergeDialog(document doc: CADDocument) {
        if ImGuiBeginPopup("##LPMMergeDlg", 0) {
            let names = scopedNames(for: doc)
            ImGuiTextV("Merge \(names.count) in-scope layers")
            ImGuiSeparator()
            let target = renderTextField(
                id: "##LPMMergeTarget", hint: "Target layer…",
                initial: "", width: 220)
            if igSmallButton("Merge listed into target##LPMMergeApply") {
                let sources = names.filter {
                    $0.caseInsensitiveCompare(target) != .orderedSame
                }
                switch LayerTransactionService().mergeLayers(
                    in: doc, from: sources, into: target) {
                case .success(let outcome):
                    notice = "Merged \(outcome.deleted) layers into "
                        + "'\(outcome.target.name)' (\(outcome.moved) entities)."
                    resetTextField(id: "##LPMMergeTarget")
                case .failure(let error):
                    notice = "Merge: \(error.description)"
                }
            }
            ImGuiEndPopup()
        }
    }

    private static func renderDeleteDialog(document doc: CADDocument) {
        if ImGuiBeginPopup("##LPMDeleteDlg", 0) {
            ImGuiTextV("Delete a layer")
            ImGuiSeparator()
            let name = renderTextField(
                id: "##LPMDeleteName", hint: "Layer name…",
                initial: "", width: 220)
            var erase = _deleteEraseEntities
            if ImGuiCheckbox("Erase its entities too", &erase) {
                _deleteEraseEntities = erase
            }
            if igSmallButton("Delete##LPMDeleteApply") {
                if _deleteEraseEntities {
                    switch LayerTransactionService()
                        .deleteLayerAndEntities(in: doc, named: name) {
                    case .success(let count):
                        notice = "Deleted '\(name)' (\(count) entities)."
                        resetTextField(id: "##LPMDeleteName")
                    case .failure(let error):
                        notice = "Delete: \(error.description)"
                    }
                } else if let layer = doc.findLayer(named: name) {
                    switch LayerTransactionService()
                        .deleteLayer(in: doc, handle: layer.handle) {
                    case .success:
                        notice = "Deleted '\(name)'."
                        resetTextField(id: "##LPMDeleteName")
                    case .failure(let error):
                        notice = "Delete: \(error.description)"
                    }
                } else {
                    notice = "Delete: Layer '\(name)' not found."
                }
            }
            ImGuiEndPopup()
        }
    }

    // MARK: Walk

    static func openWalk(for doc: CADDocument) {
        closeWalk(for: doc)
        let layers = scopedLayers(for: doc)
        guard !layers.isEmpty else {
            notice = "Walk: no layers in scope."
            return
        }
        _walk = LayerWalkSession(layers: layers)
        isolateWalkCurrent(for: doc)
        ImGuiOpenPopup("##LPMWalkDlg", 0)
    }

    static func closeWalk(for doc: CADDocument) {
        if _walk != nil {
            _ = doc.unisolateLayers()
            _walk = nil
        }
    }

    static func isolateWalkCurrent(for doc: CADDocument) {
        guard let current = _walk?.currentHandle else { return }
        _ = doc.unisolateLayers()
        doc.isolateLayers(keeping: [current])
    }

    private static func renderWalkDialog(document doc: CADDocument) {
        if ImGuiBeginPopup("##LPMWalkDlg", 0) {
            ImGuiTextV(_walk?.positionLabel ?? "Walk")
            ImGuiSeparator()
            if igSmallButton("< Prev##LPMWalkPrev") {
                if _walk?.previous() == true {
                    isolateWalkCurrent(for: doc)
                }
            }
            ImGuiSameLine(0, 4)
            if igSmallButton("Next >##LPMWalkNext") {
                if _walk?.next() == true {
                    isolateWalkCurrent(for: doc)
                }
            }
            ImGuiSameLine(0, 4)
            if igSmallButton("Close##LPMWalkClose") {
                closeWalk(for: doc)
                notice = "Walk closed; layers restored."
                ImGuiCloseCurrentPopup()
            }
            ImGuiEndPopup()
        }
    }

    // MARK: States

    private static func renderStatesDialog(document doc: CADDocument) {
        if ImGuiBeginPopup("##LPMStatesDlg", 0) {
            ImGuiTextV("Layer states")
            ImGuiSeparator()
            let name = renderTextField(
                id: "##LPMStateName", hint: "State name…",
                initial: "", width: 200)
            if igSmallButton("Save current##LPMStateSave"), !name.isEmpty {
                switch LayerTransactionService().saveLayerState(
                    in: doc, name: name) {
                case .success(let state):
                    notice = "Saved state '\(state.name)'."
                    resetTextField(id: "##LPMStateName")
                case .failure(let error):
                    notice = "Save state: \(error.description)"
                }
            }
            ImGuiSeparator()
            let service = LayerTransactionService()
            let names = service.layerStateNames(in: doc)
            if names.isEmpty {
                ImGuiTextV("(no saved states)")
            }
            for (index, stateName) in names.enumerated() {
                ImGuiPushID(Int32(index))
                ImGuiTextV(stateName)
                ImGuiSameLine(0, 8)
                if igSmallButton("Restore##LPMStateRestore") {
                    switch service.restoreLayerState(
                        in: doc, named: stateName) {
                    case .success(let report):
                        notice = "Restored '\(stateName)': "
                            + "\(report.applied) applied."
                    case .failure(let error):
                        notice = "Restore: \(error.description)"
                    }
                }
                ImGuiSameLine(0, 4)
                if igSmallButton("Delete##LPMStateDelete") {
                    switch service.deleteLayerState(
                        in: doc, named: stateName) {
                    case .success:
                        notice = "Deleted state '\(stateName)'."
                    case .failure(let error):
                        notice = "Delete state: \(error.description)"
                    }
                }
                ImGuiPopID()
            }
            ImGuiEndPopup()
        }
    }
}
