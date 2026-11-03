import Foundation

// =========================================================================
// MARK: - Layer parity Phase 1: canonical state + transactional service
//
// Canonical per-layer drafting state, matching the AutoCAD layer model:
//
//   - on/off ........... `Layer.isVisible` (DXF 62 sign; alias `isOn`)
//   - frozen ............ `Layer.isFrozen` (DXF 70 bit 1)
//   - freeze in new VPs . `Layer.freezeInNewViewports` (DXF 70 bit 2)
//   - locked ............ `Layer.isLocked` (DXF 70 bit 4)
//   - description ....... `Layer.layerDescription` (DXF 3)
//   - reconciled ........ `Layer.isReconciled` (EAB v23; DXF has no group,
//                         so imports default to reconciled)
//   - transparency ...... `Layer.transparency` 0...90 percent (DXF 440;
//                         computed alias `opacity` 0.0...1.0 preserved)
//   - lineweight ........ fixed AutoCAD set in mm (`fixedLineWeightsMM`)
//   - color intent ...... `Layer.colorSource` (ACI / RGB / color-book)
//   - plot style ........ `Layer.plotStyleName` + raw `plotStyleHandle`
//
// Layer tables are drawing-global in AutoCAD but each drawing view keeps
// its own `CADDocument` copy. `LayerTransactionService` is the single
// funnel for validated mutation: case-insensitive lookup, active-layer
// guards, exactly one undo step on the primary document, and render-only
// propagation to sibling view documents (no undo, no dirty flag), reusing
// the `adoptLayers` merge semantics the tab reconciler relies on.
// =========================================================================

// =========================================================================
// MARK: - DXF layer flag bits (group 70)
//
// Bits 16 (externally dependent) and 32 (resolved) are preserved verbatim
// for xref-dependent symbols and never assigned here.
// =========================================================================

public enum LayerDXFFlagBits {
    public static let frozen: Int = 1
    public static let freezeInNewViewports: Int = 2
    public static let locked: Int = 4
}

// =========================================================================
// MARK: - LayerColorSource
// =========================================================================

/// How a layer's display color was specified. `color` on `Layer` always
/// holds the resolved RGB actually rendered; the source records the
/// author's intent so DXF round-trips stay exact (ACI index vs 24-bit
/// true color vs named color-book swatch).
public enum LayerColorSource: Hashable, Sendable {
    /// AutoCAD Color Index 1...255 (7 = white).
    case aci(Int)
    /// Explicit 24-bit RGB (DXF 420).
    case trueColor
    /// Named swatch, e.g. "PANTONE 185 C". `Layer.color` holds the
    /// resolved RGB preview. Round-trips via EAB v23 and via
    /// `ZEPHYR_COLORBOOK` XDATA on DXF export.
    case colorBook(name: String)

    public static let `default`: LayerColorSource = .aci(7)

    /// The ACI index when the source is indexed, nil otherwise.
    public var aciIndex: Int? {
        if case .aci(let index) = self { return index }
        return nil
    }

    /// The book name when the source is a color-book swatch, nil otherwise.
    public var colorBookName: String? {
        if case .colorBook(let name) = self { return name }
        return nil
    }

    /// True when the color is an explicit RGB specification (TrueColor or
    /// a named color-book swatch) rather than an ACI index. Explicit
    /// white renders raw on light backgrounds (AutoCAD parity); only ACI
    /// white inverts for contrast.
    public var isExplicitRGB: Bool {
        switch self {
        case .trueColor, .colorBook: return true
        case .aci: return false
        }
    }
}

// =========================================================================
// MARK: - Layer canonical-value helpers
// =========================================================================

public extension Layer {
    /// Fixed AutoCAD lineweights in mm (0.00 is "hairline").
    static let fixedLineWeightsMM: [Double] = [
        0.00, 0.05, 0.09, 0.13, 0.15, 0.18, 0.20, 0.25, 0.30, 0.35,
        0.40, 0.50, 0.53, 0.60, 0.70, 0.80, 0.90, 1.00, 1.06, 1.20,
        1.40, 1.58, 2.00, 2.11,
    ]

    /// Snap an arbitrary mm value to the nearest fixed lineweight.
    static func nearestFixedLineWeight(_ mm: Double) -> Double {
        guard mm.isFinite else { return 0.25 }
        let clamped = max(0.0, min(2.11, mm))
        return fixedLineWeightsMM.min(by: {
            abs($0 - clamped) < abs($1 - clamped)
        }) ?? 0.25
    }

    /// Clamp a transparency percent to the canonical 0...90 range.
    /// (AutoCAD caps layer transparency at 90%.)
    static func clampedTransparency(_ percent: Int) -> Int {
        max(0, min(90, percent))
    }

    /// Convert a 0.0...1.0 opacity to the canonical 0...90 percent scale.
    static func transparencyForOpacity(_ opacity: Double) -> Int {
        guard opacity.isFinite else { return 0 }
        return clampedTransparency(Int((1.0 - opacity) * 100.0 + 0.5))
    }

    /// DXF group-70 state bits for the frozen/locked/new-viewport flags.
    /// Xref bits (16/32) live on `DXFLayerEntry.flags`, not here.
    var dxfStateBits: Int {
        var bits = 0
        if isFrozen { bits |= LayerDXFFlagBits.frozen }
        if freezeInNewViewports { bits |= LayerDXFFlagBits.freezeInNewViewports }
        if isLocked { bits |= LayerDXFFlagBits.locked }
        return bits
    }

    /// A layer only draws when it is on and not frozen.
    /// (Locked layers still draw; they only reject edits.)
    var isEffectivelyVisible: Bool { isVisible && !isFrozen }
}

// =========================================================================
// MARK: - LayerEditError
// =========================================================================

/// Validation failure for a transactional layer mutation. No state changes
/// when a mutation returns one of these: validation runs before any undo
/// snapshot is pushed.
public enum LayerEditError: Error, Equatable, Sendable, CustomStringConvertible {
    case unknownLayer(String)
    case duplicateName(String)
    case blankName
    case protectedLayer(String)
    case activeLayerGuard(String)
    case invalidValue(String)

    public var description: String {
        switch self {
        case .unknownLayer(let name):
            return "Layer '\(name)' not found."
        case .duplicateName(let name):
            return "A layer named '\(name)' already exists."
        case .blankName:
            return "Layer name must not be blank."
        case .protectedLayer(let reason):
            return reason
        case .activeLayerGuard(let reason):
            return reason
        case .invalidValue(let reason):
            return reason
        }
    }
}

// =========================================================================
// MARK: - LayerTransactionService
// =========================================================================

/// Validated, single-undo layer mutations with cross-view propagation.
///
/// Every mutating call validates first (case-insensitive lookup, name
/// rules, active-layer guards, value ranges) and only then pushes exactly
/// one undo entry on the primary document. The same change is propagated
/// to sibling view documents render-only via `adoptLayers` — no undo, no
/// dirty flag — matching tab-reconciliation semantics.
public struct LayerTransactionService {
    public init() {}

    /// Outcome of an applied mutation: the stored layer plus how many
    /// sibling documents actually changed during propagation.
    public struct Outcome: Equatable, Sendable {
        public let layer: Layer
        public let propagatedToSiblings: Int
    }

    // MARK: Lookup

    /// Case-insensitive, whitespace-trimmed lookup. Empty names never match.
    public func layer(in document: CADDocument, named name: String) -> Layer? {
        document.findLayer(named: name)
    }

    // MARK: Create / delete / rename / current

    @discardableResult
    public func createLayer(
        in primary: CADDocument,
        siblings: [CADDocument] = [],
        name: String,
        configure: (inout Layer) -> Void = { _ in }
    ) -> Result<Outcome, LayerEditError> {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.blankName) }
        if let clash = primary.findLayer(named: trimmed) {
            return .failure(.duplicateName(clash.name))
        }
        var layer = Layer(name: trimmed)
        configure(&layer)
        // Re-validate anything `configure` may have set.
        layer.name = layer.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !layer.name.isEmpty else { return .failure(.blankName) }
        if let clash = primary.findLayer(named: layer.name) {
            return .failure(.duplicateName(clash.name))
        }
        layer.transparency = Layer.clampedTransparency(layer.transparency)
        layer.lineWeight = Layer.nearestFixedLineWeight(layer.lineWeight)
        if case .aci(let index) = layer.colorSource, !(1...255).contains(index) {
            return .failure(.invalidValue("ACI index \(index) is out of range 1...255."))
        }
        primary.addLayer(layer)
        let propagated = propagate(from: primary, to: siblings)
        return .success(Outcome(layer: layer, propagatedToSiblings: propagated))
    }

    public func deleteLayer(
        in primary: CADDocument,
        siblings: [CADDocument] = [],
        named name: String
    ) -> Result<Void, LayerEditError> {
        guard let layer = primary.findLayer(named: name) else {
            return .failure(.unknownLayer(name))
        }
        return deleteLayer(in: primary, siblings: siblings, handle: layer.handle)
    }

    public func deleteLayer(
        in primary: CADDocument,
        siblings: [CADDocument] = [],
        handle: UUID
    ) -> Result<Void, LayerEditError> {
        guard let layer = primary.layer(for: handle) else {
            return .failure(.unknownLayer(handle.uuidString))
        }
        if layer.name.caseInsensitiveCompare("0") == .orderedSame {
            return .failure(.protectedLayer("Layer '0' cannot be deleted."))
        }
        if primary.isXrefDependentLayer(layer) {
            return .failure(.protectedLayer(
                "Layer '\(layer.name)' is xref-dependent and cannot be deleted (Detach the xref)."))
        }
        if primary.activeLayerID == handle {
            return .failure(.activeLayerGuard(
                "Layer '\(layer.name)' is current and cannot be deleted."))
        }
        primary.removeLayer(handle: handle)
        for sibling in siblings where sibling !== primary {
            sibling.pruneViewportOverrides(forDeletedLayer: handle)
        }
        propagate(from: primary, to: siblings)
        return .success(())
    }

    public func renameLayer(
        in primary: CADDocument,
        siblings: [CADDocument] = [],
        from oldName: String,
        to newName: String
    ) -> Result<Outcome, LayerEditError> {
        let trimmedNew = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedNew.isEmpty else { return .failure(.blankName) }
        guard let layer = primary.findLayer(named: oldName) else {
            return .failure(.unknownLayer(oldName))
        }
        if layer.name.caseInsensitiveCompare("0") == .orderedSame {
            return .failure(.protectedLayer("Layer '0' cannot be renamed."))
        }
        if primary.isXrefDependentLayer(layer) {
            return .failure(.protectedLayer(
                "Layer '\(layer.name)' is xref-dependent and cannot be renamed."))
        }
        if let clash = primary.findLayer(named: trimmedNew),
           clash.handle != layer.handle {
            return .failure(.duplicateName(trimmedNew))
        }
        guard var updated = primary.layer(for: layer.handle) else {
            return .failure(.unknownLayer(oldName))
        }
        updated.name = trimmedNew
        primary.storeLayer(updated)
        let propagated = propagate(from: primary, to: siblings)
        return .success(Outcome(layer: updated, propagatedToSiblings: propagated))
    }

    /// Make the named layer current. The current-layer pointer is session
    /// state (like AutoCAD): no undo is pushed, but the layer record
    /// itself is still propagated so siblings stay coherent.
    public func setCurrentLayer(
        in primary: CADDocument,
        siblings: [CADDocument] = [],
        named name: String
    ) -> Result<Outcome, LayerEditError> {
        guard let layer = primary.findLayer(named: name) else {
            return .failure(.unknownLayer(name))
        }
        primary.activeLayerID = layer.handle
        // Session state only: switching the current layer neither pushes
        // undo nor dirties the document (matches direct assignment).
        let propagated = propagate(from: primary, to: siblings)
        return .success(Outcome(layer: layer, propagatedToSiblings: propagated))
    }

    // MARK: Property setters

    public func setVisible(
        in primary: CADDocument, siblings: [CADDocument] = [],
        named name: String, visible: Bool
    ) -> Result<Outcome, LayerEditError> {
        mutate(in: primary, siblings: siblings, named: name) { layer, error in
            if !visible, primary.activeLayerID == layer.handle {
                error = .activeLayerGuard(
                    "Cannot turn off the current layer '\(layer.name)'.")
                return
            }
            layer.isVisible = visible
        }
    }

    public func setFrozen(
        in primary: CADDocument, siblings: [CADDocument] = [],
        named name: String, frozen: Bool
    ) -> Result<Outcome, LayerEditError> {
        mutate(in: primary, siblings: siblings, named: name) { layer, error in
            if frozen, primary.activeLayerID == layer.handle {
                error = .activeLayerGuard(
                    "Cannot freeze the current layer '\(layer.name)'.")
                return
            }
            layer.isFrozen = frozen
        }
    }

    public func setLocked(
        in primary: CADDocument, siblings: [CADDocument] = [],
        named name: String, locked: Bool
    ) -> Result<Outcome, LayerEditError> {
        mutate(in: primary, siblings: siblings, named: name) { layer, error in
            layer.isLocked = locked
        }
    }

    public func setFreezeInNewViewports(
        in primary: CADDocument, siblings: [CADDocument] = [],
        named name: String, freeze: Bool
    ) -> Result<Outcome, LayerEditError> {
        mutate(in: primary, siblings: siblings, named: name) { layer, error in
            layer.freezeInNewViewports = freeze
        }
    }

    public func setDescription(
        in primary: CADDocument, siblings: [CADDocument] = [],
        named name: String, description: String
    ) -> Result<Outcome, LayerEditError> {
        mutate(in: primary, siblings: siblings, named: name) { layer, _ in
            layer.layerDescription = description
        }
    }

    public func setReconciled(
        in primary: CADDocument, siblings: [CADDocument] = [],
        named name: String, reconciled: Bool
    ) -> Result<Outcome, LayerEditError> {
        mutate(in: primary, siblings: siblings, named: name) { layer, _ in
            layer.isReconciled = reconciled
        }
    }

    /// Transparency percent must be within 0...90 (AutoCAD cap).
    public func setTransparency(
        in primary: CADDocument, siblings: [CADDocument] = [],
        named name: String, transparency: Int
    ) -> Result<Outcome, LayerEditError> {
        mutate(in: primary, siblings: siblings, named: name) { layer, error in
            guard (0...90).contains(transparency) else {
                error = .invalidValue(
                    "Transparency \(transparency) is out of range 0...90.")
                return
            }
            layer.transparency = transparency
        }
    }

    /// Lineweights snap to the fixed AutoCAD set (lenient by design).
    public func setLineWeight(
        in primary: CADDocument, siblings: [CADDocument] = [],
        named name: String, lineWeight: Double
    ) -> Result<Outcome, LayerEditError> {
        mutate(in: primary, siblings: siblings, named: name) { layer, error in
            guard lineWeight.isFinite, lineWeight >= 0 else {
                error = .invalidValue("Lineweight must be a finite value >= 0.")
                return
            }
            layer.lineWeight = Layer.nearestFixedLineWeight(lineWeight)
        }
    }

    public func setColor(
        in primary: CADDocument, siblings: [CADDocument] = [],
        named name: String, color: ColorRGBA,
        source: LayerColorSource? = nil
    ) -> Result<Outcome, LayerEditError> {
        mutate(in: primary, siblings: siblings, named: name) { layer, error in
            if let source {
                if case .aci(let index) = source, !(1...255).contains(index) {
                    error = .invalidValue("ACI index \(index) is out of range 1...255.")
                    return
                }
                layer.colorSource = source
            } else if DXFColorTable.isACI(color) {
                layer.colorSource = .aci(Int(DXFColorTable.rgbaToACI(color)))
            } else {
                layer.colorSource = .trueColor
            }
            layer.color = color
        }
    }

    public func setPlotStyle(
        in primary: CADDocument, siblings: [CADDocument] = [],
        named name: String, plotStyleName: String
    ) -> Result<Outcome, LayerEditError> {
        mutate(in: primary, siblings: siblings, named: name) { layer, error in
            let trimmed = plotStyleName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                error = .invalidValue("Plot-style name must not be blank.")
                return
            }
            layer.plotStyleName = trimmed
        }
    }

    public func setLineType(
        in primary: CADDocument, siblings: [CADDocument] = [],
        named name: String, lineType: String
    ) -> Result<Outcome, LayerEditError> {
        mutate(in: primary, siblings: siblings, named: name) { layer, error in
            let trimmed = lineType.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                error = .invalidValue("Linetype name must not be blank.")
                return
            }
            layer.lineType = trimmed.uppercased()
        }
    }

    public func setPlottable(
        in primary: CADDocument, siblings: [CADDocument] = [],
        named name: String, plottable: Bool
    ) -> Result<Outcome, LayerEditError> {
        mutate(in: primary, siblings: siblings, named: name) { layer, _ in
            layer.isPlottable = plottable
        }
    }

    // MARK: Core

    private func mutate(
        in primary: CADDocument,
        siblings: [CADDocument],
        named name: String,
        change: (inout Layer, inout LayerEditError?) -> Void
    ) -> Result<Outcome, LayerEditError> {
        guard let found = primary.findLayer(named: name) else {
            return .failure(.unknownLayer(name))
        }
        guard var layer = primary.layer(for: found.handle) else {
            return .failure(.unknownLayer(name))
        }
        var error: LayerEditError?
        change(&layer, &error)
        if let error { return .failure(error) }
        primary.storeLayer(layer)
        let propagated = propagate(from: primary, to: siblings)
        return .success(Outcome(layer: layer, propagatedToSiblings: propagated))
    }

    /// Outcome of a layer merge: entities re-pointed, sources deleted.
    public struct MergeOutcome: Equatable, Sendable {
        public let target: Layer
        public let moved: Int
        public let deleted: Int
        public let propagatedToSiblings: Int
    }

    /// Merge several source layers into one target (LAYMRG): entities
    /// move, sources are deleted, exactly one undo on the primary plus
    /// a LAYERP checkpoint, with render-only sibling propagation.
    /// Refuses unknown names, merging into itself, protected layers
    /// ("0", xref-dependent) and the current layer as a source — with
    /// no state change on any refusal.
    public func mergeLayers(
        in primary: CADDocument,
        siblings: [CADDocument] = [],
        from sources: [String],
        into target: String
    ) -> Result<MergeOutcome, LayerEditError> {
        guard let targetLayer = primary.findLayer(named: target) else {
            return .failure(.unknownLayer(target))
        }
        var sourceHandles: [UUID] = []
        for name in sources {
            guard let source = primary.findLayer(named: name) else {
                return .failure(.unknownLayer(name))
            }
            if source.handle == targetLayer.handle {
                return .failure(.invalidValue(
                    "Cannot merge layer '\(source.name)' into itself."))
            }
            if source.name.caseInsensitiveCompare("0") == .orderedSame {
                return .failure(.protectedLayer("Layer '0' cannot be merged."))
            }
            if primary.isXrefDependentLayer(source) {
                return .failure(.protectedLayer(
                    "Layer '\(source.name)' is xref-dependent and cannot be merged."))
            }
            if primary.activeLayerID == source.handle {
                return .failure(.activeLayerGuard(
                    "Layer '\(source.name)' is current and cannot be merged."))
            }
            if !sourceHandles.contains(source.handle) {
                sourceHandles.append(source.handle)
            }
        }
        guard !sourceHandles.isEmpty else {
            return .failure(.invalidValue("LAYMRG needs at least one source layer."))
        }
        let report = primary.mergeLayers(sourceHandles: sourceHandles, into: targetLayer.handle)
        let propagated = propagate(from: primary, to: siblings)
        guard let updated = primary.layer(for: targetLayer.handle) else {
            return .failure(.unknownLayer(target))
        }
        return .success(MergeOutcome(
            target: updated, moved: report.moved,
            deleted: report.deleted, propagatedToSiblings: propagated))
    }

    /// Delete a layer together with its entities (LAYDEL): exactly one
    /// undo on the primary plus a LAYERP checkpoint, with render-only
    /// sibling propagation. Same guards as `deleteLayer`, plus the
    /// current layer is refused. Returns the entities deleted.
    public func deleteLayerAndEntities(
        in primary: CADDocument,
        siblings: [CADDocument] = [],
        named name: String
    ) -> Result<Int, LayerEditError> {
        guard let layer = primary.findLayer(named: name) else {
            return .failure(.unknownLayer(name))
        }
        if layer.name.caseInsensitiveCompare("0") == .orderedSame {
            return .failure(.protectedLayer("Layer '0' cannot be deleted."))
        }
        if primary.isXrefDependentLayer(layer) {
            return .failure(.protectedLayer(
                "Layer '\(layer.name)' is xref-dependent and cannot be deleted (Detach the xref)."))
        }
        if primary.activeLayerID == layer.handle {
            return .failure(.activeLayerGuard(
                "Layer '\(layer.name)' is current and cannot be deleted."))
        }
        let count = primary.deleteLayerAndEntities(handle: layer.handle) ?? 0
        propagate(from: primary, to: siblings)
        return .success(count)
    }

    /// Copy entities onto another layer (COPYTOLAYER) in one undo step,
    /// with render-only sibling propagation. Unknown targets fail with
    /// no state change; unknown entity handles are skipped.
    public func copyEntitiesToLayer(
        in primary: CADDocument,
        siblings: [CADDocument] = [],
        handles: Set<UUID>,
        target: String
    ) -> Result<Int, LayerEditError> {
        guard let layer = primary.findLayer(named: target) else {
            return .failure(.unknownLayer(target))
        }
        let count = primary.copyEntitiesToLayer(handles: handles, targetLayer: layer.handle) ?? 0
        propagate(from: primary, to: siblings)
        return .success(count)
    }

    /// Depth of the LAYERP previous-settings stack (layer history).
    public func layerHistoryDepth(in primary: CADDocument) -> Int {
        primary.layerPreviousHistory.depth
    }

    /// Render-only propagation: siblings adopt the primary layer table
    /// without pushing undo or dirtying their revision (same contract as
    /// `DocumentTab.reconcileLayersFromActiveView`).
    @discardableResult
    private func propagate(from primary: CADDocument, to siblings: [CADDocument]) -> Int {
        var count = 0
        for sibling in siblings where sibling !== primary {
            if sibling.adoptLayers(from: primary) { count += 1 }
        }
        return count
    }
}
