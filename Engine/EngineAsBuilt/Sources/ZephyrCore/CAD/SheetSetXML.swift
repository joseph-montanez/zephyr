import Foundation

// =========================================================================
// MARK: - Sheet set AcSm XML writer (Step 2: NEWSHEETSET .dst write path)
// -------------------------------------------------------------------------
// Serializes a `SheetSet` to the COM-serialized XML LT persists, then
// `SheetSetDST.encode` runs the fixed byte substitution for the `.dst`.
// Element/attribute shape is pinned to observed genuine output:
//
// - Root + set CLSIDs, `DbFingerPrint`/`DbVersion`/`FileRevision`, set
//   `propname="SheetSet" vt="13"`: cadtutor "Disadvantage of sheetsets"
//   sample (genuine AutoCAD output; overlaps dst-edit exactly where the
//   two sources intersect, which validates it).
// - Subset/custom-bag/custom-value/publish-options/simple-file-ref
//   CLSIDs, `vt` codes, `Flags` 1 = set / 2 = sheet, sorted-by-propname
//   child order, tab reindentation, XML declaration, and the surgical
//   "unknown elements are someone else's" stance: abrman/dst-edit
//   `src/lib/dst-model.ts` (round-trips real AutoCAD + ARES files).
// - Sheet/FileReference/SheetViews/SheetSelSets CLSIDs: same cadtutor
//   sample only (single source — re-verify against a live LT file at
//   the interchange gate).
// - Title ≤ 64 chars and `/` → look-alike slash in Number/Title/Desc:
//   abrman/dst-edit `src/lib/autocad-text.ts`.
//
// v1 scope: Name/Desc/Number/Title/DoNotPlot/layout refs/custom bags.
// Project Control fields, DefDwtLayout templates, and publish-option
// details are carried in the model but NOT written — their exact
// propnames are unverified, and emitting guesses would poison LT files.
// =========================================================================

/// Writer-side validation failures (mirrors dst-edit blocking a save).
public enum SheetSetXMLError: Error, LocalizedError, Equatable {
    case titleTooLong(sheet: String)
    case emptySetName

    public var errorDescription: String? {
        switch self {
        case .titleTooLong(let sheet):
            return "Sheet '\(sheet)' title exceeds 64 characters."
        case .emptySetName:
            return "Sheet set name must not be empty."
        }
    }
}

public enum SheetSetXML {
    // MARK: - CLSIDs (provenance in the file header above)

    fileprivate static let clsidDatabase = "g2162C6B6-0CE4-40E8-912B-46F59DFDF826"
    fileprivate static let clsidSheetSet = "gB20534F2-0978-418C-8D14-2E6928A077ED"
    fileprivate static let clsidSheet = "g16A07941-BC15-4D48-A880-9D5A211D5065"
    fileprivate static let clsidSubset = "g076D548F-B0F5-4FE1-B35D-7F7B73B8D322"
    fileprivate static let clsidCustomBag = "g4D103908-8C86-4D95-BBF4-68B9A7B00731"
    fileprivate static let clsidCustomValue = "g8D22A2A4-1777-4D78-84CC-69EF741FE954"
    fileprivate static let clsidPublishOptions = "gF57F96E7-0F16-4DC9-8F09-52F7BB389AB6"
    fileprivate static let clsidSimpleFileRef = "gD15A03C2-C39B-428A-9BBA-C031347C496F"
    fileprivate static let clsidFileReference = "g6BF87AE7-1BEC-4BDB-98BB-5B91F7772793"
    fileprivate static let clsidSheetViews = "gF40F931B-64BC-4B90-9FC8-A11A77D6815B"
    fileprivate static let clsidSheetSelSets = "g444780B8-6527-43A8-8DC4-FAB41B7E48BB"

    fileprivate static let xmlDeclaration = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"

    /// Fresh COM-style ID: "g" + uppercase UUID with dashes (matches
    /// `crypto.randomUUID()` output in dst-edit/dst-codec fixtures).
    public static func freshID() -> String {
        "g" + UUID().uuidString.uppercased()
    }

    /// Full XML document for a set. Throws on LT text-rule violations.
    public static func serialize(_ set: SheetSet) throws -> String {
        guard !set.name.isEmpty else { throw SheetSetXMLError.emptySetName }
        var out: [String] = [xmlDeclaration]
        out.append("<AcSmDatabase clsid=\"\(clsidDatabase)\" ID=\"\(freshID())\">")
        out.append("\t<AcSmProp propname=\"DbFingerPrint\" vt=\"8\">\(freshID())</AcSmProp>")
        out.append("\t<AcSmProp propname=\"DbVersion\" vt=\"8\">1.1</AcSmProp>")
        out.append("\t<AcSmProp propname=\"FileRevision\" vt=\"3\">8</AcSmProp>")
        out.append("\t<AcSmSheetSet clsid=\"\(clsidSheetSet)\" ID=\"\(freshID())\" propname=\"SheetSet\" vt=\"13\">")
        let inner = try serializeSetChildren(set, depth: 2)
        out.append(contentsOf: inner)
        out.append("\t</AcSmSheetSet>")
        out.append("</AcSmDatabase>")
        return out.joined(separator: "\n")
    }

    // MARK: - Set level

    fileprivate static func serializeSetChildren(_ set: SheetSet, depth: Int) throws -> [String] {
        var named: [(key: String, lines: [String])] = []
        // Custom bag sorts by its propname among the direct props.
        // Set-level entries carry Flags 1; sheet-scope defaults live
        // per-sheet (Flags 2) until the property editor lands.
        let bagLines = serializeCustomBag(entries: set.customSetProps.map {
            (name: $0.key, flags: "1", value: $0.value)
        }, depth: depth + 1)
        if !bagLines.isEmpty {
            named.append((key: "CustomPropertyBag", lines: bagLines))
        }
        named.append((key: "Desc", lines: propLines(name: "Desc", value: cleanText("Desc", set.description), depth: depth + 1, omitWhenEmpty: true)))
        named.append((key: "Name", lines: propLines(name: "Name", value: cleanText("Title", set.name), depth: depth + 1, omitWhenEmpty: false)))
        named.append((key: "NewSheetLocation", lines: fileRefLines(propname: "NewSheetLocation", depth: depth + 1)))
        if let preserved = set.preservedSelSetsXML, !preserved.isEmpty {
            // Verbatim, unindented: reformatting would silently drop
            // LT-authored selections whose member grammar is unverified.
            named.append((key: "SheetSelSets", lines: [preserved]))
        } else {
            named.append((key: "SheetSelSets", lines: [
                indent(depth + 1) + "<AcSmSheetSelSets clsid=\"\(clsidSheetSelSets)\" ID=\"\(freshID())\" propname=\"SheetSelSets\" vt=\"13\" />",
            ]))
        }
        var out: [String] = []
        for entry in named.sorted(by: { $0.key.lowercased() < $1.key.lowercased() }) {
            out.append(contentsOf: entry.lines)
        }
        // Loose sheets first, then subsets (matches `allSheetsInOrder`).
        for sheet in set.sheets {
            out.append(contentsOf: try serializeSheet(sheet, customDefs: [], depth: depth + 1))
        }
        for subset in set.subsets {
            out.append(contentsOf: try serializeSubset(subset, depth: depth + 1))
        }
        return out
    }

    // MARK: - Subsets

    fileprivate static func serializeSubset(_ subset: SheetSetSubset, depth: Int) throws -> [String] {
        var out = ["\(indent(depth))<AcSmSubset clsid=\"\(clsidSubset)\" ID=\"\(subset.id)\">"]
        var named: [(key: String, lines: [String])] = []
        named.append((key: "Desc", lines: propLines(name: "Desc", value: cleanText("Desc", subset.description), depth: depth + 1, omitWhenEmpty: true)))
        named.append((key: "Name", lines: propLines(name: "Name", value: cleanText("Title", subset.name), depth: depth + 1, omitWhenEmpty: false)))
        named.append((key: "NewSheetLocation", lines: fileRefLines(propname: "NewSheetLocation", depth: depth + 1)))
        for entry in named.sorted(by: { $0.key.lowercased() < $1.key.lowercased() }) {
            out.append(contentsOf: entry.lines)
        }
        for sheet in subset.sheets {
            out.append(contentsOf: try serializeSheet(sheet, customDefs: [], depth: depth + 1))
        }
        for child in subset.subsets {
            out.append(contentsOf: try serializeSubset(child, depth: depth + 1))
        }
        out.append("\(indent(depth))</AcSmSubset>")
        return out
    }

    // MARK: - Sheets

    fileprivate static func serializeSheet(_ sheet: SheetSetSheet, customDefs: [(name: String, scope: String)], depth: Int) throws -> [String] {
        if sheet.title.count > 64 { throw SheetSetXMLError.titleTooLong(sheet: sheet.number.isEmpty ? sheet.title : sheet.number) }
        var out = ["\(indent(depth))<AcSmSheet clsid=\"\(clsidSheet)\" ID=\"\(sheet.id)\">"]
        var named: [(key: String, lines: [String])] = []
        let bagEntries = sheet.custom.map { (name: $0.key, flags: "2", value: $0.value) }
        let bagLines = serializeCustomBag(entries: bagEntries, depth: depth + 1)
        if !bagLines.isEmpty { named.append((key: "CustomPropertyBag", lines: bagLines)) }
        named.append((key: "Desc", lines: propLines(name: "Desc", value: cleanText("Desc", sheet.description), depth: depth + 1, omitWhenEmpty: true)))
        if !sheet.includeForPlot {
            // Mirrors PromptForName-style boolean props (vt 2, "-1" = set).
            named.append((key: "DoNotPlot", lines: propLines(name: "DoNotPlot", value: "-1", vt: "2", depth: depth + 1, omitWhenEmpty: false)))
        }
        let layout = serializeLayoutRef(sheet: sheet, depth: depth + 1)
        if !layout.isEmpty { named.append((key: "Layout", lines: layout)) }
        named.append((key: "Name", lines: propLines(name: "Name", value: cleanText("Title", sheet.layoutName), depth: depth + 1, omitWhenEmpty: true)))
        named.append((key: "Number", lines: propLines(name: "Number", value: cleanText("Number", sheet.number), depth: depth + 1, omitWhenEmpty: true)))
        named.append((key: "SheetViews", lines: [
            indent(depth + 1) + "<AcSmSheetViews clsid=\"\(clsidSheetViews)\" ID=\"\(freshID())\" propname=\"SheetViews\" vt=\"13\" />",
        ]))
        named.append((key: "Title", lines: propLines(name: "Title", value: cleanText("Title", sheet.title), depth: depth + 1, omitWhenEmpty: true)))
        for entry in named.sorted(by: { $0.key.lowercased() < $1.key.lowercased() }) {
            out.append(contentsOf: entry.lines)
        }
        out.append("\(indent(depth))</AcSmSheet>")
        return out
    }

    fileprivate static func serializeLayoutRef(sheet: SheetSetSheet, depth: Int) -> [String] {
        // Environ_/SpecialFolder_ variants omitted: their path forms are
        // unverified, and dst-edit drops empty ones the same way.
        let fields: [(String, String)] = [
            // AcDbHandle propname per dst-codec read path; vt 8 assumed
            // (dst-edit never writes it — re-verify at the interchange gate).
            ("AcDbHandle", sheet.handle),
            ("FileName", sheet.absoluteFile),
            ("Name", cleanText("Title", sheet.layoutName)),
            ("Relative_FileName", sheet.relativeFile),
        ].filter { !$0.1.isEmpty }
        guard !fields.isEmpty else { return [] }
        var out = ["\(indent(depth))<AcSmAcDbLayoutReference propname=\"Layout\">"]
        for (name, value) in fields.sorted(by: { $0.0.lowercased() < $1.0.lowercased() }) {
            out.append("\(indent(depth + 1))<AcSmProp propname=\"\(name)\" vt=\"8\">\(escape(value))</AcSmProp>")
        }
        out.append("\(indent(depth))</AcSmAcDbLayoutReference>")
        return out
    }

    // MARK: - Shared pieces

    /// Custom-property bag; scope plumbing (set- vs sheet-level Flags)
    /// arrives with the full property editor — v1 writes sheet entries
    /// (Flags 2) and set-level name-only definitions.
    fileprivate static func serializeCustomBag(entries: [(name: String, flags: String, value: String)], depth: Int) -> [String] {
        let kept = entries.filter { !$0.name.isEmpty }
        guard !kept.isEmpty else { return [] }
        var out = ["\(indent(depth))<AcSmCustomPropertyBag clsid=\"\(clsidCustomBag)\" ID=\"\(freshID())\" propname=\"CustomPropertyBag\" vt=\"13\">"]
        for entry in kept.sorted(by: { $0.name.lowercased() < $1.name.lowercased() }) {
            out.append("\(indent(depth + 1))<AcSmCustomPropertyValue clsid=\"\(clsidCustomValue)\" ID=\"\(freshID())\" propname=\"\(escape(entry.name))\" vt=\"13\">")
            out.append("\(indent(depth + 2))<AcSmProp propname=\"Flags\" vt=\"3\">\(entry.flags)</AcSmProp>")
            out.append("\(indent(depth + 2))<AcSmProp propname=\"Value\" vt=\"8\">\(escape(entry.value))</AcSmProp>")
            out.append("\(indent(depth + 1))</AcSmCustomPropertyValue>")
        }
        out.append("\(indent(depth))</AcSmCustomPropertyBag>")
        return out
    }

    fileprivate static func fileRefLines(propname: String, depth: Int) -> [String] {
        ["\(indent(depth))<AcSmFileReference clsid=\"\(clsidFileReference)\" ID=\"\(freshID())\" propname=\"\(propname)\" vt=\"13\" />"]
    }

    fileprivate static func propLines(name: String, value: String, vt: String = "8", depth: Int, omitWhenEmpty: Bool) -> [String] {
        if value.isEmpty, omitWhenEmpty { return [] }
        return ["\(indent(depth))<AcSmProp propname=\"\(name)\" vt=\"\(vt)\">\(escape(value))</AcSmProp>"]
    }

    /// LT text rules: `/` → spaced look-alike in Number/Title/Desc.
    fileprivate static func cleanText(_ column: String, _ value: String) -> String {
        guard ["Number", "Title", "Desc"].contains(column) else { return value }
        return value.replacingOccurrences(of: #"\s*/\s*"#, with: " \u{0338} ", options: .regularExpression)
    }

    fileprivate static func indent(_ depth: Int) -> String {
        String(repeating: "\t", count: depth)
    }

    fileprivate static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
