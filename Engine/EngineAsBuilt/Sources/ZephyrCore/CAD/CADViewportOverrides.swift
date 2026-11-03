import Foundation

// =========================================================================
// MARK: - Layer parity Phase 3: per-viewport (per-layout) layer overrides
//
// AutoCAD lets every floating layout viewport freeze its own layer set
// (VPFREEZE) and restyle layers just for that viewport (VP color /
// linetype / lineweight / transparency / plot style). The global layer
// table stays drawing-global; the viewport deltas live on the sheet
// (layout) document only, keyed by viewport identity:
//
//   viewport stable key -> layer handle string -> ViewportLayerOverride
//
// Semantics (deliberately narrow, matching AutoCAD):
//
//   - Overrides apply ONLY to viewport-projected (derived) entities.
//     Global model entities always resolve through the plain layer table,
//     so model space never changes under a sheet edit.
//   - An override can only ADD freezing: a globally off/frozen layer stays
//     off/frozen everywhere, and no override can resurrect it.
//   - Frozen-in-viewport behaves like frozen: excluded from regeneration,
//     draw output, picking, snapping, editing, and plotting.
//   - Style overrides recolor/restyle projected copies for screen render
//     and plot output; they never mutate the stored layer or entity.
//
// Identity: every floating viewport carries a stable string key. New
// viewports get a UUID; definitions recovered from legacy content without
// a stored key fall back to "VPID-<n>". DXF round-trips the key via
// ZEPHYR_VP XDATA; EAB persists the whole map in its own additive section.
// =========================================================================

/// Per-viewport layer delta store: viewport stable key -> layer-handle
/// string (UUID.uuidString) -> override. Lives on the sheet document and
/// in its render snapshot; never on model documents.
public typealias ViewportOverrideMap = [String: [String: ViewportLayerOverride]]

// =========================================================================
// MARK: - ViewportLayerOverride
// =========================================================================

/// One viewport's delta for one layer. Every field is optional except
/// `frozen`: nil means "inherit the global layer value".
public struct ViewportLayerOverride: Sendable, Equatable, Hashable {
    /// Viewport-local freeze (DXF VIEWPORT group 331). Adds to, never
    /// removes, the global frozen/off state.
    public var frozen: Bool
    public var color: ColorRGBA?
    public var colorSource: LayerColorSource?
    public var lineType: String?
    public var lineWeight: Double?
    public var transparency: Int?
    public var plotStyleName: String?

    public init(
        frozen: Bool = false,
        color: ColorRGBA? = nil,
        colorSource: LayerColorSource? = nil,
        lineType: String? = nil,
        lineWeight: Double? = nil,
        transparency: Int? = nil,
        plotStyleName: String? = nil
    ) {
        self.frozen = frozen
        self.color = color
        self.colorSource = colorSource
        self.lineType = lineType
        self.lineWeight = lineWeight
        self.transparency = transparency
        self.plotStyleName = plotStyleName
    }

    /// True when no field carries a delta (safe to drop from storage).
    public var isEmpty: Bool {
        !frozen && color == nil && colorSource == nil && lineType == nil
            && lineWeight == nil && transparency == nil && plotStyleName == nil
    }

    /// Layer copy with the style deltas applied. Frozen is handled by
    /// callers (exclusion), never by restyling.
    public func applied(to layer: Layer) -> Layer {
        var result = layer
        if let color { result.color = color }
        if let colorSource { result.colorSource = colorSource }
        if let lineType {
            let trimmed = lineType.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { result.lineType = trimmed.uppercased() }
        }
        if let lineWeight {
            result.lineWeight = Layer.nearestFixedLineWeight(lineWeight)
        }
        if let transparency {
            result.transparency = Layer.clampedTransparency(transparency)
        }
        if let plotStyleName {
            let trimmed = plotStyleName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { result.plotStyleName = trimmed }
        }
        return result
    }
}

// =========================================================================
// MARK: - Viewport identity
// =========================================================================

public enum ViewportIdentity {
    /// Fresh stable key for a newly created viewport.
    public static func makeStableID() -> String { UUID().uuidString }

    /// Deterministic key for viewport definitions recovered from content
    /// that predates stable IDs (legacy xdata / legacy DXF).
    public static func fallbackKey(viewportNumber id: Int) -> String { "VPID-\(id)" }

    /// Storage key for a layer handle.
    public static func layerKey(_ handle: UUID) -> String { handle.uuidString }

    /// The viewport key tagging a projected entity, or nil for native
    /// (model/paper) geometry.
    public static func stableID(of entity: CADEntity) -> String? {
        guard case .string(let value)? = entity.xdata["dxf.viewport.stableID"],
              !value.isEmpty else { return nil }
        return value
    }
}

// =========================================================================
// MARK: - Override record codec (DXF XDATA + tests)
// =========================================================================

/// String codec for one viewport style/freeze record. Format:
///
///   ZVP|LAYER=<escaped name>|F=0|1|C=#RRGGBB[AA]|CS=ACI:n|RGB|BOOK:name|
///   LT=<linetype>|LW=<mm>|TR=<0-90>|PS=<plot style>
///
/// Only non-nil fields are emitted (plus F, always). `\`, `|`, `=`, `;`
/// in names are backslash-escaped.
public enum ViewportOverrideRecord {
    public static let prefix = "ZVP|"

    public static func encode(layerName: String, override: ViewportLayerOverride) -> String {
        var parts = ["ZVP", "LAYER=\(escape(layerName))", "F=\(override.frozen ? 1 : 0)"]
        if let color = override.color {
            parts.append("C=\(hex(color))")
        }
        if let source = override.colorSource {
            switch source {
            case .aci(let index): parts.append("CS=ACI:\(index)")
            case .trueColor: parts.append("CS=RGB")
            case .colorBook(let name): parts.append("CS=BOOK:\(escape(name))")
            }
        }
        if let lineType = override.lineType { parts.append("LT=\(escape(lineType))") }
        if let lineWeight = override.lineWeight {
            parts.append("LW=\(String(format: "%.4g", lineWeight))")
        }
        if let transparency = override.transparency { parts.append("TR=\(transparency)") }
        if let plotStyleName = override.plotStyleName {
            parts.append("PS=\(escape(plotStyleName))")
        }
        return parts.joined(separator: "|")
    }

    public static func decode(_ record: String) -> (layerName: String, override: ViewportLayerOverride)? {
        guard record.hasPrefix(prefix) else { return nil }
        let fields = split(record)
        var layerName: String?
        var override = ViewportLayerOverride()
        for field in fields {
            guard let eq = field.firstIndex(of: "=") else { continue }
            let key = String(field[..<eq])
            let value = unescape(String(field[field.index(after: eq)...]))
            switch key {
            case "LAYER": layerName = value
            case "F": override.frozen = (Int(value) ?? 0) != 0
            case "C":
                if let color = ColorRGBA(hex: value) { override.color = color }
            case "CS":
                if value.hasPrefix("ACI:") {
                    if let index = Int(value.dropFirst(4)), (1...255).contains(index) {
                        override.colorSource = .aci(index)
                    }
                } else if value == "RGB" {
                    override.colorSource = .trueColor
                } else if value.hasPrefix("BOOK:") {
                    let name = String(value.dropFirst(5))
                    if !name.isEmpty { override.colorSource = .colorBook(name: name) }
                }
            case "LT":
                if !value.isEmpty { override.lineType = value }
            case "LW":
                if let weight = Double(value), weight.isFinite, weight >= 0 {
                    override.lineWeight = weight
                }
            case "TR":
                if let percent = Int(value) { override.transparency = percent }
            case "PS":
                if !value.isEmpty { override.plotStyleName = value }
            default: break
            }
        }
        guard let layerName, !layerName.isEmpty else { return nil }
        return (layerName, override)
    }

    // MARK: Private

    private static func hex(_ color: ColorRGBA) -> String {
        String(format: "#%02X%02X%02X", color.r, color.g, color.b)
    }

    private static func escape(_ value: String) -> String {
        var result = ""
        for ch in value {
            if ch == "\\" || ch == "|" || ch == "=" || ch == ";" { result.append("\\") }
            result.append(ch)
        }
        return result
    }

    /// Split on unescaped "|", preserving escape sequences for the
    /// single `unescape` pass in `decode` (splitting must not consume
    /// backslashes or `\\` would collapse one pass too early).
    private static func split(_ record: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var escaped = false
        for ch in record {
            if escaped {
                current.append("\\")
                current.append(ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "|" {
                fields.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        if escaped { current.append("\\") }
        fields.append(current)
        return fields
    }

    private static func unescape(_ value: String) -> String {
        var result = ""
        var escaped = false
        for ch in value {
            if escaped {
                result.append(ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else {
                result.append(ch)
            }
        }
        if escaped { result.append("\\") }
        return result
    }
}

// =========================================================================
// MARK: - LayerAccess viewport resolution
// =========================================================================

public extension LayerAccess {
    /// The override governing a projected entity in its owning document,
    /// or nil for native geometry / unknown viewports / absent deltas.
    /// Model documents never carry overrides, so their entities resolve nil.
    static func viewportOverride(
        for entity: CADEntity, in document: CADDocument
    ) -> ViewportLayerOverride? {
        guard let stableID = ViewportIdentity.stableID(of: entity) else { return nil }
        return document.viewportLayerOverrides[stableID]?[ViewportIdentity.layerKey(entity.layerID)]
    }

    /// Snapshot variant for render/regen paths.
    static func viewportOverride(
        for entity: CADEntity, in snapshot: CADDocumentSnapshot
    ) -> ViewportLayerOverride? {
        guard let stableID = ViewportIdentity.stableID(of: entity) else { return nil }
        return snapshot.viewportOverrides[stableID]?[ViewportIdentity.layerKey(entity.layerID)]
    }

    /// The layer with viewport style deltas applied (frozen excluded by
    /// callers). Returns the base layer when no override applies.
    static func effectiveLayer(
        for entity: CADEntity, in document: CADDocument
    ) -> Layer? {
        guard let base = layer(for: entity, in: document) else { return nil }
        guard let override = viewportOverride(for: entity, in: document) else { return base }
        return override.applied(to: base)
    }

    /// Snapshot variant for render/regen paths.
    static func effectiveLayer(
        for entity: CADEntity, in snapshot: CADDocumentSnapshot
    ) -> Layer? {
        guard let base = snapshot.layers[entity.layerID] else { return nil }
        guard let override = viewportOverride(for: entity, in: snapshot) else { return base }
        return override.applied(to: base)
    }

    /// Viewport-local freeze adds to (never removes) global frozen/off.
    static func isFrozenInViewport(
        _ entity: CADEntity, in document: CADDocument
    ) -> Bool {
        viewportOverride(for: entity, in: document)?.frozen == true
    }

    /// Snapshot variant for render/regen paths.
    static func isFrozenInViewport(
        _ entity: CADEntity, in snapshot: CADDocumentSnapshot
    ) -> Bool {
        viewportOverride(for: entity, in: snapshot)?.frozen == true
    }

}

// =========================================================================
// MARK: - CADDocument viewport-override storage
// =========================================================================

public extension CADDocument {
    /// Set (or replace) the frozen flag for one layer in one viewport.
    /// Clearing the last delta of a layer drops its record; clearing the
    /// last record of a viewport drops the viewport key. One undo step.
    func setViewportLayerFrozen(viewportID: String, layer handle: UUID, frozen: Bool) {
        var current = viewportOverride(viewportID: viewportID, layer: handle) ?? ViewportLayerOverride()
        current.frozen = frozen
        setViewportLayerOverride(viewportID: viewportID, layer: handle, override: current)
    }

    /// Set (or replace) the full override record for one layer in one
    /// viewport. An empty record removes the layer entry. One undo step.
    func setViewportLayerOverride(
        viewportID: String, layer handle: UUID, override: ViewportLayerOverride
    ) {
        let key = viewportID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        pushUndo()
        if override.isEmpty {
            viewportLayerOverrides[key]?.removeValue(forKey: ViewportIdentity.layerKey(handle))
            if viewportLayerOverrides[key]?.isEmpty == true {
                viewportLayerOverrides.removeValue(forKey: key)
            }
        } else {
            viewportLayerOverrides[key, default: [:]][ViewportIdentity.layerKey(handle)] = override
        }
        markEdited(regenerate: true)
    }

    /// Freeze (or thaw) many layers in one viewport in a single undo step.
    /// Creation-time path for freeze-in-new-viewport layers.
    func setViewportLayersFrozen(viewportID: String, layers handles: [UUID], frozen: Bool) {
        let key = viewportID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !handles.isEmpty else { return }
        pushUndo()
        for handle in handles {
            let layerKey = ViewportIdentity.layerKey(handle)
            var current = viewportLayerOverrides[key]?[layerKey] ?? ViewportLayerOverride()
            current.frozen = frozen
            if current.isEmpty {
                viewportLayerOverrides[key]?.removeValue(forKey: layerKey)
            } else {
                viewportLayerOverrides[key, default: [:]][layerKey] = current
            }
        }
        if viewportLayerOverrides[key]?.isEmpty == true {
            viewportLayerOverrides.removeValue(forKey: key)
        }
        markEdited(regenerate: true)
    }

    /// Drop every override for one viewport (e.g. viewport deleted).
    /// No-op (no undo) when the viewport carries nothing.
    func clearViewportOverrides(forViewport viewportID: String) {
        guard viewportLayerOverrides[viewportID] != nil else { return }
        pushUndo()
        viewportLayerOverrides.removeValue(forKey: viewportID)
        markEdited(regenerate: true)
    }

    /// Drop every override referencing a deleted layer handle.
    func pruneViewportOverrides(forDeletedLayer handle: UUID) {
        if pruneViewportOverridesInPlace(forDeletedLayer: handle) {
            markNeedsRegeneration()
        }
    }

    /// Prune without undo or regeneration signaling, for use inside an
    /// outer undo step (`removeLayer`). Returns whether anything changed.
    @discardableResult
    func pruneViewportOverridesInPlace(forDeletedLayer handle: UUID) -> Bool {
        let layerKey = ViewportIdentity.layerKey(handle)
        var changed = false
        for viewportID in viewportLayerOverrides.keys {
            if viewportLayerOverrides[viewportID]?.removeValue(forKey: layerKey) != nil {
                changed = true
                if viewportLayerOverrides[viewportID]?.isEmpty == true {
                    viewportLayerOverrides.removeValue(forKey: viewportID)
                }
            }
        }
        return changed
    }

    /// The override for one layer in one viewport, if any.
    func viewportOverride(viewportID: String, layer handle: UUID) -> ViewportLayerOverride? {
        viewportLayerOverrides[viewportID]?[ViewportIdentity.layerKey(handle)]
    }

    /// Viewport-local freeze for one layer (false for unknown records).
    func isLayerFrozenInViewport(viewportID: String, layer handle: UUID) -> Bool {
        viewportOverride(viewportID: viewportID, layer: handle)?.frozen == true
    }

    /// All viewport keys carrying overrides (sorted, for IO/tests).
    var viewportOverrideKeys: [String] {
        viewportLayerOverrides.keys.sorted()
    }
}
