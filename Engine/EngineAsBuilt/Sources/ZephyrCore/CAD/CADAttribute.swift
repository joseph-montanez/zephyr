import Foundation

// =========================================================================
// MARK: - Block attributes (ATTDEF / ATTEDIT / ATTSYNC)
// =========================================================================

/// An attribute definition (DXF ATTDEF) living inside a block definition.
/// The definition fixes the tag, prompt, default value, and text placement
/// in block space; each INSERT carries per-tag values in
/// `CADEntity.attributeValues`.
public struct CADAttributeDefinition: Hashable, Sendable {
    /// Attribute tag (group 2). Matched case-insensitively; stored as authored.
    public var tag: String
    /// Prompt shown when asking for a value (group 3).
    public var prompt: String
    /// Default text (group 1).
    public var defaultValue: String
    /// Insertion point in block space (groups 10/20/30).
    public var position: Vector3
    /// Text height (group 40).
    public var height: Double
    /// Text rotation in radians (group 50, stored degrees in DXF).
    public var rotation: Double
    /// Text style name (group 7).
    public var style: String?
    /// Horizontal justification (group 72).
    public var alignH: Int
    /// Vertical justification (group 74).
    public var alignV: Int
    /// Raw DXF attribute flags (group 70): bit 0 (1) invisible,
    /// bit 1 (2) constant, bit 2 (4) verify, bit 3 (8) preset.
    public var flags: Int
    /// Layer the definition was authored on. "0"/empty inherits the insert.
    public var layerName: String?

    public init(
        tag: String,
        prompt: String = "",
        defaultValue: String = "",
        position: Vector3 = .zero,
        height: Double = 2.5,
        rotation: Double = 0,
        style: String? = nil,
        alignH: Int = 0,
        alignV: Int = 0,
        flags: Int = 0,
        layerName: String? = nil
    ) {
        self.tag = tag
        self.prompt = prompt
        self.defaultValue = defaultValue
        self.position = position
        self.height = height
        self.rotation = rotation
        self.style = style
        self.alignH = alignH
        self.alignV = alignV
        self.flags = flags
        self.layerName = layerName
    }

    /// Canonical lookup key: tags match case-insensitively per DXF.
    public var key: String { tag.uppercased() }

    public var isInvisible: Bool { (flags & 1) != 0 }
    public var isConstant: Bool { (flags & 2) != 0 }
    public var isVerify: Bool { (flags & 4) != 0 }
    public var isPreset: Bool { (flags & 8) != 0 }
}

/// A per-INSERT attribute value (DXF ATTRIB). Placement overrides are nil
/// when the value follows its definition (the ATTSYNC-normalized state);
/// the importer preserves moved ATTRIBs here instead of losing them.
public struct CADAttributeValue: Hashable, Sendable {
    public var value: String
    public var position: Vector3?
    public var height: Double?
    public var rotation: Double?

    public init(
        value: String,
        position: Vector3? = nil,
        height: Double? = nil,
        rotation: Double? = nil
    ) {
        self.value = value
        self.position = position
        self.height = height
        self.rotation = rotation
    }
}

// =========================================================================
// MARK: - Sync (ATTSYNC semantics)
// =========================================================================

/// Pure ATTSYNC engine: re-applies a block's definitions to one insert's
/// values. Missing tags are added with defaults, orphaned tags (no longer
/// defined) are dropped, edited values are preserved, and placement
/// overrides are reset so text follows the current definition.
public enum CADAttributeSync {
    public static func apply(
        definitions: [CADAttributeDefinition],
        to values: [String: CADAttributeValue]
    ) -> [String: CADAttributeValue] {
        var synced: [String: CADAttributeValue] = [:]
        synced.reserveCapacity(definitions.count)
        for def in definitions {
            if let existing = values[def.key] {
                synced[def.key] = CADAttributeValue(value: existing.value)
            } else {
                synced[def.key] = CADAttributeValue(value: def.defaultValue)
            }
        }
        return synced
    }
}

// =========================================================================
// MARK: - Display synthesis
// =========================================================================

/// One resolved attribute row ready to render: definition placement in
/// block space with the insert's value (or the default when unset).
public struct CADResolvedAttribute: Sendable {
    public var definition: CADAttributeDefinition
    public var text: String
    public var position: Vector3
    public var height: Double
    public var rotation: Double
}

public enum CADAttributeDisplay {
    /// Resolves display rows for an insert. Invisible definitions are
    /// skipped (matching the importer's render gate); constant definitions
    /// always show the default value; rows with empty text are skipped.
    /// Orphaned values (no matching definition) render from their stored
    /// placement so imported content is never silently dropped.
    public static func resolve(
        definitions: [CADAttributeDefinition],
        values: [String: CADAttributeValue]
    ) -> [CADResolvedAttribute] {
        var rows: [CADResolvedAttribute] = []
        rows.reserveCapacity(definitions.count)
        for def in definitions {
            guard !def.isInvisible else { continue }
            let stored = values[def.key]
            let text = def.isConstant ? def.defaultValue : (stored?.value ?? def.defaultValue)
            guard !text.isEmpty else { continue }
            rows.append(CADResolvedAttribute(
                definition: def,
                text: text,
                position: stored?.position ?? def.position,
                height: stored?.height ?? def.height,
                rotation: stored?.rotation ?? def.rotation))
        }
        let definedKeys = Set(definitions.map(\.key))
        for key in values.keys.sorted() where !definedKeys.contains(key) {
            guard let stored = values[key], !stored.value.isEmpty else { continue }
            let surrogate = CADAttributeDefinition(
                tag: key,
                defaultValue: stored.value,
                position: stored.position ?? .zero,
                height: stored.height ?? 2.5,
                rotation: stored.rotation ?? 0)
            rows.append(CADResolvedAttribute(
                definition: surrogate,
                text: stored.value,
                position: surrogate.position,
                height: surrogate.height,
                rotation: surrogate.rotation))
        }
        return rows
    }

    /// Display rows as block-local `.text` primitives plus the definition
    /// layer each row inherits. The caller renders them through the normal
    /// text path so style/rotation handling matches baked text exactly.
    public static func styledPrimitives(
        definitions: [CADAttributeDefinition],
        values: [String: CADAttributeValue]
    ) -> [(primitive: CADPrimitive, layerName: String?)] {
        resolve(definitions: definitions, values: values).map { row in
            (primitive: CADPrimitive.text(
                position: row.position,
                text: row.text,
                height: row.height,
                rotation: row.rotation,
                style: row.definition.style,
                alignH: row.definition.alignH,
                alignV: row.definition.alignV,
                mtextWidth: nil,
                color: nil),
             layerName: row.definition.layerName)
        }
    }

    /// Display rows as block-local `.text` primitives. The caller renders
    /// them through the normal text path so style/rotation handling matches
    /// baked text exactly.
    public static func textPrimitives(
        definitions: [CADAttributeDefinition],
        values: [String: CADAttributeValue]
    ) -> [CADPrimitive] {
        styledPrimitives(definitions: definitions, values: values).map(\.primitive)
    }
}
