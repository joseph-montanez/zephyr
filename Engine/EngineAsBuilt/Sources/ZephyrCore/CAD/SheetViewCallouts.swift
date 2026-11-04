import Foundation

// MARK: - SheetViewCallouts
//
// Callout/label blocks for placed sheet views: the "Place Callout Block"
// subset of the Sheet Views tab implementable without AutoCAD LT.
//
// In LT, callout attributes bind to live AcSm SheetView objects (auto view
// numbers, back-references that follow the view across sheets). Those object
// IDs are unverified without LT, so values here are resolved text snapshots
// — the same cached-text rule FIELD uses: the view name, the active sheet's
// number/title when that sheet belongs to an open set, the model file name,
// and an explicit TAG=value map that always wins. Tags the block does not
// define are dropped by ATTSYNC; tags with no rule keep their defaults.
// View-number tags (VIEW_NO and kin) intentionally resolve to nil: view
// numbers are LT-assigned, so pass them explicitly (e.g. VIEW_NO=3).
// Attribute tags match case-insensitively.

public enum SheetViewCallouts {
    public struct Target: Sendable, Equatable {
        public var viewName: String
        public var modelFileName: String
        public var sheetNumber: String?
        public var sheetTitle: String?
        public var scaleDenominator: Double

        public init(
            viewName: String,
            modelFileName: String = "",
            sheetNumber: String? = nil,
            sheetTitle: String? = nil,
            scaleDenominator: Double = 1
        ) {
            self.viewName = viewName
            self.modelFileName = modelFileName
            self.sheetNumber = sheetNumber
            self.sheetTitle = sheetTitle
            self.scaleDenominator = scaleDenominator
        }
    }

    private static let numberWords: Set<String> = ["NO", "NUM", "NUMBER", "NUMBERS", "NBR"]

    private static func tokens(of tag: String) -> [String] {
        tag.uppercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    public static func scaleText(_ denominator: Double) -> String {
        denominator == denominator.rounded() ? "1:\(Int(denominator))" : "1:\(denominator)"
    }

    /// Resolved text for one attribute tag, or nil when no rule fires (the
    /// caller keeps the definition default). `overrides` keys are uppercased
    /// tag names; `tag` itself is matched case-insensitively.
    public static func value(
        forTag tag: String, target: Target, overrides: [String: String]
    ) -> String? {
        let key = tag.uppercased()
        let upper = Dictionary(uniqueKeysWithValues: overrides.map { ($0.key.uppercased(), $0.value) })
        if let explicit = upper[key] { return explicit }
        let parts = tokens(of: key)
        if parts.contains("SCALE") { return scaleText(target.scaleDenominator) }
        if parts.contains("SHEET") {
            if !parts.filter(numberWords.contains).isEmpty { return target.sheetNumber }
            if parts.contains("TITLE") || parts.contains("NAME") { return target.sheetTitle }
            if parts == ["SHEET"] { return target.sheetNumber ?? target.sheetTitle }
            return nil
        }
        if parts.contains("VIEW") || parts.contains("DETAIL") {
            if !parts.filter(numberWords.contains).isEmpty { return nil }
            return target.viewName
        }
        if parts == ["DWG"] || parts == ["DRAWING"]
            || parts == ["DWG", "NAME"] || parts == ["DRAWING", "NAME"] {
            return target.modelFileName.isEmpty ? nil : target.modelFileName
        }
        // Conventional single-token compounds without separators.
        switch key {
        case "VIEWNO", "VIEWNUM", "VIEWNUMBER", "VIEWNBR",
            "DETAILNO", "DETAILNUM", "DETAILNUMBER":
            return nil
        case "VIEWNAME", "VIEWTITLE", "DETAILNAME", "DETAILTITLE":
            return target.viewName
        case "SHEETNO", "SHEETNUM", "SHEETNUMBER", "SHEETNBR":
            return target.sheetNumber
        case "SHEETTITLE", "SHEETNAME":
            return target.sheetTitle
        case "DWGNAME", "DRAWINGNAME":
            return target.modelFileName.isEmpty ? nil : target.modelFileName
        default:
            return nil
        }
    }

    /// Full attribute map for a block: heuristic fills for defined tags,
    /// ATTSYNC-merged so missing tags gain defaults and seeded values for
    /// undefined tags drop.
    public static func resolve(
        definitions: [CADAttributeDefinition],
        target: Target,
        overrides: [String: String] = [:]
    ) -> [String: CADAttributeValue] {
        var seeded: [String: CADAttributeValue] = [:]
        seeded.reserveCapacity(definitions.count)
        for def in definitions {
            if let text = value(forTag: def.tag, target: target, overrides: overrides) {
                seeded[def.key] = CADAttributeValue(value: text)
            }
        }
        return CADAttributeSync.apply(definitions: definitions, to: seeded)
    }
}
