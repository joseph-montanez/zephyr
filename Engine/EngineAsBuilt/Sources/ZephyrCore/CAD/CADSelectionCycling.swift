import Foundation

// =========================================================================
// MARK: - CADSelectionCycling
//
// AutoCAD Selection Cycling support: sysvar backing store, hover-cycle
// state helpers, row labels, and the shared pick resolver decision.
// =========================================================================

/// Backing store for the `SELECTIONCYCLING` sysvar.
///
/// AutoCAD values: 0 = off, 1 = badge + Shift+Space cycling only,
/// 2 = badge + cycling + Selection list. Negative values mean "off but
/// remember the setting" (-1 remembers 1, -2 remembers 2).
/// Single source of truth shared by the hover coordinator, the click
/// resolver, and the Lisp `getvar`/`setvar` bridge. Mirrors the
/// `TrimSettings` sharing pattern (lock-guarded, nonisolated).
public enum SelectionCyclingSettings: Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var storedValue: Int = 2

    /// Current raw value in -2...2. Defaults to 2 (restored behavior on).
    public static var value: Int {
        get { lock.withLock { storedValue } }
        set {
            let clamped = max(-2, min(2, newValue))
            lock.withLock { storedValue = clamped }
        }
    }

    /// True when hover badges and Shift+Space cycling are active (1 or 2).
    public static var isEnabled: Bool { value > 0 }

    /// True when a multi-hit click should open the Selection list (2 only).
    public static var showsList: Bool { value == 2 }

    /// Unified toggle used by the status-bar button (Ctrl+W stays bound to
    /// tab close in Zephyr, so it does not toggle cycling).
    /// 0 -> 2, positive -> negative (remember), negative -> positive.
    @discardableResult
    public static func toggle() -> Int {
        let current = value
        let next = (current == 0) ? 2 : -current
        value = next
        return next
    }
}

/// Pure resolver decision for a click with N hits. Unit-testable without
/// an engine harness.
public enum SelectionCyclingResolver: Sendable {
    /// Whether a click with `hitCount` hits should open the Selection list.
    /// Mode 2 opens the list only when the user has NOT already armed a
    /// hover-cycled candidate (an explicit Shift+Space choice wins).
    public static func shouldOpenList(
        hitCount: Int, mode: Int, hasActiveCycle: Bool
    ) -> Bool {
        guard mode == 2, hitCount >= 2, !hasActiveCycle else { return false }
        return true
    }

    /// Whether the Selection list should be offered before starting a
    /// grip drag. Block references expose a grip for every nested
    /// vertex/midpoint, so in a genuine pile a block-member grip is
    /// almost always near the cursor; letting it preempt would make
    /// the list unreachable exactly where it is needed (the screenshot
    /// case: 584 grips on one INSERT). Loose-entity and special grips
    /// keep their normal priority.
    public static func shouldOpenListBeforeGrip(
        isBlockMemberGrip: Bool,
        hitCount: Int, mode: Int, hasActiveCycle: Bool
    ) -> Bool {
        isBlockMemberGrip
            && shouldOpenList(
                hitCount: hitCount, mode: mode, hasActiveCycle: hasActiveCycle)
    }
}

/// Row labels and swatch colors for the Selection list. Same-module access
/// to `LispEntityAdapter` keeps DXF type names consistent with ssget/entget.
enum CADSelectionCyclingLabels {
    /// Short display type: dimensions/leaders/tables first (their generated
    /// geometry would otherwise report as LINE/LWPOLYLINE), then block
    /// names for INSERTs, then the DXF type name.
    static func displayType(for entity: CADEntity, document: CADDocument) -> String {
        if entity.dimensionMetadata != nil { return "Dimension" }
        if entity.leaderData != nil { return "Leader" }
        if let blockID = entity.blockID, let block = document.block(for: blockID) {
            if block.isInternalTableDisplayBlock { return "Table" }
            return "Block \(block.name)"
        }
        return LispEntityAdapter.dxfTypeName(entity: entity, document: document)
    }

    static func isLocked(_ entity: CADEntity, document: CADDocument) -> Bool {
        document.layer(for: entity.layerID)?.isLocked ?? false
    }

    /// `Type · Layer`, with a short-handle suffix only when sibling rows
    /// would otherwise read identically, and a locked marker for
    /// locked-layer rows (locked layers stay pickable by design).
    static func label(
        for entity: CADEntity, document: CADDocument, needsDisambiguation: Bool
    ) -> String {
        let layer = document.layer(for: entity.layerID)?.name ?? "0"
        var text = "\(displayType(for: entity, document: document)) · \(layer)"
        if needsDisambiguation {
            text += " (#\(entity.handle.uuidString.prefix(8)))"
        }
        if isLocked(entity, document: document) {
            text += " [locked]"
        }
        return text
    }

    /// Effective display color: explicit entity color override wins,
    /// otherwise the layer color. Mirrors the resolution in
    /// `CADRendererBridge` without opacity/fade adjustments (swatch only).
    static func effectiveColor(for entity: CADEntity, document: CADDocument) -> ColorRGBA {
        if let cv = entity.xdata["dxf.color"], case .string(let hex) = cv,
           let c = ColorRGBA(hex: hex) {
            return c
        }
        if let layer = document.layer(for: entity.layerID) {
            return layer.color
        }
        return .white
    }
}
