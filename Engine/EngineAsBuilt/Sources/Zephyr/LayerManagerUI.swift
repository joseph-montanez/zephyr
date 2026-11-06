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

    // MARK: Multi-selection state (AutoCAD-style)

    /// The panel's layer selection, independent of `activeLayerID`.
    /// Reset whenever the panel switches documents.
    static var selection = LayerSelectionModel()
    static var selectionDocID: ObjectIdentifier? = nil
    /// Full visible display order (uncapped), refreshed by the panel
    /// each frame before the toolbar renders. Selection commands and
    /// Shift-range math use this, never the 500-row render window.
    static var visibleOrder: [UUID] = []

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

    // MARK: Selection helpers

    /// Reset the selection when the panel switches documents and drop
    /// handles for layers that no longer exist (deleted/undone).
    static func ensureSelection(for doc: CADDocument) {
        if selectionDocID != ObjectIdentifier(doc) {
            selection = LayerSelectionModel()
            selectionDocID = ObjectIdentifier(doc)
        }
        selection.prune(valid: Set(doc.allLayers.map(\.handle)))
    }

    /// Bulk target: the selection when one exists, else the scope.
    /// Selection order follows the visible display order; out-of-scope
    /// picks are appended by name for determinism.
    static func targetHandles(
        for doc: CADDocument
    ) -> (handles: [UUID], isSelection: Bool) {
        ensureSelection(for: doc)
        let valid = Set(doc.allLayers.map(\.handle))
        let picked = selection.orderedSelection(in: visibleOrder) {
            doc.layer(for: $0)?.name
        }.filter { valid.contains($0) }
        if !picked.isEmpty { return (picked, true) }
        return (scopedLayers(for: doc).map(\.handle), false)
    }

    /// "(N selected)" vs "(N in scope)" for dialog titles.
    static func targetCountLabel(for doc: CADDocument) -> String {
        let target = targetHandles(for: doc)
        return target.isSelection
            ? "(\(target.handles.count) selected)"
            : "(\(target.handles.count) in scope)"
    }

    // MARK: Bulk helper

    static func applyTarget(
        _ doc: CADDocument, _ label: String,
        _ op: ([UUID]) -> Result<Int, LayerEditError>
    ) {
        let target = targetHandles(for: doc)
        guard !target.handles.isEmpty else {
            notice = "\(label): no layers "
                + (target.isSelection ? "selected." : "in scope.")
            return
        }
        switch op(target.handles) {
        case .success(let n):
            let scope = target.isSelection ? "selected" : "in scope"
            notice = "\(label): \(n) layer\(n == 1 ? "" : "s") (\(scope))."
        case .failure(let error):
            notice = "\(label): \(error.description)"
        }
    }

    /// Bulk Off/Freeze refuse the current layer all-or-nothing, so
    /// partition it out first and report the skip in the notice.
    static func applyTargetExcludingCurrent(
        _ doc: CADDocument, _ label: String,
        _ op: ([UUID]) -> Result<Int, LayerEditError>
    ) {
        let target = targetHandles(for: doc)
        let (handles, skippedCurrent) =
            LayerSelectionModel.partitionExcludingCurrent(
                target.handles, current: doc.activeLayerID)
        guard !handles.isEmpty else {
            notice = "\(label): only the current layer "
                + (target.isSelection ? "selected." : "in scope.")
            return
        }
        switch op(handles) {
        case .success(let n):
            let scope = target.isSelection ? "selected" : "in scope"
            notice = "\(label): \(n) layer\(n == 1 ? "" : "s") (\(scope))"
            if skippedCurrent,
               let current = doc.activeLayerID,
               let name = doc.layer(for: current)?.name {
                notice += " · skipped current '\(name)'."
            } else {
                notice += "."
            }
        case .failure(let error):
            notice = "\(label): \(error.description)"
        }
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

    // MARK: Select row + selection menu

    /// Set Current button plus the Select menu. Shared by the toolbar;
    /// the row context menu reuses `renderSelectionMenu` directly.
    private static func renderSelectRow(
        engine: PhrostEngine, document doc: CADDocument,
        policy: LayerPanelPolicy
    ) {
        let theme = engine.ui.theme
        let size = policy.toolbarButtonSize
        ImGuiSetCursorPosX(6)
        let single = selection.selected.count == 1
        if PanelWidgets.labelButton(
            id: "LPMSetCurrent", icon: "layer-cur", label: "Set Current",
            tooltip: single
                ? "Make the selected layer current"
                : "Select exactly one layer (or double-click a row)",
            theme: theme, size: size, enabled: single) {
            if let handle = selection.selected.first {
                doc.activeLayerID = handle
                if let name = doc.layer(for: handle)?.name {
                    notice = "Current layer: '\(name)'."
                } else {
                    notice = "Current layer set."
                }
            }
        }
        let selectWidth = PanelWidgets.labelButtonWidth(
            icon: "select", label: "Select", size: size, chevron: true)
        PanelWidgets.flow(itemWidth: selectWidth)
        if PanelWidgets.labelButton(
            id: "LPMSelectMenu", icon: "select", label: "Select",
            tooltip: "Layer selection commands",
            theme: theme, size: size, chevron: true) {
            ImGuiOpenPopup("##LPMSelectPopup", 0)
        }
        if ImGuiBeginPopup("##LPMSelectPopup", 0) {
            renderSelectionMenu(document: doc)
            ImGuiEndPopup()
        }
        if !selection.isEmpty {
            PanelWidgets.flow(itemWidth: 70, gap: 8)
            let textH = ImGuiCalcTextSize(
                "\(selection.count) selected", nil, false, -1).y
            ImGuiSetCursorPosY(
                igGetCursorPos().y + max(0, (size - textH) * 0.5))
            ImGuiTextV("\(selection.count) selected")
        }
    }

    /// Selection commands shared by the toolbar Select menu and the
    /// row right-click menu. Commands act on the visible display order
    /// and preserve out-of-scope picks; only Deselect All clears all.
    static func renderSelectionMenu(document doc: CADDocument) {
        let order = visibleOrder
        if igMenuItem_Bool("Select All", nil, false, !order.isEmpty) {
            selection.selectAll(in: order)
            notice = "Selected \(selection.count) layers."
        }
        if igMenuItem_Bool("Deselect All", nil, false, !selection.isEmpty) {
            selection.deselectAll()
            notice = "Selection cleared."
        }
        if igMenuItem_Bool(
            "Select All Except Current", nil, false, !order.isEmpty) {
            selection.selectAllExceptCurrent(
                in: order, current: doc.activeLayerID)
            notice = "Selected \(selection.count) layers (except current)."
        }
        if igMenuItem_Bool(
            "Invert Selection", nil, false, !order.isEmpty) {
            selection.invert(in: order)
            notice = "Selected \(selection.count) layers."
        }
        if igMenuItem_Bool(
            "Select Current Layer", nil, false, doc.activeLayerID != nil) {
            selection.selectCurrent(doc.activeLayerID)
            notice = "Selected the current layer."
        }
        let canSimilar = !order.isEmpty && !selection.isEmpty
        if ImGuiBeginMenu("Select Similar", canSimilar) {
            let refHandle =
                selection.anchor.flatMap {
                    selection.selected.contains($0) ? $0 : nil
                } ?? selection.orderedSelection(in: order) {
                    doc.layer(for: $0)?.name
                }.first
            if let refHandle,
               let reference = doc.layer(for: refHandle) {
                let layers = order.compactMap { doc.layer(for: $0) }
                for criterion in LayerSimilarCriterion.allCases {
                    if igMenuItem_Bool(
                        criterion.displayName, nil, false, true) {
                        selection.selectSimilar(
                            to: reference, in: layers,
                            criterion: criterion)
                        notice = "Select Similar "
                            + "(\(criterion.displayName)): "
                            + "\(selection.count) layers."
                    }
                }
            }
            ImGuiEndMenu()
        }
    }

    private static func renderToolbar(
        engine: PhrostEngine, document doc: CADDocument
    ) {
        let service = LayerTransactionService()
        ensureSelection(for: doc)
        let theme = engine.ui.theme
        let policy = LayerPanelPolicy(frameHeight: ImGuiGetFrameHeight())
        let size = policy.toolbarButtonSize
        let groupGap = policy.toolbarGroupGap
        let targetLabel = targetCountLabel(for: doc)
        func btn(
            _ id: String, _ icon: String, _ tooltip: String,
            gap: Float = 4, first: Bool = false,
            enabled: Bool = true, danger: Bool = false
        ) -> Bool {
            if first {
                ImGuiSetCursorPosX(6)
            } else {
                PanelWidgets.flow(itemWidth: size, gap: gap)
            }
            return PanelWidgets.iconButton(
                id: id, icon: icon, tooltip: tooltip, theme: theme,
                size: size, enabled: enabled, danger: danger)
        }

        renderSelectRow(engine: engine, document: doc, policy: policy)

        // State toggles (pairs, group-gapped, wrapping).
        if btn("LPMOn", "eye", "Bulk On \(targetLabel)", first: true) {
            applyTarget(doc, "Bulk On") {
                service.setVisibleBulk(in: doc, handles: $0, visible: true)
            }
        }
        if btn("LPMOff", "eye-off", "Bulk Off \(targetLabel)") {
            applyTargetExcludingCurrent(doc, "Bulk Off") {
                service.setVisibleBulk(in: doc, handles: $0, visible: false)
            }
        }
        if btn("LPMFreeze", "freeze", "Bulk Freeze \(targetLabel)",
               gap: groupGap) {
            applyTargetExcludingCurrent(doc, "Bulk Freeze") {
                service.setFrozenBulk(in: doc, handles: $0, frozen: true)
            }
        }
        if btn("LPMThaw", "thaw", "Bulk Thaw \(targetLabel)") {
            applyTarget(doc, "Bulk Thaw") {
                service.setFrozenBulk(in: doc, handles: $0, frozen: false)
            }
        }
        if btn("LPMLock", "lock", "Bulk Lock \(targetLabel)",
               gap: groupGap) {
            applyTarget(doc, "Bulk Lock") {
                service.setLockedBulk(in: doc, handles: $0, locked: true)
            }
        }
        if btn("LPMUnlock", "unlock", "Bulk Unlock \(targetLabel)") {
            applyTarget(doc, "Bulk Unlock") {
                service.setLockedBulk(in: doc, handles: $0, locked: false)
            }
        }
        if btn("LPMPlot", "print", "Bulk Plot \(targetLabel)",
               gap: groupGap) {
            applyTarget(doc, "Bulk Plot") {
                service.setPlottableBulk(in: doc, handles: $0, plottable: true)
            }
        }
        if btn("LPMNoPlot", "no-plot", "Bulk No Plot \(targetLabel)") {
            applyTarget(doc, "Bulk NoPlot") {
                service.setPlottableBulk(in: doc, handles: $0, plottable: false)
            }
        }
        let hasVP = !(selectedViewportID ?? "").isEmpty
        if btn("LPMVPFrz", "vp-freeze",
               hasVP ? "VP Freeze \(targetLabel)"
                     : "VP Freeze: pick a viewport first",
               gap: groupGap, enabled: hasVP) {
            if let vp = selectedViewportID {
                let target = targetHandles(for: doc)
                switch service.setViewportFrozenBulk(
                    in: doc, viewportID: vp,
                    handles: target.handles, frozen: true) {
                case .success(let n):
                    notice = "VP Freeze: \(n) layers."
                case .failure(let error):
                    notice = "VP Freeze: \(error.description)"
                }
            }
        }
        if btn("LPMVPThaw", "vp-thaw",
               hasVP ? "VP Thaw \(targetLabel)"
                     : "VP Thaw: pick a viewport first",
               enabled: hasVP) {
            if let vp = selectedViewportID {
                let target = targetHandles(for: doc)
                switch service.setViewportFrozenBulk(
                    in: doc, viewportID: vp,
                    handles: target.handles, frozen: false) {
                case .success(let n):
                    notice = "VP Thaw: \(n) layers."
                case .failure(let error):
                    notice = "VP Thaw: \(error.description)"
                }
            }
        }
        // Property dialogs + merge/delete + overflow menu.
        if btn("LPMColor", "color-drop", "Bulk Color \(targetLabel)",
               first: true) {
            ImGuiOpenPopup("##LPMColorDlg", 0)
        }
        if btn("LPMLinetype", "linetype", "Bulk Linetype \(targetLabel)") {
            ImGuiOpenPopup("##LPMLinetypeDlg", 0)
        }
        if btn("LPMWeight", "lineweight",
               "Bulk Lineweight \(targetLabel)") {
            ImGuiOpenPopup("##LPMWeightDlg", 0)
        }
        if btn("LPMTransp", "transparency",
               "Bulk Transparency \(targetLabel)") {
            ImGuiOpenPopup("##LPMTranspDlg", 0)
        }
        if btn("LPMMerge", "join", "Merge \(targetLabel)...",
               gap: groupGap) {
            resetTextField(id: "##LPMMergeTarget")
            ImGuiOpenPopup("##LPMMergeDlg", 0)
        }
        if btn("LPMDelete", "trash", "Delete \(targetLabel)...",
               danger: true) {
            let target = targetHandles(for: doc)
            if target.handles.isEmpty {
                notice = "Delete: no layers selected or in scope."
            } else {
                ImGuiOpenPopup("##LPMDeleteConfirm", 0)
            }
        }
        if btn("LPMMore", "more", "More: Walk, States, LAYERP...",
               gap: groupGap) {
            ImGuiOpenPopup("##LPMMoreMenu", 0)
        }
        var pendingDialog: String? = nil
        if ImGuiBeginPopup("##LPMMoreMenu", 0) {
            if igMenuItem_Bool("Plot Style...", nil, false, true) {
                pendingDialog = "##LPMPlotStyleDlg"
            }
            if igMenuItem_Bool("Description...", nil, false, true) {
                pendingDialog = "##LPMDescrDlg"
            }
            ImGuiSeparator()
            if igMenuItem_Bool("Layer Walk...", nil, false, true) {
                openWalk(for: doc)
            }
            if igMenuItem_Bool("Layer States...", nil, false, true) {
                resetTextField(id: "##LPMStateName")
                pendingDialog = "##LPMStatesDlg"
            }
            if igMenuItem_Bool("LAYERP (restore previous)", nil, false, true) {
                if LayerTransactionService().restoreLayerPrevious(in: doc) {
                    notice = "LAYERP: restored previous layer settings."
                } else {
                    notice = "LAYERP: nothing to restore."
                }
            }
            if igMenuItem_Bool("Reconcile All", nil, false, true) {
                let n = LayerTransactionService().reconcileAllLayers(in: doc)
                notice = "Reconciled \(n) layers."
            }
            ImGuiEndPopup()
        }
        if let pendingDialog {
            ImGuiOpenPopup(pendingDialog, 0)
        }
    }

    private static func renderScopeStrip(
        engine: PhrostEngine, document doc: CADDocument
    ) {
        let theme = engine.ui.theme
        let policy = LayerPanelPolicy(frameHeight: ImGuiGetFrameHeight())
        let size = policy.toolbarButtonSize
        func chip(
            _ id: String, _ icon: String, _ label: String,
            tooltip: String, checked: Bool, first: Bool = false
        ) -> Bool {
            if first {
                ImGuiSetCursorPosX(6)
            } else {
                PanelWidgets.flow(
                    itemWidth: PanelWidgets.labelButtonWidth(
                        icon: icon, label: label, size: size,
                        chevron: true))
            }
            return PanelWidgets.labelButton(
                id: id, icon: icon, label: label, tooltip: tooltip,
                theme: theme, size: size, checked: checked,
                chevron: true)
        }

        if chip("LPMViewportBtn", "vport",
                selectedViewportID ?? "No VP",
                tooltip: "Viewport for VP overrides",
                checked: selectedViewportID != nil, first: true) {
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
        let filterActive = activeFilterName != nil
            || unreconciledOnly || viewportFrozenOnly
        if chip("LPMFilterBtn", "filter",
                activeFilterName ?? "All layers",
                tooltip: "Layer filter scope",
                checked: filterActive) {
            ImGuiOpenPopup("##LPMFilterMenu", 0)
        }
        if ImGuiBeginPopup("##LPMFilterMenu", 0) {
            if igMenuItem_Bool(
                "Unreconciled only", nil, unreconciledOnly, true) {
                unreconciledOnly.toggle()
            }
            if igMenuItem_Bool(
                "VP-frozen only", nil, viewportFrozenOnly, true) {
                viewportFrozenOnly.toggle()
            }
            ImGuiSeparator()
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
        if chip("LPMStateBtn", "layers",
                activeStateName ?? "Any state",
                tooltip: "Layer state scope",
                checked: activeStateName != nil) {
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
        if !selection.isEmpty {
            summary += " · Selected: \(selection.count)"
        }
        ImGuiTextV(summary)
        if !notice.isEmpty {
            ImGuiSetCursorPosX(6)
            ImGuiPushStyleColor(
                Int32(ImGuiCol_Text.rawValue), engine.ui.theme.textAccent)
            ImGuiTextV(notice)
            ImGuiPopStyleColor(1)
        }
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
            ImGuiTextV("Bulk color \(targetCountLabel(for: doc))")
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
                applyTarget(doc, "Bulk color") {
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
                applyTarget(doc, "Bulk color") {
                    LayerTransactionService().setColorBulk(
                        in: doc, handles: $0, color: color)
                }
            }
            ImGuiEndPopup()
        }
    }

    private static func renderLinetypeDialog(document doc: CADDocument) {
        if ImGuiBeginPopup("##LPMLinetypeDlg", 0) {
            ImGuiTextV("Bulk linetype \(targetCountLabel(for: doc))")
            ImGuiSeparator()
            let names = LayerManagerModel.availableLinetypes(in: doc)
            var index = min(_linetypeIndex, Int32(max(0, names.count - 1)))
            ImGuiSetNextItemWidth(220)
            if igCombo_Str("##LPMLinetypeCombo", &index, comboItems(names), -1) {
                _linetypeIndex = index
            }
            if igSmallButton("Apply##LPMLinetypeApply"), !names.isEmpty {
                let value = names[Int(min(index, Int32(names.count - 1)))]
                applyTarget(doc, "Bulk linetype") {
                    LayerTransactionService().setLineTypeBulk(
                        in: doc, handles: $0, lineType: value)
                }
            }
            ImGuiEndPopup()
        }
    }

    private static func renderLineweightDialog(document doc: CADDocument) {
        if ImGuiBeginPopup("##LPMWeightDlg", 0) {
            ImGuiTextV("Bulk lineweight \(targetCountLabel(for: doc))")
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
                applyTarget(doc, "Bulk lineweight") {
                    LayerTransactionService().setLineWeightBulk(
                        in: doc, handles: $0, lineWeight: value)
                }
            }
            ImGuiEndPopup()
        }
    }

    private static func renderTransparencyDialog(document doc: CADDocument) {
        if ImGuiBeginPopup("##LPMTranspDlg", 0) {
            ImGuiTextV("Bulk transparency \(targetCountLabel(for: doc))")
            ImGuiSeparator()
            var value = _transparency
            ImGuiSetNextItemWidth(220)
            if igSliderFloat("Percent", &value, 0, 90, "%.0f", 0) {
                _transparency = value
            }
            if igSmallButton("Apply##LPMTranspApply") {
                let percent = Int(_transparency)
                applyTarget(doc, "Bulk transparency") {
                    LayerTransactionService().setTransparencyBulk(
                        in: doc, handles: $0, transparency: percent)
                }
            }
            ImGuiEndPopup()
        }
    }

    private static func renderPlotStyleDialog(document doc: CADDocument) {
        if ImGuiBeginPopup("##LPMPlotStyleDlg", 0) {
            ImGuiTextV("Bulk plot style \(targetCountLabel(for: doc))")
            ImGuiSeparator()
            let names = LayerManagerModel.availablePlotStyles(in: doc)
            var index = min(_plotStyleIndex, Int32(max(0, names.count - 1)))
            ImGuiSetNextItemWidth(220)
            if igCombo_Str("##LPMPlotStyleCombo", &index, comboItems(names), -1) {
                _plotStyleIndex = index
            }
            if igSmallButton("Apply##LPMPlotStyleApply"), !names.isEmpty {
                let value = names[Int(min(index, Int32(names.count - 1)))]
                applyTarget(doc, "Bulk plot style") {
                    LayerTransactionService().setPlotStyleBulk(
                        in: doc, handles: $0, plotStyleName: value)
                }
            }
            ImGuiEndPopup()
        }
    }

    private static func renderDescriptionDialog(document doc: CADDocument) {
        if ImGuiBeginPopup("##LPMDescrDlg", 0) {
            ImGuiTextV("Bulk description \(targetCountLabel(for: doc))")
            ImGuiSeparator()
            let value = renderTextField(
                id: "##LPMDescrText", hint: "Description...",
                initial: "", width: 260)
            if igSmallButton("Apply##LPMDescrApply") {
                applyTarget(doc, "Bulk description") {
                    LayerTransactionService().setDescriptionBulk(
                        in: doc, handles: $0, description: value)
                }
            }
            ImGuiEndPopup()
        }
    }

    private static func renderMergeDialog(document doc: CADDocument) {
        if ImGuiBeginPopup("##LPMMergeDlg", 0) {
            let bulk = targetHandles(for: doc)
            let names = bulk.handles.compactMap {
                doc.layer(for: $0)?.name
            }
            let scope = bulk.isSelection ? "selected" : "in-scope"
            ImGuiTextV("Merge \(names.count) \(scope) layers")
            ImGuiSeparator()
            let target = renderTextField(
                id: "##LPMMergeTarget", hint: "Target layer...",
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

    /// Bulk-delete confirmation: lists what would be deleted and what
    /// would be skipped (current, "0", xref-dependent, in-use) before
    /// anything changes. One undo step on confirm.
    private static func renderDeleteDialog(document doc: CADDocument) {
        if ImGuiBeginPopup("##LPMDeleteConfirm", 0) {
            let target = targetHandles(for: doc)
            switch LayerTransactionService().auditBulkDelete(
                in: doc, handles: target.handles,
                eraseEntities: _deleteEraseEntities) {
            case .failure(let error):
                ImGuiTextV("Delete: \(error.description)")
            case .success(let plan):
                ImGuiTextV("Delete \(plan.deletable.count) layers?")
                if !plan.skipped.isEmpty {
                    ImGuiSeparator()
                    ImGuiTextV("Skipped (\(plan.skipped.count)):")
                    for skip in plan.skipped.prefix(8) {
                        ImGuiTextV("· \(skip.name): \(skip.reason)")
                    }
                    if plan.skipped.count > 8 {
                        ImGuiTextV(
                            "...and \(plan.skipped.count - 8) more.")
                    }
                }
                ImGuiSeparator()
                var erase = _deleteEraseEntities
                if ImGuiCheckbox("Erase its entities too", &erase) {
                    _deleteEraseEntities = erase
                }
                if plan.deletable.isEmpty { ImGuiBeginDisabled(true) }
                if igSmallButton("Delete##LPMDeleteConfirmApply") {
                    switch LayerTransactionService().deleteLayersBulk(
                        in: doc, handles: target.handles,
                        eraseEntities: _deleteEraseEntities) {
                    case .success(let outcome):
                        notice = "Deleted \(outcome.deleted) layer"
                            + (outcome.deleted == 1 ? "" : "s")
                        if outcome.erasedEntities > 0 {
                            notice += " (\(outcome.erasedEntities) entities)"
                        }
                        if !outcome.skipped.isEmpty {
                            notice += " · skipped \(outcome.skipped.count)"
                        }
                        notice += "."
                        ensureSelection(for: doc)
                        ImGuiCloseCurrentPopup()
                    case .failure(let error):
                        notice = "Delete: \(error.description)"
                    }
                }
                if plan.deletable.isEmpty { ImGuiEndDisabled() }
                ImGuiSameLine(0, 4)
                if igSmallButton("Cancel##LPMDeleteConfirmCancel") {
                    ImGuiCloseCurrentPopup()
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
                id: "##LPMStateName", hint: "State name...",
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
