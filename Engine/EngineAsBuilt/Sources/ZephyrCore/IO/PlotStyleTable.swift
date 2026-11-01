import Foundation
import CZLibNG

// =========================================================================
// MARK: - PlotStyleTable
//
// Phase 3 step 18: `.ctb` / `.stb` plot-style table parser.
//
// On-disk format (verified against every file in `Plot Styles/`):
// ```
// PIAFILEVERSION_2.0,CTBVER1,compress\r\n   (or STBVER1)
// pmzlibcodec                                (11-byte codec tag)
// <12-byte header>                            (opaque; skipped)
// <zlib stream>                               (RFC 1950, inflate → UTF-8 text)
// ```
// The decompressed payload is line-oriented text:
// ```
// description="
// aci_table_available=TRUE
// ...
// aci_table{
//  0="Color_1
//  ...
// }
// plot_style{
//  0{
//   name="Color_1
//   color=-16777216
//   color_policy=5
//   ...
//   screen=100
//   lineweight=0
//  }
//  ...
// }
// custom_lineweight_table{
//  0=0.0
//  ...
// }
// ```
// String values open with `="` and run to end of line (no closing quote).
//
// Field semantics (reverse-engineered; honest where uncertain):
// - `color` is a signed 32-bit ARGB integer; -1 means "use object color".
// - `color_policy`: 1 = object color, 3 = grayscale of object color,
//   5 = explicit `color` override, 0 (STB) = style color (`mode_color`
//   when present, else `color`).
// - `screen` 0–100 = screening (ink) percent.
// - `lineweight` indexes `custom_lineweight_table` (mm); 0 = object
//   lineweight (all factory tables use 0 for "use object").
// =========================================================================

/// One resolved plot-style pen (CTB ACI entry or named STB style).
public struct PlotStylePen: Sendable, Equatable {
    /// Style name (`Color_7`, `Style_1`, `Normal` …).
    public var name: String
    /// Explicit ARGB override (nil = derive from the object).
    public var colorARGB: UInt32?
    /// Raw color policy (0/1/3/5; see header note).
    public var colorPolicy: Int
    /// Grayscale conversion of the object color (policy 3).
    public var isGrayscale: Bool { colorPolicy == 3 }
    /// Screening percent 0–100.
    public var screeningPercent: Int
    /// Pen lineweight in mm (nil = use object lineweight).
    public var lineweightMM: Double?

    public init(name: String, colorARGB: UInt32? = nil, colorPolicy: Int = 1,
                screeningPercent: Int = 100, lineweightMM: Double? = nil) {
        self.name = name
        self.colorARGB = colorARGB
        self.colorPolicy = colorPolicy
        self.screeningPercent = min(max(screeningPercent, 0), 100)
        self.lineweightMM = lineweightMM
    }
}

public enum PlotStyleTableKind: Sendable, Equatable {
    case ctb
    case stb
}

/// Parsed `.ctb` (ACI-indexed, 255 pens) or `.stb` (named styles) table.
public struct PlotStyleTable: Sendable, Equatable {
    public var kind: PlotStyleTableKind
    public var pens: [PlotStylePen]
    /// Index → mm (from `custom_lineweight_table`).
    public var lineweightTable: [Double]

    public init(kind: PlotStyleTableKind, pens: [PlotStylePen] = [],
                lineweightTable: [Double] = []) {
        self.kind = kind
        self.pens = pens
        self.lineweightTable = lineweightTable
    }

    /// CTB lookup: ACI 1–255 → pen (table order is 0-based).
    public func pen(forACI aci: Int) -> PlotStylePen? {
        guard kind == .ctb, (1...255).contains(aci) else { return nil }
        let index = aci - 1
        guard pens.indices.contains(index) else { return nil }
        return pens[index]
    }

    /// STB lookup by style name (case-insensitive).
    public func pen(named name: String) -> PlotStylePen? {
        pens.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    // MARK: - Loading

    public enum ParseError: Error, Equatable {
        case unknownHeader
        case unsupportedCodec(String)
        case truncatedPayload
        case inflateFailed
        case notUTF8
    }

    public static func parse(url: URL) throws -> PlotStyleTable {
        try parse(data: try Data(contentsOf: url))
    }

    public static func parse(data: Data) throws -> PlotStyleTable {
        // ASCII header line: PIAFILEVERSION_2.0,CTBVER1,compress\r\n
        guard let crlf = data.range(of: Data([0x0D, 0x0A])),
              let header = String(data: data[..<crlf.lowerBound], encoding: .utf8) else {
            throw ParseError.unknownHeader
        }
        let kind: PlotStyleTableKind
        if header.contains("CTBVER1") {
            kind = .ctb
        } else if header.contains("STBVER1") {
            kind = .stb
        } else {
            throw ParseError.unknownHeader
        }
        var rest = data[crlf.upperBound...]
        let codecTag = Data("pmzlibcodec".utf8)
        guard rest.starts(with: codecTag) else {
            throw ParseError.unsupportedCodec(String(data: rest.prefix(16), encoding: .utf8) ?? "?")
        }
        rest = rest.dropFirst(codecTag.count + 12) // codec tag + opaque header
        guard !rest.isEmpty else { throw ParseError.truncatedPayload }
        let inflated = try inflateZlib(Data(rest))
        guard let text = String(data: inflated, encoding: .utf8) else {
            throw ParseError.notUTF8
        }
        return parseText(text, kind: kind)
    }

    // MARK: - Text sections

    static func parseText(_ text: String, kind: PlotStyleTableKind) -> PlotStyleTable {
        struct RawPen { var name: String; var policy: Int; var colorRaw: Int; var modeRaw: Int?; var screen: Int; var lwIndex: Int }
        var rawPens: [RawPen] = []
        var lineweights: [Double] = []
        var currentFields: [String: String] = [:]
        var inPlotStyle = false
        var plotDepth = 0 // nested `N{` records inside plot_style{ }
        var inLineweightTable = false

        func stripped(_ raw: String) -> String {
            var v = raw
            if v.hasPrefix("\"") { v = String(v.dropFirst()) }
            return v
        }

        func flushPen() {
            guard inPlotStyle, !currentFields.isEmpty else { return }
            let name = stripped(currentFields["name"] ?? "")
            rawPens.append(RawPen(
                name: name.isEmpty ? "Style_\(rawPens.count)" : name,
                policy: Int(currentFields["color_policy"] ?? "1") ?? 1,
                colorRaw: Int(currentFields["color"] ?? "-1") ?? -1,
                modeRaw: currentFields["mode_color"].flatMap(Int.init),
                screen: Int(currentFields["screen"] ?? "100") ?? 100,
                lwIndex: Int(currentFields["lineweight"] ?? "0") ?? 0))
            currentFields = [:]
        }
        func buildPen(_ raw: RawPen) -> PlotStylePen {
            let color: UInt32?
            switch raw.policy {
            case 5:
                color = raw.colorRaw == -1 ? nil : UInt32(bitPattern: Int32(raw.colorRaw))
            case 0:
                let v = raw.modeRaw ?? raw.colorRaw
                color = v == -1 ? nil : UInt32(bitPattern: Int32(v))
            default:
                color = nil // 1 = object color, 3 = object grayscale
            }
            // Index 0 = object lineweight; out-of-range = object (tolerant).
            let lwMM: Double? = (raw.lwIndex > 0 && raw.lwIndex < lineweights.count)
                ? lineweights[raw.lwIndex] : nil
            return PlotStylePen(
                name: raw.name, colorARGB: color, colorPolicy: raw.policy,
                screeningPercent: raw.screen, lineweightMM: lwMM)
        }

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line == "plot_style{" {
                inPlotStyle = true
                plotDepth = 0
                inLineweightTable = false
                continue
            }
            if line == "custom_lineweight_table{" {
                inPlotStyle = false
                inLineweightTable = true
                continue
            }
            if line == "}" {
                if inPlotStyle, plotDepth > 0 {
                    flushPen()
                    plotDepth -= 1
                } else {
                    inPlotStyle = false
                    inLineweightTable = false
                }
                continue
            }
            if inLineweightTable {
                // ` N=F.F` — indices are dense from 0.
                let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2, let idx = Int(parts[0].trimmingCharacters(in: .whitespaces)),
                   let mm = Double(parts[1]) {
                    while lineweights.count <= idx { lineweights.append(0) }
                    lineweights[idx] = mm
                }
                continue
            }
            if inPlotStyle {
                if line.hasSuffix("{") {
                    // ` N{` starts a style record (nested depth).
                    plotDepth += 1
                    currentFields = [:]
                    continue
                }
                let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 {
                    currentFields[parts[0]] = stripped(parts[1])
                }
                continue
            }
        }

        // Lineweight indices resolve after the table (pen records precede it).
        let pens = rawPens.map(buildPen)
        return PlotStyleTable(kind: kind, pens: pens, lineweightTable: lineweights)
    }

    // MARK: - zlib inflate (mirrors PDFWriter.compressDeflate)

    static func inflateZlib(_ input: Data) throws -> Data {
        guard !input.isEmpty else { throw ParseError.truncatedPayload }
        var strm = zng_stream()
        var ret = zng_inflateInit(&strm)
        guard ret == Z_OK else { throw ParseError.inflateFailed }
        defer { zng_inflateEnd(&strm) }

        var output = [UInt8](repeating: 0, count: max(input.count * 4, 4096))
        var totalOut = 0
        var finished = false
        try input.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            guard let base = ptr.bindMemory(to: UInt8.self).baseAddress else {
                throw ParseError.truncatedPayload
            }
            strm.next_in = UnsafePointer(base)
            strm.avail_in = UInt32(input.count)
            repeat {
                let outOffset = totalOut
                let outRemaining = output.count - outOffset
                var outLeft = UInt32(outRemaining)
                let ok: Bool = output.withUnsafeMutableBufferPointer { bufPtr in
                    guard let b = bufPtr.baseAddress else { return false }
                    strm.next_out = b + outOffset
                    strm.avail_out = UInt32(outRemaining)
                    ret = zng_inflate(&strm, Z_FINISH)
                    outLeft = strm.avail_out
                    return true
                }
                guard ok else { throw ParseError.inflateFailed }
                totalOut = output.count - Int(outLeft)
                if ret == Z_STREAM_END {
                    finished = true
                } else if outLeft == 0 {
                    // Output full (Z_OK or Z_BUF_ERROR): grow and continue.
                    output.append(contentsOf: repeatElement(0, count: output.count))
                } else if strm.avail_in == 0 {
                    finished = true // input consumed; accept bytes so far
                } else {
                    throw ParseError.inflateFailed
                }
            } while !finished
        }
        guard finished, totalOut > 0 else { throw ParseError.inflateFailed }
        return Data(output.prefix(totalOut))
    }
}
