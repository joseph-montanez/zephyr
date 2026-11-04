import Foundation

// =========================================================================
// MARK: - Sheet Set DST codec (`.dst`, Step 1-2)
// -------------------------------------------------------------------------
// Two-layer codec for AutoCAD sheet set data files:
//
//   `.dst` bytes --(fixed 1-byte substitution)--> UTF-8 XML text.
//
// Byte layer ported from Bedz01/dst-codec (MIT, Copyright (c) 2026 Bedz01):
// https://github.com/Bedz01/dst-codec — `xml = BLOCK_BASE[dst >> 4] +
// PERMUTE[dst & 0xF]` with a single 16-entry permutation shared by every
// block. No header, compression, or checksum: substituted back, a `.dst`
// is plain XML. The XML layer here is intentionally dependency-free
// (string scanning, no XMLDocument/XMLParser) so decode/list works on
// macOS and Linux alike; a tolerant DOM can replace the scanner later
// without changing the byte layer.
//
// DST blocks without a confirmed base (high nibbles 0x8 except the three
// whitespace bytes, and 0xB) fail closed instead of guessing.
// =========================================================================

/// Errors from `SheetSetDST` decode/encode.
public enum SheetSetDSTError: Error, LocalizedError, Equatable {
    case emptyDocument
    case unknownDSTByte(offset: Int, byte: UInt8)
    case unencodableXMLByte(offset: Int, byte: UInt8)
    case invalidUTF8

    public var errorDescription: String? {
        switch self {
        case .emptyDocument:
            return "Not a sheet set: empty DST document."
        case .unknownDSTByte(let offset, let byte):
            return "DST byte 0x\(String(byte, radix: 16)) at offset \(offset) is in a block with no confirmed mapping."
        case .unencodableXMLByte(let offset, let byte):
            return "XML byte 0x\(String(byte, radix: 16)) at offset \(offset) has no DST encoding."
        case .invalidUTF8:
            return "Decoded DST bytes are not valid UTF-8."
        }
    }
}

/// One decoded sheet reference: enough to render the Sheet List tree with
/// zero DWG opens. Identity keys on `(absoluteFile, handle)` — the stored
/// layout name can be stale; the `AcDbHandle` wins.
public struct SheetSetSheetRef: Sendable, Equatable {
    public var id: String
    public var number: String
    public var title: String
    public var description: String
    public var relativeFile: String
    public var absoluteFile: String
    public var handle: String
    public var layoutName: String
    public var includeForPlot: Bool
    public var custom: [String: String]

    /// Lossless model → interchange round-trip (every field survives).
    public init(sheet: SheetSetSheet) {
        self.init(
            id: sheet.id,
            number: sheet.number,
            title: sheet.title,
            description: sheet.description,
            relativeFile: sheet.relativeFile,
            absoluteFile: sheet.absoluteFile,
            handle: sheet.handle,
            layoutName: sheet.layoutName,
            includeForPlot: sheet.includeForPlot,
            custom: sheet.custom)
    }

    public init(
        id: String = "",
        number: String = "",
        title: String = "",
        description: String = "",
        relativeFile: String = "",
        absoluteFile: String = "",
        handle: String = "",
        layoutName: String = "",
        includeForPlot: Bool = true,
        custom: [String: String] = [:]
    ) {
        self.id = id
        self.number = number
        self.title = title
        self.description = description
        self.relativeFile = relativeFile
        self.absoluteFile = absoluteFile
        self.handle = handle
        self.layoutName = layoutName
        self.includeForPlot = includeForPlot
        self.custom = custom
    }
}

public enum SheetSetDST {
    /// Fixed 16-entry low-nibble permutation, identical across blocks.
    /// Self-inverse: applying it twice returns the input.
    fileprivate static let permute: [UInt8] = [13, 12, 15, 14, 9, 8, 11, 10, 5, 4, 7, 6, 1, 0, 3, 2]

    /// Confirmed high-nibble bases. Missing: 0x8 (whitespace only) and
    /// 0xB (176-191, unobserved — decode fails closed).
    fileprivate static let blockBase: [UInt8: UInt16] = [
        0x0: 127, 0x1: 111, 0x2: 159, 0x3: 143,
        0x4: 191, 0x5: 175, 0x6: 223, 0x7: 207,
        0x9: 239, 0xA: 31, 0xC: 63, 0xD: 47,
        0xE: 95, 0xF: 79,
    ]

    fileprivate static let dstToWhitespace: [UInt8: UInt8] = [
        131: 10, // AutoCAD LF
        134: 9,  // TAB
        135: 10, // ARES LF (accepted on decode)
    ]
    fileprivate static let lfDST: UInt8 = 131
    fileprivate static let tabDST: UInt8 = 134

    /// Reverse map XML byte -> canonical DST byte (LF always 131).
    fileprivate static let xmlToDST: [UInt8: UInt8] = {
        var rev: [UInt8: UInt8] = [:]
        for b in 0...255 {
            let dst = UInt8(b)
            if let x = dstToXMLByte(dst), rev[x] == nil {
                rev[x] = dst
            }
        }
        rev[9] = tabDST
        rev[10] = lfDST
        return rev
    }()

    fileprivate static func dstToXMLByte(_ dst: UInt8) -> UInt8? {
        if let w = dstToWhitespace[dst] { return w }
        guard let base = blockBase[dst >> 4] else { return nil }
        let mapped = Int(base) + Int(permute[Int(dst & 0xF)])
        guard (0...255).contains(mapped) else { return nil }
        return UInt8(mapped)
    }

    /// `.dst` bytes -> XML text. Throws on empty input or unmapped bytes.
    public static func decode(_ data: Data) throws -> String {
        guard !data.isEmpty else { throw SheetSetDSTError.emptyDocument }
        var out = [UInt8]()
        out.reserveCapacity(data.count)
        var offset = 0
        for byte in data {
            guard let x = dstToXMLByte(byte) else {
                throw SheetSetDSTError.unknownDSTByte(offset: offset, byte: byte)
            }
            out.append(x)
            offset += 1
        }
        guard let xml = String(bytes: out, encoding: .utf8) else {
            throw SheetSetDSTError.invalidUTF8
        }
        return xml
    }

    /// XML text -> `.dst` bytes. Normalizes CRLF/CR to LF first (CR has no
    /// DST encoding and XML parsers normalize it on read anyway).
    public static func encode(_ xml: String) throws -> Data {
        let normalized = xml
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let bytes = Array(normalized.utf8)
        guard !bytes.isEmpty else { throw SheetSetDSTError.emptyDocument }
        var out = [UInt8]()
        out.reserveCapacity(bytes.count)
        for (offset, byte) in bytes.enumerated() {
            guard let d = xmlToDST[byte] else {
                throw SheetSetDSTError.unencodableXMLByte(offset: offset, byte: byte)
            }
            out.append(d)
        }
        return Data(out)
    }

    // MARK: - Lightweight sheet listing (no DWG opens)

    /// Sheets in display order (Sheet Set Manager display/publish order):
    /// loose sheets first, then subsets depth-first. Boundary-aware:
    /// `<AcSmSheet` must not match `<AcSmSheetSet>`, `<AcSmSheetViews>`,
    /// or `<AcSmSheetSelSets` (a latent bug this replaces).
    public static func listSheets(xml: String) -> [SheetSetSheetRef] {
        let children = parseChildren(scope(xml))
        var out = children.sheets
        func walk(_ subsets: [SheetSetSubset]) {
            for sub in subsets {
                out.append(contentsOf: sub.sheets.map(SheetSetSheetRef.init(sheet:)))
                walk(sub.subsets)
            }
        }
        walk(children.subsets)
        return out
    }

    /// Hierarchical parse: loose sheets, subsets (recursive), and the
    /// set-level custom entries. Unknown containers are skipped, never
    /// mistaken for sheets.
    public static func parseChildren(_ scope: String) -> (
        sheets: [SheetSetSheetRef], subsets: [SheetSetSubset], setCustoms: [CustomEntry]
    ) {
        var sheets: [SheetSetSheetRef] = []
        var subsets: [SheetSetSubset] = []
        var setCustoms: [CustomEntry] = []
        var searchFrom = scope.startIndex
        while searchFrom < scope.endIndex {
            guard let (tag, openRange) = nextChildOpen(in: scope, from: searchFrom) else { break }
            if tag == "bag" {
                guard let close = scope.range(of: "</AcSmCustomPropertyBag>", range: openRange.lowerBound..<scope.endIndex) else { break }
                setCustoms.append(contentsOf: parseCustomEntries(in: String(scope[openRange.lowerBound..<close.upperBound])))
                searchFrom = close.upperBound
            } else if tag == "sheet" {
                guard let close = scope.range(of: "</AcSmSheet>", range: openRange.lowerBound..<scope.endIndex) else { break }
                sheets.append(sheetFromBlock(String(scope[openRange.lowerBound..<close.upperBound])))
                searchFrom = close.upperBound
            } else {
                // Subset: depth-match nested subsets to the owning close.
                guard let close = matchingSubsetClose(in: scope, from: openRange.lowerBound) else { break }
                subsets.append(subsetFromBlock(String(scope[openRange.lowerBound..<close.upperBound])))
                searchFrom = close.upperBound
            }
        }
        return (sheets, subsets, setCustoms)
    }

    /// The `<AcSmSheetSet>` inner XML, or "" when absent (wrapper-less
    /// fixtures). `store.open` falls back to the whole document then.
    public static func sheetSetInner(xml: String) -> String {
        guard let openRange = nextOpen(in: xml, from: xml.startIndex, tag: "AcSmSheetSet"),
              let gt = xml.range(of: ">", range: openRange.lowerBound..<xml.endIndex),
              let close = xml.range(of: "</AcSmSheetSet>", range: gt.upperBound..<xml.endIndex) else { return "" }
        return String(xml[gt.upperBound..<close.lowerBound])
    }

    /// Scope `open` uses: set inner when present, else the whole document.
    public static func scope(_ xml: String) -> String {
        let inner = sheetSetInner(xml: xml)
        return inner.isEmpty ? xml : inner
    }

    /// The raw `<AcSmSheetSelSets>` element (self-closed or paired), or nil
    /// when the document has none. Returned byte-exact for opaque
    /// preservation: the member grammar is unverified without LT (even the
    /// reference open-source editor round-trips this block untouched), so
    /// the model never reformats it — open captures it, save emits it back.
    public static func selSetsBlock(xml: String) -> String? {
        guard let open = nextOpen(in: xml, from: xml.startIndex, tag: "AcSmSheetSelSets") else { return nil }
        guard let gt = xml.range(of: ">", range: open.lowerBound..<xml.endIndex) else { return nil }
        let opener = String(xml[open.lowerBound..<gt.lowerBound])
        if opener.hasSuffix("/") || opener.hasSuffix("/ ") {
            return String(xml[open.lowerBound..<gt.upperBound])
        }
        guard let close = xml.range(of: "</AcSmSheetSelSets>", range: gt.upperBound..<xml.endIndex) else { return nil }
        return String(xml[open.lowerBound..<close.upperBound])
    }

    /// One parsed custom-property entry (Flags 1 = set scope, 2 = sheet).
    public struct CustomEntry: Sendable, Equatable {
        public var name: String
        public var flags: String
        public var value: String
    }

    /// Entries of one `<AcSmCustomPropertyBag>` block.
    public static func parseCustomEntries(in block: String) -> [CustomEntry] {
        var out: [CustomEntry] = []
        var searchFrom = block.startIndex
        while let openRange = nextOpen(in: block, from: searchFrom, tag: "AcSmCustomPropertyValue"),
              let closeRange = block.range(of: "</AcSmCustomPropertyValue>", range: openRange.lowerBound..<block.endIndex)
        {
            let entry = String(block[openRange.lowerBound..<closeRange.upperBound])
            out.append(CustomEntry(
                name: unescape(attribute(entry, tag: "<AcSmCustomPropertyValue", name: "propname")),
                flags: prop(entry, name: "Flags"),
                value: prop(entry, name: "Value")))
            searchFrom = closeRange.upperBound
        }
        return out
    }

    // MARK: - Hierarchical pieces

    fileprivate static func sheetFromBlock(_ block: String) -> SheetSetSheetRef {
        let layoutBlock = subblock(block, tag: "AcSmAcDbLayoutReference")
        let bagBlock = subblock(block, tag: "AcSmCustomPropertyBag")
        var custom: [String: String] = [:]
        for entry in parseCustomEntries(in: bagBlock) where entry.flags == "2" && !entry.name.isEmpty {
            custom[entry.name] = entry.value
        }
        return SheetSetSheetRef(
            id: attribute(block, tag: "<AcSmSheet", name: "ID"),
            number: prop(block, name: "Number"),
            title: prop(block, name: "Title"),
            description: prop(block, name: "Desc"),
            relativeFile: prop(layoutBlock, name: "Relative_FileName"),
            absoluteFile: prop(layoutBlock, name: "FileName"),
            handle: prop(layoutBlock, name: "AcDbHandle"),
            layoutName: prop(layoutBlock, name: "Name"),
            includeForPlot: prop(block, name: "DoNotPlot") != "-1",
            custom: custom)
    }

    fileprivate static func subsetFromBlock(_ block: String) -> SheetSetSubset {
        let inner: String = {
            guard let gt = block.range(of: ">"),
                  let close = block.range(of: "</AcSmSubset>", options: .backwards) else { return "" }
            return String(block[gt.upperBound..<close.lowerBound])
        }()
        let children = parseChildren(inner)
        var subset = SheetSetSubset(
            id: attribute(block, tag: "<AcSmSubset", name: "ID"),
            name: prop(block, name: "Name"),
            description: prop(block, name: "Desc"))
        // NOTE: no verified serialization for the subset publish flag;
        // subsets restore as publishing until the mapping is proven.
        subset.sheets = children.sheets.map(SheetSetSheet.init(ref:))
        subset.subsets = children.subsets
        return subset
    }

    /// Next child opener at top level: "sheet" | "subset" | "bag", or nil.
    /// Tag match requires a boundary (space, `>`, tab, LF, CR) so
    /// `<AcSmSheetSet>` / `<AcSmSheetViews>` / `<AcSmSheetSelSets>` never
    /// match a sheet search.
    fileprivate static func nextChildOpen(in xml: String, from: String.Index) -> (tag: String, range: Range<String.Index>)? {
        var best: (tag: String, range: Range<String.Index>)? = nil
        for tag in ["AcSmSheet", "AcSmSubset", "AcSmCustomPropertyBag"] {
            if let r = nextOpen(in: xml, from: from, tag: tag),
               best == nil || r.lowerBound < best!.range.lowerBound {
                let kind = tag == "AcSmSheet" ? "sheet" : (tag == "AcSmSubset" ? "subset" : "bag")
                best = (kind, r)
            }
        }
        return best
    }

    /// `<Tag` opener whose next char is a boundary (space, `>`, tab, LF, CR).
    fileprivate static func nextOpen(in xml: String, from: String.Index, tag: String) -> Range<String.Index>? {
        let needle = "<" + tag
        var searchFrom = from
        while let r = xml.range(of: needle, range: searchFrom..<xml.endIndex) {
            let after = xml.index(r.lowerBound, offsetBy: needle.count)
            if after < xml.endIndex {
                let c = xml[after]
                if c == " " || c == ">" || c == "\t" || c == "\n" || c == "\r" {
                    return r.lowerBound..<after
                }
            }
            searchFrom = xml.index(after: r.lowerBound)
        }
        return nil
    }

    /// Close range matching the subset opener at `openStart`, counting
    /// nested `<AcSmSubset>` opens.
    fileprivate static func matchingSubsetClose(in xml: String, from openStart: String.Index) -> Range<String.Index>? {
        var depth = 0
        var searchFrom = openStart
        while searchFrom < xml.endIndex {
            let nextOpen = nextOpen(in: xml, from: searchFrom, tag: "AcSmSubset")
            let nextClose = xml.range(of: "</AcSmSubset>", range: searchFrom..<xml.endIndex)
            if let o = nextOpen, let c = nextClose, o.lowerBound < c.lowerBound {
                depth += 1
                searchFrom = o.upperBound
            } else if let c = nextClose {
                depth -= 1
                if depth == 0 { return c }
                searchFrom = c.upperBound
            } else {
                return nil
            }
        }
        return nil
    }

    /// Set-level name from `<AcSmSheetSet>` (`Name` prop); "" when absent.
    /// The full AcSm reader (Step 2) replaces this with the typed model.
    public static func sheetSetName(xml: String) -> String {
        prop(subblock(xml, tag: "AcSmSheetSet"), name: "Name")
    }

    /// Set-level description from `<AcSmSheetSet>` (`Desc` prop).
    public static func sheetSetDescription(xml: String) -> String {
        let set = subblock(xml, tag: "AcSmSheetSet")
        let desc = prop(set, name: "Desc")
        return desc.isEmpty ? prop(set, name: "Description") : desc
    }

    // MARK: - String scanning helpers

    fileprivate static func attribute(_ block: String, tag: String, name: String) -> String {
        guard let tagRange = block.range(of: tag) else { return "" }
        let afterTag = block[tagRange.lowerBound...]
        guard let endRange = afterTag.range(of: ">") else { return "" }
        let header = String(afterTag[..<endRange.lowerBound])
        let needle = name + "=\""
        guard let keyRange = header.range(of: needle),
              let valueEnd = header[keyRange.upperBound...].range(of: "\"") else { return "" }
        return String(header[keyRange.upperBound..<valueEnd.lowerBound])
    }

    fileprivate static func subblock(_ block: String, tag: String) -> String {
        guard let openRange = block.range(of: "<" + tag),
              let closeRange = block.range(of: "</" + tag + ">", range: openRange.lowerBound..<block.endIndex) else { return "" }
        return String(block[openRange.lowerBound..<closeRange.upperBound])
    }

    fileprivate static func prop(_ block: String, name: String) -> String {
        let needle = "<AcSmProp propname=\"" + name + "\""
        guard let keyRange = block.range(of: needle),
              let gtRange = block.range(of: ">", range: keyRange.upperBound..<block.endIndex),
              let endRange = block.range(of: "</AcSmProp>", range: gtRange.upperBound..<block.endIndex) else { return "" }
        return unescape(String(block[gtRange.upperBound..<endRange.lowerBound]))
    }

    fileprivate static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
    }
}
