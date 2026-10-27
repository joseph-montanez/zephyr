// Sources/ZephyrCore/CAD/EntityFilter.swift
import Foundation

/// Shared entity-matching core for Phase 2.2 selection commands
/// (SELECTSIMILAR now; QSELECT/FILTER next). Pure and headless-testable;
/// presentation (commands, dialogs) lives elsewhere.
///
/// Layer policy: matches respect the on/off visibility model — entities on
/// invisible layers never match. Frozen/locked layers do not exist in the
/// model yet (isolation fade stands in), so there is nothing further to
/// honor; this function is the single place to extend when they land.
public enum EntityFilter {

    // MARK: - SELECTSIMILARMODE bits (AutoCAD values)

    public static let matchType = 1
    public static let matchLayer = 2
    public static let matchColor = 4
    public static let matchLinetype = 8
    public static let matchLineweight = 16
    /// 32 (plot style) and 64 (object style) have no model behind them.
    public static let matchName = 128
    public static let supportedBits =
        matchType | matchLayer | matchColor | matchLinetype | matchLineweight | matchName
    public static let defaultMode = 130 // layer + name, like AutoCAD

    // MARK: - Visibility

    /// Mirrors CADSelectionManager.selectAll: invisible layers never select.
    public static func isVisibleForSelection(
        _ entity: CADEntity, in document: CADDocument
    ) -> Bool {
        guard let layer = document.layer(for: entity.layerID) else { return true }
        return layer.isVisible
    }

    // MARK: - Wildcard

    /// Case-insensitive `*` (any run) and `?` (one character) matching.
    /// Anything else in the pattern is literal.
    public static func wildcardMatch(_ value: String, pattern: String) -> Bool {
        let v = Array(value.uppercased())
        let p = Array(pattern.uppercased())
        var vi = 0
        var pi = 0
        var star: Int? = nil
        var mark = 0
        while vi < v.count {
            if pi < p.count && (p[pi] == "?" || p[pi] == v[vi]) {
                vi += 1
                pi += 1
            } else if pi < p.count && p[pi] == "*" {
                star = pi
                mark = vi
                pi += 1
            } else if let s = star {
                pi = s + 1
                mark += 1
                vi = mark
            } else {
                return false
            }
        }
        while pi < p.count && p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    // MARK: - Similarity

    /// Display name for the name criterion: block name for inserts, style
    /// name for text/dimension/leader content, nil for everything else.
    public static func displayName(
        of entity: CADEntity, in document: CADDocument
    ) -> String? {
        if let blockID = entity.blockID {
            return document.block(for: blockID)?.name
        }
        if let box = entity.dimensionMetadata {
            return box.value.styleName
        }
        if let leader = entity.leaderData?.value {
            return leader.styleName
        }
        guard let geom = entity.localGeometry else { return nil }
        for prim in geom {
            if case .text(_, _, _, _, let style, _, _, _, _) = prim {
                return style
                    ?? entity.xdata["dxf.textStyle"].flatMap {
                        if case .string(let name) = $0 { return name }
                        return nil
                    }
            }
        }
        return nil
    }

    /// Effective linetype: explicit `dxf.lineType` wins, otherwise the
    /// layer default (BYLAYER semantics, mirroring the renderer).
    public static func effectiveLineType(
        of entity: CADEntity, in document: CADDocument
    ) -> String {
        if case .string(let name) = entity.xdata["dxf.lineType"],
           !name.isEmpty,
           name.uppercased() != "BYLAYER" {
            return name
        }
        return document.layer(for: entity.layerID)?.lineType ?? "CONTINUOUS"
    }

    /// Effective lineweight in mm: explicit `dxf.lineWeight` wins,
    /// otherwise the layer default (mirroring the renderer).
    public static func effectiveLineWeight(
        of entity: CADEntity, in document: CADDocument
    ) -> Double {
        if case .double(let w) = entity.xdata["dxf.lineWeight"], w >= 0 {
            return w
        }
        return document.layer(for: entity.layerID)?.lineWeight ?? 0.25
    }

    /// True when the candidate matches the reference on every set
    /// supported bit. Set-but-unsupported bits (plot/object style) are
    /// ignored here and reported by `ignoredModeBits`.
    public static func similar(
        to reference: CADEntity, candidate: CADEntity,
        mode: Int, in document: CADDocument
    ) -> Bool {
        if mode & matchType != 0 {
            let a = LispEntityAdapter.dxfTypeName(entity: reference, document: document)
            let b = LispEntityAdapter.dxfTypeName(entity: candidate, document: document)
            guard a.uppercased() == b.uppercased() else { return false }
        }
        if mode & matchLayer != 0 {
            let a = LispEntityAdapter.layerName(entity: reference, document: document)
            let b = LispEntityAdapter.layerName(entity: candidate, document: document)
            guard a.uppercased() == b.uppercased() else { return false }
        }
        if mode & matchColor != 0 {
            guard LispEntityAdapter.entityACI(entity: reference)
                == LispEntityAdapter.entityACI(entity: candidate) else {
                return false
            }
        }
        if mode & matchLinetype != 0 {
            let a = effectiveLineType(of: reference, in: document)
            let b = effectiveLineType(of: candidate, in: document)
            guard a.uppercased() == b.uppercased() else { return false }
        }
        if mode & matchLineweight != 0 {
            let a = effectiveLineWeight(of: reference, in: document)
            let b = effectiveLineWeight(of: candidate, in: document)
            guard abs(a - b) < 1e-9 else { return false }
        }
        if mode & matchName != 0 {
            let a = displayName(of: reference, in: document)?.uppercased()
            let b = displayName(of: candidate, in: document)?.uppercased()
            guard a == b else { return false }
        }
        return true
    }

    /// Human names of set bits with no model behind them (32, 64, and
    /// anything above 128).
    public static func ignoredModeBits(_ mode: Int) -> [String] {
        var out: [String] = []
        if mode & 32 != 0 { out.append("plot style") }
        if mode & 64 != 0 { out.append("object style") }
        if mode & ~255 != 0 { out.append("reserved bits") }
        return out
    }

    /// Short mode summary for result lines, e.g. "layer+name".
    public static func modeDescription(_ mode: Int) -> String {
        var parts: [String] = []
        if mode & matchType != 0 { parts.append("type") }
        if mode & matchLayer != 0 { parts.append("layer") }
        if mode & matchColor != 0 { parts.append("color") }
        if mode & matchLinetype != 0 { parts.append("linetype") }
        if mode & matchLineweight != 0 { parts.append("lineweight") }
        if mode & matchName != 0 { parts.append("name") }
        return parts.isEmpty ? "nothing (empty mask)" : parts.joined(separator: "+")
    }

    // MARK: - QSELECT/FILTER criteria (Phase 2.2b)

    /// Filterable properties. String-backed (type/layer/linetype/handle)
    /// support equals/not-equals with `*`/`?` wildcards; numeric (color
    /// ACI, lineweight mm) support the full comparison set.
    public enum FilterProperty: String, CaseIterable {
        case objectType
        case layer
        case color
        case linetype
        case lineweight
        case handle
    }

    public enum FilterOperator: String, CaseIterable {
        case equals
        case notEquals
        case lessThan
        case lessThanOrEqual
        case greaterThan
        case greaterThanOrEqual
    }

    public struct FilterCriterion {
        public var property: FilterProperty
        public var op: FilterOperator
        public var value: String

        public init(property: FilterProperty, op: FilterOperator, value: String) {
            self.property = property
            self.op = op
            self.value = value
        }
    }

    public enum FilterCombine: String, CaseIterable {
        case and
        case or
        case not
    }

    /// DXF type names the engine produces (for prompts and validation).
    public static let knownTypes = [
        "LINE", "LWPOLYLINE", "CIRCLE", "ARC", "SPLINE", "TEXT",
        "ELLIPSE", "HATCH", "RAY", "XLINE", "IMAGE", "ACAD_TABLE",
        "INSERT", "POINT", "UNKNOWN",
    ]

    public static func isNumericProperty(_ property: FilterProperty) -> Bool {
        property == .color || property == .lineweight
    }

    /// Resolved string for a string-backed property.
    public static func stringValue(
        _ property: FilterProperty, of entity: CADEntity, in document: CADDocument
    ) -> String? {
        switch property {
        case .objectType:
            return LispEntityAdapter.dxfTypeName(entity: entity, document: document)
        case .layer:
            return LispEntityAdapter.layerName(entity: entity, document: document)
        case .linetype:
            return effectiveLineType(of: entity, in: document)
        case .handle:
            return entity.handle.uuidString
        case .color, .lineweight:
            return nil
        }
    }

    /// Resolved number for a numeric property (color ACI 0-256, lineweight mm).
    public static func numericValue(
        _ property: FilterProperty, of entity: CADEntity, in document: CADDocument
    ) -> Double? {
        switch property {
        case .color:
            return Double(LispEntityAdapter.entityACI(entity: entity))
        case .lineweight:
            return effectiveLineWeight(of: entity, in: document)
        case .objectType, .layer, .linetype, .handle:
            return nil
        }
    }

    /// Parses and range-checks a criterion value for a numeric property.
    /// Color accepts ACI 0-256 (0 = BYBLOCK, 256 = BYLAYER); lineweight mm >= 0.
    public static func parseNumericValue(
        _ property: FilterProperty, _ text: String
    ) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(trimmed), value.isFinite else { return nil }
        switch property {
        case .color:
            guard value >= 0, value <= 256, value == value.rounded() else { return nil }
            return value
        case .lineweight:
            guard value >= 0 else { return nil }
            return value
        case .objectType, .layer, .linetype, .handle:
            return nil
        }
    }

    /// Evaluates one criterion. Operator/property mismatches (a comparison
    /// on a string property, an unparseable number) are false, never errors.
    public static func evaluate(
        _ criterion: FilterCriterion, on entity: CADEntity, in document: CADDocument
    ) -> Bool {
        switch criterion.property {
        case .objectType, .layer, .linetype, .handle:
            guard let actual = stringValue(
                criterion.property, of: entity, in: document) else {
                return false
            }
            switch criterion.op {
            case .equals:
                if criterion.value.contains("*") || criterion.value.contains("?") {
                    return wildcardMatch(actual, pattern: criterion.value)
                }
                return actual.uppercased() == criterion.value.uppercased()
            case .notEquals:
                if criterion.value.contains("*") || criterion.value.contains("?") {
                    return !wildcardMatch(actual, pattern: criterion.value)
                }
                return actual.uppercased() != criterion.value.uppercased()
            case .lessThan, .lessThanOrEqual, .greaterThan, .greaterThanOrEqual:
                return false
            }
        case .color, .lineweight:
            guard let actual = numericValue(
                criterion.property, of: entity, in: document),
                  let wanted = parseNumericValue(
                      criterion.property, criterion.value) else {
                return false
            }
            switch criterion.op {
            case .equals: return actual == wanted
            case .notEquals: return actual != wanted
            case .lessThan: return actual < wanted
            case .lessThanOrEqual: return actual <= wanted
            case .greaterThan: return actual > wanted
            case .greaterThanOrEqual: return actual >= wanted
            }
        }
    }

    /// Combines per-criterion results: all (and), any (or), none (not).
    /// Empty criteria match everything under and/or, nothing under not.
    public static func combine(_ hits: [Bool], with combine: FilterCombine) -> Bool {
        switch combine {
        case .and: return hits.allSatisfy { $0 }
        case .or: return hits.contains(true)
        case .not: return !hits.contains(true)
        }
    }

    /// Visible entities matching the criteria under the combinator.
    public static func filter(
        _ entities: [CADEntity], criteria: [FilterCriterion],
        using combinator: FilterCombine, in document: CADDocument
    ) -> [CADEntity] {
        entities.filter { entity in
            guard isVisibleForSelection(entity, in: document) else { return false }
            let hits = criteria.map {
                evaluate($0, on: entity, in: document)
            }
            return combine(hits, with: combinator)
        }
    }
}
