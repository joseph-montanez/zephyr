// =========================================================================
// MARK: - Layer parity Phase 6: Layer Properties Manager model
//
// Headless model behind the Layers panel's Layer Properties Manager
// presentation. All value logic lives here so it is unit-testable
// without ImGui:
//
//   - `LayerManagerColumn`: every column the manager shows, split into
//     drawing-global columns and selected-viewport (`VP`) columns.
//   - `LayerManagerQuery` / `LayerManagerModel.rows`: one-pass search +
//     named-filter + state scoping + unreconciled/viewport flags,
//     shared sort settings, and a hard row cap so a 10k-layer drawing
//     cannot stall the panel (performance-safe rendering).
//   - `LayerManagerStatus`: the counts behind the manager header and the
//     status-bar layer summary.
//   - Picker validation (`validateACI`, `validateTransparency`,
//     `validatePlotStyleName`, `validateDescription`,
//     `availableLinetypes`) shared by the panel pickers/dialogs.
//   - `LayerWalkSession`: ordered walk state for the LAYWALK dialog.
//   - `LayerTransactionService` bulk setters: every bulk edit validates
//     first and then applies in exactly one undo step plus one LAYERP
//     checkpoint, with render-only sibling propagation (Phase 1/4
//     contract). Viewport bulk freeze reuses the single-undo
//     `setViewportLayersFrozen` document path.
// =========================================================================

import Foundation

// =========================================================================
// MARK: - LayerManagerColumn
// =========================================================================

/// Every column of the Layer Properties Manager grid. `isViewport`
/// columns resolve through the selected viewport's override map and read
/// "(none)" when no viewport is selected.
public enum LayerManagerColumn: String, CaseIterable, Sendable {
    case status
    case name
    case on
    case freeze
    case lock
    case color
    case linetype
    case lineweight
    case transparency
    case plot
    case plotStyle
    case description
    case vpFreeze
    case vpColor
    case vpLinetype
    case vpLineweight
    case vpTransparency
    case vpPlotStyle
    case reconciled
    case used

    /// True for columns that need a selected viewport.
    public var isViewport: Bool {
        switch self {
        case .vpFreeze, .vpColor, .vpLinetype, .vpLineweight,
             .vpTransparency, .vpPlotStyle:
            return true
        default:
            return false
        }
    }

    public var headerTitle: String {
        switch self {
        case .status: return "Status"
        case .name: return "Name"
        case .on: return "On"
        case .freeze: return "Freeze"
        case .lock: return "Lock"
        case .color: return "Color"
        case .linetype: return "Linetype"
        case .lineweight: return "Lineweight"
        case .transparency: return "Transparency"
        case .plot: return "Plot"
        case .plotStyle: return "Plot Style"
        case .description: return "Description"
        case .vpFreeze: return "VP Freeze"
        case .vpColor: return "VP Color"
        case .vpLinetype: return "VP Linetype"
        case .vpLineweight: return "VP Lineweight"
        case .vpTransparency: return "VP Transparency"
        case .vpPlotStyle: return "VP Plot Style"
        case .reconciled: return "Reconciled"
        case .used: return "Used"
        }
    }
}

// =========================================================================
// MARK: - LayerManagerQuery
// =========================================================================

/// What the manager grid shows. `filterName` scopes to a stored named
/// filter, `stateName` scopes to the layers captured in a stored layer
/// state; both are case-insensitive and unknown names match nothing
/// (never everything).
public struct LayerManagerQuery: Equatable, Sendable {
    public var searchText: String
    public var filterName: String?
    public var stateName: String?
    public var showOnlyUnreconciled: Bool
    public var showOnlyViewportFrozen: Bool
    public var sort: LayerSortSettings
    /// Hard cap on returned rows (performance-safe rendering).
    public var rowLimit: Int

    public init(
        searchText: String = "",
        filterName: String? = nil,
        stateName: String? = nil,
        showOnlyUnreconciled: Bool = false,
        showOnlyViewportFrozen: Bool = false,
        sort: LayerSortSettings = LayerSortSettings(),
        rowLimit: Int = LayerManagerModel.defaultRowLimit
    ) {
        self.searchText = searchText
        self.filterName = filterName
        self.stateName = stateName
        self.showOnlyUnreconciled = showOnlyUnreconciled
        self.showOnlyViewportFrozen = showOnlyViewportFrozen
        self.sort = sort
        self.rowLimit = rowLimit
    }
}

// =========================================================================
// MARK: - LayerManagerRow
// =========================================================================

/// One grid row: the stored layer plus its selected-viewport resolution.
/// `effectiveLayer` carries the viewport style deltas (frozen is exposed
/// separately via `viewportFrozen`, matching the add-only freeze rule).
public struct LayerManagerRow: Equatable, Sendable {
    public var layer: Layer
    public var viewportID: String?
    public var effectiveLayer: Layer
    public var viewportFrozen: Bool
    public var entityCount: Int

    public init(
        layer: Layer, viewportID: String? = nil,
        effectiveLayer: Layer? = nil,
        viewportFrozen: Bool = false,
        entityCount: Int = 0
    ) {
        self.layer = layer
        self.viewportID = viewportID
        self.effectiveLayer = effectiveLayer ?? layer
        self.viewportFrozen = viewportFrozen
        self.entityCount = entityCount
    }
}

// =========================================================================
// MARK: - LayerManagerModel
// =========================================================================

public enum LayerManagerModel {
    /// Hard row cap so pathological drawings cannot stall the panel.
    public static let defaultRowLimit = 2000

    /// Rows for the manager grid: named filter -> state scope ->
    /// unreconciled/viewport flags -> name search -> shared sort ->
    /// row cap. Read-only: no undo, no edits.
    public static func rows(
        in document: CADDocument,
        viewportID: String? = nil,
        query: LayerManagerQuery = LayerManagerQuery(),
        entityCounts: [UUID: Int]? = nil
    ) -> (rows: [LayerManagerRow], total: Int, truncated: Bool) {
        var layers = document.allLayers

        if let name = query.filterName,
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let key = name.trimmingCharacters(
                in: .whitespacesAndNewlines).uppercased()
            guard let filter = document.layerFilters[key] else {
                return ([], 0, false)
            }
            layers = layers.filter { filter.matches($0) }
        }

        if let name = query.stateName,
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let key = name.trimmingCharacters(
                in: .whitespacesAndNewlines).uppercased()
            guard let state = document.layerStates[key] else {
                return ([], 0, false)
            }
            let known = Set(state.entries.keys)
            layers = layers.filter {
                known.contains($0.name.trimmingCharacters(
                    in: .whitespacesAndNewlines).uppercased())
            }
        }

        if query.showOnlyUnreconciled {
            layers = layers.filter { !$0.isReconciled }
        }

        let viewportKey = viewportID?.trimmingCharacters(
            in: .whitespacesAndNewlines)
        let hasViewport = viewportKey != nil && !(viewportKey!.isEmpty)
        if query.showOnlyViewportFrozen {
            guard hasViewport else { return ([], 0, false) }
            layers = layers.filter {
                document.isLayerFrozenInViewport(
                    viewportID: viewportKey!, layer: $0.handle)
            }
        }

        let search = query.searchText.trimmingCharacters(
            in: .whitespacesAndNewlines)
        if !search.isEmpty {
            layers = layers.filter {
                $0.name.localizedCaseInsensitiveContains(search)
            }
        }

        let counts: [UUID: Int]
        if let entityCounts {
            counts = entityCounts
        } else if query.sort.key == .used {
            counts = LayerSortPolicy.entityCounts(in: document)
        } else {
            counts = [:]
        }
        let sorted = LayerSortPolicy.sorted(
            layers, entityCounts: counts, settings: query.sort)

        let total = sorted.count
        let limit = max(1, query.rowLimit)
        let truncated = total > limit
        let page = Array(sorted.prefix(limit))
        let rows = page.map { layer -> LayerManagerRow in
            var effective = layer
            var frozen = false
            if hasViewport,
               let override = document.viewportOverride(
                   viewportID: viewportKey!, layer: layer.handle) {
                frozen = override.frozen
                effective = override.applied(to: layer)
            }
            return LayerManagerRow(
                layer: layer, viewportID: hasViewport ? viewportKey : nil,
                effectiveLayer: effective, viewportFrozen: frozen,
                entityCount: counts[layer.handle] ?? 0)
        }
        return (rows, total, truncated)
    }

    /// Short status text for the manager header ("12 layers, 2 frozen").
    public static func headerSummary(
        in document: CADDocument, viewportID: String? = nil
    ) -> String {
        let status = status(in: document, viewportID: viewportID)
        var parts = ["\(status.total) layer\(status.total == 1 ? "" : "s")"]
        if status.frozen > 0 { parts.append("\(status.frozen) frozen") }
        if status.off > 0 { parts.append("\(status.off) off") }
        if status.locked > 0 { parts.append("\(status.locked) locked") }
        if status.unreconciled > 0 {
            parts.append("\(status.unreconciled) unreconciled")
        }
        if status.viewportFrozen > 0 {
            parts.append("\(status.viewportFrozen) VP frozen")
        }
        return parts.joined(separator: ", ")
    }
}

// =========================================================================
// MARK: - LayerManagerStatus
// =========================================================================

/// Counts behind the manager header and the status-bar layer summary.
public struct LayerManagerStatus: Equatable, Sendable {
    public var total: Int
    public var off: Int
    public var frozen: Int
    public var locked: Int
    public var unreconciled: Int
    public var viewportFrozen: Int
    public var currentLayerName: String

    public init(
        total: Int = 0, off: Int = 0, frozen: Int = 0, locked: Int = 0,
        unreconciled: Int = 0, viewportFrozen: Int = 0,
        currentLayerName: String = "none"
    ) {
        self.total = total
        self.off = off
        self.frozen = frozen
        self.locked = locked
        self.unreconciled = unreconciled
        self.viewportFrozen = viewportFrozen
        self.currentLayerName = currentLayerName
    }
}

public extension LayerManagerModel {
    /// One-pass status snapshot. Read-only.
    static func status(
        in document: CADDocument, viewportID: String? = nil
    ) -> LayerManagerStatus {
        let layers = document.allLayers
        var result = LayerManagerStatus(total: layers.count)
        for layer in layers {
            if !layer.isVisible { result.off += 1 }
            if layer.isFrozen { result.frozen += 1 }
            if layer.isLocked { result.locked += 1 }
            if !layer.isReconciled { result.unreconciled += 1 }
        }
        let key = viewportID?.trimmingCharacters(
            in: .whitespacesAndNewlines)
        if let key, !key.isEmpty {
            result.viewportFrozen = layers.filter {
                document.isLayerFrozenInViewport(
                    viewportID: key, layer: $0.handle)
            }.count
        }
        if let id = document.activeLayerID,
           let current = document.layer(for: id) {
            result.currentLayerName = current.name
        }
        return result
    }

    /// Status-bar suffix for the manager: empty when there is nothing
    /// worth flagging, so quiet drawings keep a quiet status bar.
    static func statusBarSuffix(
        in document: CADDocument, viewportID: String? = nil
    ) -> String {
        let s = status(in: document, viewportID: viewportID)
        var flags: [String] = []
        if s.unreconciled > 0 {
            flags.append("\(s.unreconciled) unreconciled")
        }
        if s.viewportFrozen > 0 {
            flags.append("\(s.viewportFrozen) VP frozen")
        }
        guard !flags.isEmpty else { return "" }
        return "  ·  Layers: " + flags.joined(separator: ", ")
    }
}

// =========================================================================
// MARK: - Picker validation
// =========================================================================

public extension LayerManagerModel {
    /// AutoCAD caps layer descriptions at 255 characters.
    static let maxDescriptionLength = 255

    static func validateACI(_ index: Int) -> LayerEditError? {
        (1...255).contains(index)
            ? nil : .invalidValue("ACI index \(index) is out of range 1...255.")
    }

    static func validateTransparency(_ percent: Int) -> LayerEditError? {
        (0...90).contains(percent)
            ? nil : .invalidValue(
                "Transparency \(percent) is out of range 0...90.")
    }

    static func validatePlotStyleName(_ name: String) -> LayerEditError? {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? .invalidValue("Plot-style name must not be blank.") : nil
    }

    static func validateDescription(_ text: String) -> LayerEditError? {
        text.count <= maxDescriptionLength
            ? nil : .invalidValue(
                "Description is \(text.count) characters (max \(maxDescriptionLength)).")
    }

    static func validateLineWeight(_ mm: Double) -> LayerEditError? {
        mm.isFinite && mm >= 0
            ? nil : .invalidValue("Lineweight must be a finite value >= 0.")
    }

    /// Linetypes the picker can offer: drawing patterns plus the
    /// reserved names every drawing understands.
    static func availableLinetypes(in document: CADDocument) -> [String] {
        var names = Set(["CONTINUOUS", "BYLAYER", "BYBLOCK"])
        for key in document.linetypePatterns.keys {
            let trimmed = key.trimmingCharacters(
                in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { names.insert(trimmed.uppercased()) }
        }
        return names.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    /// Plot styles the picker can offer: the drawing's layer styles
    /// plus the Normal default every drawing understands.
    static func availablePlotStyles(in document: CADDocument) -> [String] {
        var names = Set(["Normal"])
        for layer in document.allLayers {
            let trimmed = layer.plotStyleName.trimmingCharacters(
                in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { names.insert(trimmed) }
        }
        return names.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }
}

// =========================================================================
// MARK: - LayerWalkSession
// =========================================================================

/// Ordered state for the LAYWALK dialog: walk the drawing one layer at
/// a time in manager sort order. Pure value: the caller applies
/// isolation through `LayerTransactionService`.
public struct LayerWalkSession: Equatable, Sendable {
    public var layerHandles: [UUID]
    public var layerNames: [String]
    public var index: Int

    public init(layers: [Layer], startAt handle: UUID? = nil) {
        layerHandles = layers.map(\.handle)
        layerNames = layers.map(\.name)
        if let handle, let at = layerHandles.firstIndex(of: handle) {
            index = at
        } else {
            index = 0
        }
    }

    public var count: Int { layerHandles.count }
    public var isEmpty: Bool { layerHandles.isEmpty }

    public var currentHandle: UUID? {
        guard !layerHandles.isEmpty,
              layerHandles.indices.contains(index) else { return nil }
        return layerHandles[index]
    }

    public var currentName: String? {
        guard !layerNames.isEmpty,
              layerNames.indices.contains(index) else { return nil }
        return layerNames[index]
    }

    /// Position label for the dialog ("3 of 12 — Walls").
    public var positionLabel: String? {
        guard let name = currentName else { return nil }
        return "\(index + 1) of \(count) — \(name)"
    }

    public mutating func moveTo(handle: UUID) -> Bool {
        guard let at = layerHandles.firstIndex(of: handle) else {
            return false
        }
        index = at
        return true
    }

    @discardableResult
    public mutating func next() -> Bool {
        guard index + 1 < layerHandles.count else { return false }
        index += 1
        return true
    }

    @discardableResult
    public mutating func previous() -> Bool {
        guard index > 0 else { return false }
        index -= 1
        return true
    }
}

// =========================================================================
// MARK: - LayerSimilarCriterion
// =========================================================================

/// One matchable layer property for "Select Similar" in the Layer
/// Properties Manager. Matching is by resolved value (exact RGB, not
/// just ACI) so true-color and color-book layers match correctly.
public enum LayerSimilarCriterion: String, CaseIterable, Sendable {
    case color
    case linetype
    case lineweight
    case transparency
    case plot

    public var displayName: String {
        switch self {
        case .color: return "Color"
        case .linetype: return "Linetype"
        case .lineweight: return "Lineweight"
        case .transparency: return "Transparency"
        case .plot: return "Plot"
        }
    }

    public func matches(_ layer: Layer, reference: Layer) -> Bool {
        switch self {
        case .color:
            return layer.color == reference.color
        case .linetype:
            return layer.lineType.caseInsensitiveCompare(reference.lineType)
                == .orderedSame
        case .lineweight:
            return abs(layer.lineWeight - reference.lineWeight) < 1e-9
        case .transparency:
            return layer.transparency == reference.transparency
        case .plot:
            return layer.isPlottable == reference.isPlottable
        }
    }
}

// =========================================================================
// MARK: - LayerSelectionModel
// =========================================================================

/// AutoCAD-style multi-selection for the Layer Properties Manager.
/// Headless value logic (no ImGui): the panel owns one of these and
/// feeds it the visible display order plus the Ctrl/Shift modifier
/// state for each click.
///
/// Scope rule: commands that take an `ordered` visible list only touch
/// the visible portion — out-of-scope picks are preserved. Only
/// `deselectAll` (and `selectCurrent`, which targets one layer) clear
/// everything. Selection is always independent of `activeLayerID`.
public struct LayerSelectionModel: Equatable, Sendable {
    public var selected: Set<UUID>
    public var anchor: UUID?

    public init(selected: Set<UUID> = [], anchor: UUID? = nil) {
        self.selected = selected
        self.anchor = anchor
    }

    public var isEmpty: Bool { selected.isEmpty }
    public var count: Int { selected.count }

    public func contains(_ handle: UUID) -> Bool {
        selected.contains(handle)
    }

    /// Standard click handling: plain click selects one, Ctrl toggles,
    /// Shift selects the continuous display range from the anchor.
    /// Shift with no usable anchor falls back to a plain click.
    public mutating func click(
        handle: UUID, in ordered: [UUID], ctrl: Bool, shift: Bool
    ) {
        if shift, let anchor,
           let lo = rangeIndices(from: anchor, to: handle, in: ordered) {
            let visible = Set(ordered)
            let range = Set(ordered[lo.0...lo.1])
            selected.subtract(visible)
            selected.formUnion(range)
            return
        }
        if ctrl {
            if selected.contains(handle) {
                selected.remove(handle)
            } else {
                selected.insert(handle)
            }
            anchor = handle
            return
        }
        selected = [handle]
        anchor = handle
    }

    /// Select every visible layer, preserving out-of-scope picks.
    public mutating func selectAll(in ordered: [UUID]) {
        selected.formUnion(ordered)
        if anchor == nil { anchor = ordered.first }
    }

    public mutating func deselectAll() {
        selected = []
        anchor = nil
    }

    /// Select every visible layer except the current one, preserving
    /// out-of-scope picks (the topo "keep the frame" workflow).
    public mutating func selectAllExceptCurrent(
        in ordered: [UUID], current: UUID?
    ) {
        let visible = Set(ordered)
        selected.subtract(visible)
        for handle in ordered where handle != current {
            selected.insert(handle)
        }
    }

    /// Toggle every visible layer, preserving out-of-scope picks.
    public mutating func invert(in ordered: [UUID]) {
        for handle in ordered {
            if selected.contains(handle) {
                selected.remove(handle)
            } else {
                selected.insert(handle)
            }
        }
    }

    /// Select exactly the current layer (clears everything else).
    public mutating func selectCurrent(_ current: UUID?) {
        if let current {
            selected = [current]
            anchor = current
        } else {
            selected = []
            anchor = nil
        }
    }

    /// Select visible layers matching the reference on one criterion,
    /// preserving out-of-scope picks.
    public mutating func selectSimilar(
        to reference: Layer, in layers: [Layer],
        criterion: LayerSimilarCriterion
    ) {
        let visible = Set(layers.map(\.handle))
        selected.subtract(visible)
        for layer in layers where criterion.matches(layer, reference: reference) {
            selected.insert(layer.handle)
        }
    }

    /// Drop handles that no longer exist (deleted/undone layers).
    /// The anchor falls back to nil when it is pruned.
    public mutating func prune(valid: Set<UUID>) {
        selected.formIntersection(valid)
        if let anchor, !valid.contains(anchor) {
            self.anchor = nil
        }
    }

    /// Selected handles in display order, with any out-of-scope picks
    /// appended in name order for determinism.
    public func orderedSelection(
        in ordered: [UUID], named lookup: (UUID) -> String?
    ) -> [UUID] {
        let set = selected
        var result = ordered.filter { set.contains($0) }
        let extra = set.subtracting(ordered).sorted {
            (lookup($0) ?? "") < (lookup($1) ?? "")
        }
        result.append(contentsOf: extra)
        return result
    }

    /// Split handles into bulk targets, skipping the current layer
    /// (bulk Off/Freeze refuse it all-or-nothing, so callers partition
    /// first and report the skip instead of failing the batch).
    public static func partitionExcludingCurrent(
        _ handles: [UUID], current: UUID?
    ) -> (targets: [UUID], skippedCurrent: Bool) {
        guard let current else { return (handles, false) }
        var skipped = false
        let targets = handles.filter {
            if $0 == current {
                skipped = true
                return false
            }
            return true
        }
        return (targets, skipped)
    }

    private func rangeIndices(
        from anchor: UUID, to handle: UUID, in ordered: [UUID]
    ) -> (Int, Int)? {
        guard let a = ordered.firstIndex(of: anchor),
              let b = ordered.firstIndex(of: handle) else {
            return nil
        }
        return (min(a, b), max(a, b))
    }
}

// =========================================================================
// MARK: - LayerTransactionService bulk setters (Phase 6)
//
// Every bulk setter validates every handle first and applies the whole
// batch in exactly one undo step plus one LAYERP checkpoint, then
// propagates render-only to siblings. Any refusal leaves all state
// untouched (no checkpoint, no undo).
// =========================================================================

public extension LayerTransactionService {
    /// Shared validate-first, apply-once bulk core. `validate` sees the
    /// live layer and may refuse the batch; `apply` mutates a table copy.
    private func bulkApply(
        in primary: CADDocument,
        siblings: [CADDocument] = [],
        handles: [UUID],
        validate: (Layer) -> LayerEditError?,
        apply: (inout [UUID: Layer]) -> Void
    ) -> Result<Int, LayerEditError> {
        var table = Dictionary(
            uniqueKeysWithValues: primary.allLayers.map { ($0.handle, $0) })
        for handle in handles {
            guard let layer = table[handle] else {
                return .failure(.unknownLayer(handle.uuidString))
            }
            if let error = validate(layer) { return .failure(error) }
        }
        guard !handles.isEmpty else { return .success(0) }
        primary.checkpointLayerPrevious()
        primary.pushUndo()
        apply(&table)
        primary.storeLayerTable(table)
        for sibling in siblings where sibling !== primary {
            _ = sibling.adoptLayers(from: primary)
        }
        return .success(handles.count)
    }

    private func guardNotCurrent(
        _ layer: Layer, in primary: CADDocument, verb: String
    ) -> LayerEditError? {
        primary.activeLayerID == layer.handle
            ? .activeLayerGuard(
                "Layer '\(layer.name)' is current and cannot be \(verb).")
            : nil
    }

    // MARK: Bulk state flags

    func setVisibleBulk(
        in primary: CADDocument, siblings: [CADDocument] = [],
        handles: [UUID], visible: Bool
    ) -> Result<Int, LayerEditError> {
        bulkApply(in: primary, siblings: siblings, handles: handles,
            validate: {
                !visible ? guardNotCurrent($0, in: primary, verb: "turned off") : nil
            },
            apply: {
                for handle in handles { $0[handle]?.isVisible = visible }
            })
    }

    func setFrozenBulk(
        in primary: CADDocument, siblings: [CADDocument] = [],
        handles: [UUID], frozen: Bool
    ) -> Result<Int, LayerEditError> {
        bulkApply(in: primary, siblings: siblings, handles: handles,
            validate: {
                frozen ? guardNotCurrent($0, in: primary, verb: "frozen") : nil
            },
            apply: {
                for handle in handles { $0[handle]?.isFrozen = frozen }
            })
    }

    func setLockedBulk(
        in primary: CADDocument, siblings: [CADDocument] = [],
        handles: [UUID], locked: Bool
    ) -> Result<Int, LayerEditError> {
        bulkApply(in: primary, siblings: siblings, handles: handles,
            validate: { _ in nil },
            apply: {
                for handle in handles { $0[handle]?.isLocked = locked }
            })
    }

    func setPlottableBulk(
        in primary: CADDocument, siblings: [CADDocument] = [],
        handles: [UUID], plottable: Bool
    ) -> Result<Int, LayerEditError> {
        bulkApply(in: primary, siblings: siblings, handles: handles,
            validate: { _ in nil },
            apply: {
                for handle in handles { $0[handle]?.isPlottable = plottable }
            })
    }

    func setReconciledBulk(
        in primary: CADDocument, siblings: [CADDocument] = [],
        handles: [UUID], reconciled: Bool
    ) -> Result<Int, LayerEditError> {
        bulkApply(in: primary, siblings: siblings, handles: handles,
            validate: { _ in nil },
            apply: {
                for handle in handles { $0[handle]?.isReconciled = reconciled }
            })
    }

    // MARK: Bulk properties

    func setColorBulk(
        in primary: CADDocument, siblings: [CADDocument] = [],
        handles: [UUID], color: ColorRGBA, source: LayerColorSource? = nil
    ) -> Result<Int, LayerEditError> {
        if let source, case .aci(let index) = source,
           let error = LayerManagerModel.validateACI(index) {
            return .failure(error)
        }
        return bulkApply(in: primary, siblings: siblings, handles: handles,
            validate: { _ in nil },
            apply: { table in
                for handle in handles {
                    table[handle]?.color = color
                    if let source {
                        table[handle]?.colorSource = source
                    } else if DXFColorTable.isACI(color) {
                        table[handle]?.colorSource = .aci(
                            Int(DXFColorTable.rgbaToACI(color)))
                    } else {
                        table[handle]?.colorSource = .trueColor
                    }
                }
            })
    }

    func setLineTypeBulk(
        in primary: CADDocument, siblings: [CADDocument] = [],
        handles: [UUID], lineType: String
    ) -> Result<Int, LayerEditError> {
        let trimmed = lineType.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(.invalidValue("Linetype name must not be blank."))
        }
        let canonical = trimmed.uppercased()
        return bulkApply(in: primary, siblings: siblings, handles: handles,
            validate: { _ in nil },
            apply: {
                for handle in handles { $0[handle]?.lineType = canonical }
            })
    }

    func setLineWeightBulk(
        in primary: CADDocument, siblings: [CADDocument] = [],
        handles: [UUID], lineWeight: Double
    ) -> Result<Int, LayerEditError> {
        if let error = LayerManagerModel.validateLineWeight(lineWeight) {
            return .failure(error)
        }
        let snapped = Layer.nearestFixedLineWeight(lineWeight)
        return bulkApply(in: primary, siblings: siblings, handles: handles,
            validate: { _ in nil },
            apply: {
                for handle in handles { $0[handle]?.lineWeight = snapped }
            })
    }

    func setTransparencyBulk(
        in primary: CADDocument, siblings: [CADDocument] = [],
        handles: [UUID], transparency: Int
    ) -> Result<Int, LayerEditError> {
        if let error = LayerManagerModel.validateTransparency(transparency) {
            return .failure(error)
        }
        return bulkApply(in: primary, siblings: siblings, handles: handles,
            validate: { _ in nil },
            apply: {
                for handle in handles {
                    $0[handle]?.transparency = transparency
                }
            })
    }

    func setPlotStyleBulk(
        in primary: CADDocument, siblings: [CADDocument] = [],
        handles: [UUID], plotStyleName: String
    ) -> Result<Int, LayerEditError> {
        let trimmed = plotStyleName.trimmingCharacters(
            in: .whitespacesAndNewlines)
        if let error = LayerManagerModel.validatePlotStyleName(trimmed) {
            return .failure(error)
        }
        return bulkApply(in: primary, siblings: siblings, handles: handles,
            validate: { _ in nil },
            apply: {
                for handle in handles {
                    $0[handle]?.plotStyleName = trimmed
                }
            })
    }

    func setDescriptionBulk(
        in primary: CADDocument, siblings: [CADDocument] = [],
        handles: [UUID], description: String
    ) -> Result<Int, LayerEditError> {
        if let error = LayerManagerModel.validateDescription(description) {
            return .failure(error)
        }
        return bulkApply(in: primary, siblings: siblings, handles: handles,
            validate: { _ in nil },
            apply: {
                for handle in handles {
                    $0[handle]?.layerDescription = description
                }
            })
    }

    // MARK: Bulk viewport freeze

    /// Freeze (or thaw) many layers in one viewport in one undo step.
    /// Unknown handles and blank viewport IDs fail with no state change.
    func setViewportFrozenBulk(
        in primary: CADDocument,
        viewportID: String,
        handles: [UUID],
        frozen: Bool
    ) -> Result<Int, LayerEditError> {
        let key = viewportID.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            return .failure(.invalidValue("Viewport id must not be blank."))
        }
        for handle in handles where primary.layer(for: handle) == nil {
            return .failure(.unknownLayer(handle.uuidString))
        }
        guard !handles.isEmpty else { return .success(0) }
        primary.setViewportLayersFrozen(
            viewportID: key, layers: handles, frozen: frozen)
        return .success(handles.count)
    }
}
