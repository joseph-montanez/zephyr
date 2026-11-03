import Foundation

// =========================================================================
// MARK: - Layer parity Phase 2: shared access/style resolver
//
// Single choke point for every layer-gated pipeline decision, so drawing,
// regeneration, picking, snapping, editing, and plotting agree on what a
// layer state means:
//
//   - Off (isVisible == false) ... hidden but KEPT in regeneration: its
//     geometry still resolves (unhide needs no rebuild) while producing no
//     draw output, and it stays out of picking, snapping, editing, and
//     plotting.
//   - Frozen .................. excluded from regeneration entirely (no
//     tessellation work, no output) and from every downstream consumer.
//   - Locked .................. still draws, picks, and snaps; only edits
//     are refused. Pixels dim by `lockFadePercent` (LAYLOCKFADECTL).
//   - No Plot ................. `isPlottable == false` (or the reserved
//     DEFPOINTS layer, which never plots regardless) skips PDF/plot
//     output while staying fully interactive on screen.
//   - Display toggles ......... transparency and lineweight display are
//     render-only switches carried in the snapshot; plotting honors its
//     own PrintLineweights / PlotPlotStyles flags instead.
//   - Plot styles ............. CTB (color-dependent, PSTYLEMODE 1) looks
//     the pen up by ACI; named STB (PSTYLEMODE 0) looks it up by the
//     layer's plot-style name with a "Normal" fallback.
//
// Entity-level helpers return false when the entity's layer is missing
// (unknown layers never grant access); the per-primitive visibility rule
// (`CADPrimitiveVisibility.isVisible`) keeps its own fallback and is
// unchanged.
// =========================================================================

// =========================================================================
// MARK: - LayerDisplayOptions
// =========================================================================

/// Render-only layer display switches. Session state (like isolation):
/// snapshotted for the renderer, never persisted to DXF/EAB, never
/// undoable.
public struct LayerDisplayOptions: Hashable, Sendable {
    /// Locked-layer dim percent, 0...90 (AutoCAD LAYLOCKFADECTL, default 50).
    public var lockFadePercent: Int
    /// TRANSPARENCYDISPLAY: honor layer/entity transparency when true.
    public var transparencyShown: Bool
    /// LWDISPLAY: honor lineweights when true, hairline (0.0) when false.
    /// Screen only; plotting honors PrintLineweights (DXF 70 bit 128).
    public var lineweightsShown: Bool

    public static let `default` = LayerDisplayOptions()

    public init(
        lockFadePercent: Int = 50,
        transparencyShown: Bool = true,
        lineweightsShown: Bool = true
    ) {
        self.lockFadePercent = max(0, min(90, lockFadePercent))
        self.transparencyShown = transparencyShown
        self.lineweightsShown = lineweightsShown
    }

    /// Alpha multiplier for a locked layer (1.0 when unlocked or faded 0).
    /// Two nested locked layers (entity layer + primitive style layer)
    /// multiply; each level dims independently.
    public func lockedMultiplier(isLocked: Bool) -> Double {
        guard isLocked, lockFadePercent > 0 else { return 1.0 }
        return max(0.0, 1.0 - Double(lockFadePercent) / 100.0)
    }

    /// Combined layer x entity opacity, ignoring both when transparency
    /// display is off. Inputs are 0.0...1.0; output is clamped there too.
    public func effectiveOpacity(layerOpacity: Double, entityOpacity: Double) -> Double {
        guard transparencyShown else { return 1.0 }
        return max(0.0, min(1.0, layerOpacity)) * max(0.0, min(1.0, entityOpacity))
    }

    /// Effective lineweight in mm: the authored value, or hairline (0.0)
    /// when lineweight display is off.
    public func effectiveLineWeight(_ mm: Double) -> Double {
        lineweightsShown ? mm : 0.0
    }
}

// =========================================================================
// MARK: - LayerAccess
// =========================================================================

public enum LayerAccess {

    // MARK: Names

    /// The reserved DEFPOINTS layer never plots, whatever its flags say.
    /// Case-insensitive with surrounding whitespace ignored.
    public static func isDefpointsLayerName(_ name: String) -> Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("DEFPOINTS") == .orderedSame
    }

    // MARK: Layer policy

    /// On screen: on and not frozen. Locked layers still draw.
    public static func isDrawn(_ layer: Layer) -> Bool {
        layer.isEffectivelyVisible
    }

    /// In regeneration: everything except frozen. Off layers keep their
    /// resolved geometry (unhide is free) while emitting no draw output.
    public static func isRegenerated(_ layer: Layer) -> Bool {
        !layer.isFrozen
    }

    /// Pickable (click/rect/lasso/select-all/grips): drawn layers only.
    /// Locked layers stay selectable; frozen and off layers do not.
    public static func isPickable(_ layer: Layer) -> Bool {
        isDrawn(layer)
    }

    /// Snappable: drawn layers only. Locked layers keep their snaps;
    /// frozen and off layers offer none.
    public static func isSnappable(_ layer: Layer) -> Bool {
        isDrawn(layer)
    }

    /// Editable (grips, vertex drags): drawn and not locked.
    public static func isEditable(_ layer: Layer) -> Bool {
        isDrawn(layer) && !layer.isLocked
    }

    /// Plottable (PDF/plot output): the NoPlot flag honored, plus the
    /// reserved DEFPOINTS layer which never plots. Screen visibility is
    /// NOT consulted here; callers combine with `isDrawn` (frozen and
    /// off layers never reach the plotter).
    public static func isPlottable(_ layer: Layer) -> Bool {
        layer.isPlottable && !isDefpointsLayerName(layer.name)
    }

    /// Alpha multiplier for a layer's pixels under a display configuration.
    public static func lockedFadeMultiplier(
        layer: Layer?, fadePercent: Int
    ) -> Double {
        guard let layer, layer.isLocked, fadePercent > 0 else { return 1.0 }
        return max(0.0, 1.0 - Double(max(0, min(90, fadePercent))) / 100.0)
    }

    // MARK: Entity policy (missing layer grants nothing)

    public static func layer(for entity: CADEntity, in document: CADDocument) -> Layer? {
        document.layer(for: entity.layerID)
    }

    public static func isDrawn(entity: CADEntity, in document: CADDocument) -> Bool {
        guard let layer = layer(for: entity, in: document) else { return false }
        guard !isFrozenInViewport(entity, in: document) else { return false }
        return isDrawn(layer)
    }

    public static func isRegenerated(entity: CADEntity, in document: CADDocument) -> Bool {
        guard let layer = layer(for: entity, in: document) else { return false }
        guard !isFrozenInViewport(entity, in: document) else { return false }
        return isRegenerated(layer)
    }

    public static func isPickable(entity: CADEntity, in document: CADDocument) -> Bool {
        guard let layer = layer(for: entity, in: document) else { return false }
        guard !isFrozenInViewport(entity, in: document) else { return false }
        return isPickable(layer)
    }

    public static func isSnappable(entity: CADEntity, in document: CADDocument) -> Bool {
        guard let layer = layer(for: entity, in: document) else { return false }
        guard !isFrozenInViewport(entity, in: document) else { return false }
        return isSnappable(layer)
    }

    public static func isEditable(entity: CADEntity, in document: CADDocument) -> Bool {
        guard let layer = layer(for: entity, in: document) else { return false }
        guard !isFrozenInViewport(entity, in: document) else { return false }
        return isEditable(layer)
    }

    public static func isPlottable(entity: CADEntity, in document: CADDocument) -> Bool {
        guard let layer = layer(for: entity, in: document) else { return false }
        guard !isFrozenInViewport(entity, in: document) else { return false }
        return isPlottable(layer)
    }

    // MARK: Plot-style resolution (CTB vs named STB)

    /// Resolve the plot-style pen for one layer under a plot table.
    /// CTB mode (pstyleMode 1) keys by ACI; named-STB mode (pstyleMode 0)
    /// keys by the layer's plot-style name with a "Normal" fallback
    /// (case-insensitive, like `PlotStyleTable.pen(named:)`). A nil table
    /// (no style sheet assigned) resolves to nil: object color/lineweight.
    public static func plotPen(
        layer: Layer?,
        objectACI: Int,
        pstyleMode: Int,
        table: PlotStyleTable?
    ) -> PlotStylePen? {
        guard let table else { return nil }
        if pstyleMode == 0 {
            let raw = layer?.plotStyleName.trimmingCharacters(
                in: .whitespacesAndNewlines) ?? ""
            let key = raw.isEmpty ? "Normal" : raw
            return table.pen(named: key) ?? table.pen(named: "Normal")
        } else {
            return table.pen(forACI: objectACI)
        }
    }

    // MARK: Regeneration plan

    /// Which entities regeneration processes vs actually draws. `regenerated`
    /// keeps Off-layer geometry (hidden, no output); `drawn` is the subset
    /// with visible output. Frozen layers and per-entity-isolated handles
    /// appear in neither. Mirrors `CADRendererBridge.computeSpecs` filters
    /// so tests can assert the split without running the tessellator.
    public struct RegenerationPlan: Sendable, Equatable {
        public var regenerated: Set<UUID>
        public var drawn: Set<UUID>

        public init(regenerated: Set<UUID> = [], drawn: Set<UUID> = []) {
            self.regenerated = regenerated
            self.drawn = drawn
        }
    }

    public static func regenerationPlan(
        snapshot: CADDocumentSnapshot
    ) -> RegenerationPlan {
        var regenerated = Set<UUID>()
        var drawn = Set<UUID>()
        for (handle, entity) in snapshot.entities {
            guard let layer = snapshot.layers[entity.layerID],
                  isRegenerated(layer) else { continue }
            guard !snapshot.isolatedHiddenHandles.contains(handle) else { continue }
            guard !isFrozenInViewport(entity, in: snapshot) else { continue }
            regenerated.insert(handle)
            if isDrawn(layer) { drawn.insert(handle) }
        }
        return RegenerationPlan(regenerated: regenerated, drawn: drawn)
    }
}
