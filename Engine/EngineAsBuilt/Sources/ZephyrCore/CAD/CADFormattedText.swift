import Foundation

// =========================================================================
// MARK: - CADFormattedText
//
// Structured representation of formatted text that can express all
// AutoCAD MTEXT capabilities: font changes, height, color, underline,
// overline, stacking (fractions), width factor, tracking, oblique,
// alignment, and paragraph breaks.
//
// Used by the DXF importer (parse MTEXT codes → FormattedText),
// the renderer (iterate runs with per-run formatting), and the
// DXF exporter (serialize FormattedText → MTEXT codes).

// =========================================================================
// MARK: - StackedText
// =========================================================================

/// Represents a stacked fraction: numerator over denominator with a
/// horizontal fraction bar (^), diagonal fraction bar (/), or no bar (#).
public struct StackedText: Codable, Sendable, Hashable {
    public enum Style: String, Codable, Sendable, Hashable {
        case horizontal  // ^  — horizontal bar (tolerance style)
        case diagonal    // /  — diagonal slash (fraction style)
        case tolerance   // #  — no bar (tolerance/suffix style)
    }

    public let numerator: String
    public let denominator: String
    public let style: Style

    public init(numerator: String, denominator: String, style: Style = .horizontal) {
        self.numerator = numerator
        self.denominator = denominator
        self.style = style
    }
}

// =========================================================================
// MARK: - FormattedTextRun
// =========================================================================

/// An atomic run of text with uniform formatting.
/// Properties that are `nil` inherit from the current state (defaults
/// from the enclosing paragraph or FormattedText).
public struct FormattedTextRun: Codable, Sendable, Hashable {
    public var text: String
    public var fontName: String?
    public var height: Double?
    public var color: ColorRGBA?
    public var bold: Bool
    public var italic: Bool
    public var underline: Bool
    public var overline: Bool
    public var oblique: Double?
    public var widthFactor: Double?
    public var tracking: Double?
    public var stack: StackedText?

    public init(
        text: String,
        fontName: String? = nil,
        height: Double? = nil,
        color: ColorRGBA? = nil,
        bold: Bool = false,
        italic: Bool = false,
        underline: Bool = false,
        overline: Bool = false,
        oblique: Double? = nil,
        widthFactor: Double? = nil,
        tracking: Double? = nil,
        stack: StackedText? = nil
    ) {
        self.text = text
        self.fontName = fontName
        self.height = height
        self.color = color
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.overline = overline
        self.oblique = oblique
        self.widthFactor = widthFactor
        self.tracking = tracking
        self.stack = stack
    }

    /// Returns true if any formatting property is non-nil/non-default.
    public var hasFormatting: Bool {
        fontName != nil || height != nil || color != nil
            || bold || italic || underline || overline
            || oblique != nil || widthFactor != nil || tracking != nil
            || stack != nil
    }
}

// =========================================================================
// MARK: - FormattedParagraph
// =========================================================================

/// A paragraph of formatted text: a sequence of runs with a single
/// alignment setting.
public struct FormattedParagraph: Codable, Sendable, Hashable {
    /// 0 = inherit entity alignment, 1 = center, 2 = right,
    /// 3 = justified, 4 = distributed, 5 = explicit left
    public var alignment: Int
    public var firstLineIndent: Double?
    public var leftIndent: Double?
    public var rightIndent: Double?
    public var tabStops: [Double]?
    public var runs: [FormattedTextRun]

    public init(
        alignment: Int = 0,
        firstLineIndent: Double? = nil,
        leftIndent: Double? = nil,
        rightIndent: Double? = nil,
        tabStops: [Double]? = nil,
        runs: [FormattedTextRun] = []
    ) {
        self.alignment = alignment
        self.firstLineIndent = firstLineIndent
        self.leftIndent = leftIndent
        self.rightIndent = rightIndent
        self.tabStops = tabStops
        self.runs = runs
    }

    /// Plain-text content of this paragraph.
    public var plainText: String {
        runs.map { $0.stack != nil ? "[\($0.stack!.numerator)/\($0.stack!.denominator)]" : $0.text }.joined()
    }

    public var isEmpty: Bool {
        runs.isEmpty || runs.allSatisfy { $0.text.isEmpty && $0.stack == nil }
    }
}

// =========================================================================
// MARK: - FormattedText
// =========================================================================

/// Top-level formatted text container: default formatting for the entity,
/// plus a list of paragraphs.
public struct FormattedText: Codable, Sendable, Hashable {
    public var styleName: String?
    public var defaultFont: String
    public var defaultHeight: Double
    public var defaultColor: ColorRGBA
    public var paragraphs: [FormattedParagraph]

    public init(
        styleName: String? = nil,
        defaultFont: String = "simplex.shx",
        defaultHeight: Double = 2.5,
        defaultColor: ColorRGBA = .white,
        paragraphs: [FormattedParagraph] = []
    ) {
        self.styleName = styleName
        self.defaultFont = defaultFont
        self.defaultHeight = defaultHeight
        self.defaultColor = defaultColor
        self.paragraphs = paragraphs
    }

    /// Extract plain text (strips all formatting, preserves paragraph breaks).
    public func toPlainText() -> String {
        paragraphs.map { $0.plainText }.joined(separator: "\n")
    }

    /// Create a simple FormattedText from a plain string with the given defaults.
    public static func plain(
        _ text: String,
        styleName: String? = nil,
        font: String = "simplex.shx",
        height: Double = 2.5,
        color: ColorRGBA = .white
    ) -> FormattedText {
        let lines = text.components(separatedBy: "\n")
        let paragraphs = lines.map { line in
            FormattedParagraph(
                alignment: 0,
                runs: line.isEmpty
                    ? []
                    : [FormattedTextRun(text: line)]
            )
        }
        return FormattedText(
            styleName: styleName,
            defaultFont: font,
            defaultHeight: height,
            defaultColor: color,
            paragraphs: paragraphs
        )
    }
}

// =========================================================================
// MARK: - MTEXTFormatter
// =========================================================================

/// Parses and serializes AutoCAD MTEXT control codes.
///
/// ## Supported control codes
///
/// | Code | Meaning |
/// |------|---------|
/// | `\fFont|b0|i0|c0|p34;` | Font change (name, bold, italic, codepage, pitch) |
/// | `\H2.5;` / `\H2.5x;` | Height (absolute or relative to default) |
/// | `\C1;` / `\cRRGGBB;` | Color (ACI index or RGB hex) |
/// | `\L` / `\l` | Underline start / stop |
/// | `\O` / `\o` | Overline start / stop |
/// | `\S...^...;` / `\S.../...;` / `\S...#...;` | Stacked fraction |
/// | `\W2.0;` | Width factor |
/// | `\T1.5;` | Tracking |
/// | `\Q30;` | Oblique angle |
/// | `\A0;` / `\A1;` / `\A2;` | Legacy alignment override |
/// | `\pxql;` / `\pxqc;` / `\pxqr;` | Paragraph left/center/right justification |
/// | `\pxqj;` / `\pxqd;` | Paragraph justified/distributed justification |
/// | `\P` | Paragraph break |
/// | `\{` `\}` `\\` | Escaped braces and backslash |
/// | `{...}` | Nested formatting group |
/// | `%%u` `%%d` `%%p` `%%c` | Special characters |
public enum MTEXTFormatter {

    // MARK: - Public API

    /// Parse a raw MTEXT string into structured `FormattedText`.
    /// - Parameters:
    ///   - raw: The raw MTEXT content string (may contain formatting codes).
    ///   - defaultFont: Fallback font name.
    ///   - defaultHeight: Fallback text height.
    /// - Returns: A `FormattedText` with paragraphs and runs.
    public static func parse(
        _ raw: String,
        defaultFont: String = "simplex.shx",
        defaultHeight: Double = 2.5,
        defaultColor: ColorRGBA = .white
    ) -> FormattedText {
        var parser = Parser(
            input: Array(raw),
            defaultFont: defaultFont,
            defaultHeight: defaultHeight,
            defaultColor: defaultColor
        )
        return parser.parse()
    }

    /// Serialize `FormattedText` back into an MTEXT string.
    /// - Parameter formatted: The structured formatted text.
    /// - Returns: A string suitable for DXF MTEXT group code 1.
    public static func serialize(_ formatted: FormattedText) -> String {
        var out = ""

        // Emit font/height if different from AutoCAD defaults (which are
        // typically handled by the STYLE table). We emit a leading \f and \H
        // to lock in the entity's default font/height.
        out += "\\f\(formatted.defaultFont);"
        out += "\\H\(formatted.defaultHeight);"

        for (pIdx, paragraph) in formatted.paragraphs.enumerated() {
            if pIdx > 0 {
                out += "\\P"
            }
            var paragraphProperties: [String] = []
            if let indent = paragraph.firstLineIndent {
                paragraphProperties.append("i\(indent)")
            }
            if let indent = paragraph.leftIndent {
                paragraphProperties.append("l\(indent)")
            }
            if let indent = paragraph.rightIndent {
                paragraphProperties.append("r\(indent)")
            }
            if let stops = paragraph.tabStops {
                if stops.isEmpty {
                    paragraphProperties.append("tz")
                } else {
                    paragraphProperties.append(
                        "t" + stops.map { String($0) }.joined(separator: ","))
                }
            }
            switch paragraph.alignment {
            case 1: paragraphProperties.append("qc")
            case 2: paragraphProperties.append("qr")
            case 3: paragraphProperties.append("qj")
            case 4: paragraphProperties.append("qd")
            case 5: paragraphProperties.append("ql")
            default: break
            }
            if !paragraphProperties.isEmpty {
                out += "\\px" + paragraphProperties.joined(separator: ",") + ";"
            }
            for run in paragraph.runs {
                if let stack = run.stack {
                    out += serializeStack(stack)
                } else if run.hasFormatting {
                    out += "{"
                    if let fn = run.fontName { out += "\\f\(fn);" }
                    if let h = run.height { out += "\\H\(h);" }
                    if let c = run.color {
                        let hex = String(format: "%02X%02X%02X", c.r, c.g, c.b)
                        out += "\\c\(hex);"
                    }
                    if run.bold { out += "\\f\(run.fontName ?? "")|b1;" }
                    if run.italic { out += "\\f\(run.fontName ?? "")|i1;" }
                    if run.underline { out += "\\L" }
                    if run.overline { out += "\\O" }
                    if let wf = run.widthFactor { out += "\\W\(wf);" }
                    if let tr = run.tracking { out += "\\T\(tr);" }
                    if let ob = run.oblique { out += "\\Q\(ob);" }
                    out += escapeText(run.text)
                    if run.overline { out += "\\o" }
                    if run.underline { out += "\\l" }
                    out += "}"
                } else {
                    out += escapeText(run.text)
                }
            }
        }

        return out
    }

    // MARK: - Internal Helpers

    private static func escapeText(_ text: String) -> String {
        var result = ""
        for ch in text {
            switch ch {
            case "\\": result += "\\\\"
            case "{":  result += "\\{"
            case "}":  result += "\\}"
            default:   result.append(ch)
            }
        }
        return result
    }

    private static func serializeStack(_ stack: StackedText) -> String {
        let sep: Character
        switch stack.style {
        case .horizontal: sep = "^"
        case .diagonal:   sep = "/"
        case .tolerance:  sep = "#"
        }
        return "\\S\(stack.numerator)\(sep)\(stack.denominator);"
    }
}

// =========================================================================
// MARK: - MTEXT Parser State Machine
// =========================================================================

extension MTEXTFormatter {

    /// Mutable formatting state that tracks inherited properties.
    private struct FormatState {
        var fontName: String
        var height: Double
        var color: ColorRGBA
        var bold: Bool = false
        var italic: Bool = false
        var underline: Bool = false
        var overline: Bool = false
        var oblique: Double? = nil
        var widthFactor: Double? = nil
        var tracking: Double? = nil

        /// Build a FormattedTextRun from this state (excluding stack).
        func makeRun(text: String) -> FormattedTextRun {
            FormattedTextRun(
                text: text,
                fontName: fontName,
                height: height,
                color: color,
                bold: bold,
                italic: italic,
                underline: underline,
                overline: overline,
                oblique: oblique,
                widthFactor: widthFactor,
                tracking: tracking
            )
        }
    }

    private struct Parser {
        let chars: [Character]
        var pos: Int = 0
        let defaultFont: String
        let defaultHeight: Double
        let defaultColor: ColorRGBA

        /// Result accumulator.
        var paragraphs: [FormattedParagraph] = [FormattedParagraph()]
        var currentAlignment: Int = 0
        var currentFirstLineIndent: Double? = nil
        var currentLeftIndent: Double? = nil
        var currentRightIndent: Double? = nil
        var currentTabStops: [Double]? = nil
        var currentRuns: [FormattedTextRun] = []

        /// Formatting stack for `{...}` groups.
        var stateStack: [FormatState] = []
        var state: FormatState

        /// Accumulator for plain text between control codes.
        var textBuf: String = ""

        init(input: [Character], defaultFont: String, defaultHeight: Double, defaultColor: ColorRGBA) {
            self.chars = input
            self.defaultFont = defaultFont
            self.defaultHeight = defaultHeight
            self.defaultColor = defaultColor
            self.state = FormatState(
                fontName: defaultFont,
                height: defaultHeight,
                color: defaultColor
            )
        }

        // MARK: - Main Loop

        mutating func parse() -> FormattedText {
            while pos < chars.count {
                let c = chars[pos]

                if c == "{" {
                    flushText()
                    pos += 1
                    // Push current state onto stack
                    stateStack.append(state)
                } else if c == "}" {
                    flushText()
                    pos += 1
                    // Pop state
                    if let prev = stateStack.popLast() {
                        state = prev
                    }
                } else if c == "\\" || c == "¥" {
                    flushText()
                    pos += 1
                    parseControlCode()
                } else if c == "^", pos + 1 < chars.count {
                    let next = chars[pos + 1]
                    switch next {
                    case "I", "i":
                        textBuf.append("\t")
                        pos += 2
                    case "J", "j", "M", "m":
                        flushText()
                        newParagraph()
                        pos += 2
                    case "^":
                        textBuf.append("^")
                        pos += 2
                    default:
                        textBuf.append(c)
                        pos += 1
                    }
                } else if c == "%" {
                    // %% special characters
                    if pos + 2 < chars.count && chars[pos + 1] == "%" {
                        flushText()
                        pos += 2
                        parsePercentCode()
                    } else {
                        textBuf.append(c)
                        pos += 1
                    }
                } else if c == "\n" || c == "\r" {
                    flushText()
                    newParagraph()
                    pos += 1
                    // Skip \r\n pair
                    if c == "\r" && pos < chars.count && chars[pos] == "\n" {
                        pos += 1
                    }
                } else {
                    textBuf.append(c)
                    pos += 1
                }
            }

            flushText()
            commitParagraph()

            return FormattedText(
                defaultFont: defaultFont,
                defaultHeight: defaultHeight,
                defaultColor: defaultColor,
                paragraphs: paragraphs
            )
        }

        // MARK: - Helpers

        private mutating func flushText() {
            if !textBuf.isEmpty {
                currentRuns.append(state.makeRun(text: textBuf))
                textBuf = ""
            }
        }

        private mutating func commitParagraph() {
            if currentRuns.isEmpty && paragraphs.last?.runs.isEmpty == true {
                // Avoid adding empty paragraphs repeatedly
                return
            }
            paragraphs[paragraphs.count - 1] = FormattedParagraph(
                alignment: currentAlignment,
                firstLineIndent: currentFirstLineIndent,
                leftIndent: currentLeftIndent,
                rightIndent: currentRightIndent,
                tabStops: currentTabStops,
                runs: currentRuns
            )
            currentRuns = []
        }

        private mutating func newParagraph() {
            commitParagraph()
            paragraphs.append(FormattedParagraph(
                alignment: currentAlignment,
                firstLineIndent: currentFirstLineIndent,
                leftIndent: currentLeftIndent,
                rightIndent: currentRightIndent,
                tabStops: currentTabStops))
        }

        // MARK: - Control Code Parsing

        private mutating func parseControlCode() {
            guard pos < chars.count else { return }

            let code = chars[pos]
            pos += 1

            switch code {
            case "P":
                // Paragraph break
                newParagraph()

            case "L":
                // Underline start
                state.underline = true

            case "l":
                // Underline stop
                state.underline = false

            case "O":
                // Overline start
                state.overline = true

            case "o":
                // Overline stop
                state.overline = false

            case "f", "F":
                parseFontSpec()

            case "H", "h":
                parseHeightSpec()

            case "C", "c":
                parseColorSpec()

            case "S", "s":
                parseStackSpec()

            case "W", "w":
                state.widthFactor = parseNumericValue()

            case "T", "t":
                state.tracking = parseNumericValue()

            case "Q", "q":
                state.oblique = parseNumericValue()

            case "A", "a":
                parseAlignmentSpec()

            case "\\", "¥":
                textBuf.append("\\")

            case "{":
                textBuf.append("{")

            case "}":
                textBuf.append("}")

            case "p":
                parseParagraphProperties()

            default:
                // Unknown control code — skip everything up to semicolon if present
                // Some codes are followed by semicolon, others aren't
                break
            }
        }

        // MARK: - Paragraph Properties: \pxql; \pxqc; \pxqr; \pxqj; \pxqd;

        private mutating func parseParagraphProperties() {
            var spec = ""
            while pos < chars.count && chars[pos] != ";" {
                spec.append(chars[pos])
                pos += 1
            }
            if pos < chars.count && chars[pos] == ";" {
                pos += 1
            }

            var tabStops = currentTabStops
            var parsingTabStops = false
            for rawPart in spec.split(separator: ",", omittingEmptySubsequences: true) {
                var part = String(rawPart).lowercased()
                while part.first == "x" {
                    part.removeFirst()
                }
                guard let key = part.first else { continue }
                let value = String(part.dropFirst())

                if parsingTabStops, let number = Double(part) {
                    if tabStops == nil || tabStops?.isEmpty == true {
                        tabStops = []
                    }
                    tabStops?.append(number)
                    continue
                }
                parsingTabStops = false

                switch key {
                case "q":
                    switch value.first {
                    case "c": currentAlignment = 1
                    case "r": currentAlignment = 2
                    case "j": currentAlignment = 3
                    case "d": currentAlignment = 4
                    case "l": currentAlignment = 5
                    default: break
                    }
                case "i":
                    if let number = Double(value) {
                        currentFirstLineIndent = number
                    }
                case "l":
                    if let number = Double(value) {
                        currentLeftIndent = number
                    }
                case "r":
                    if let number = Double(value) {
                        currentRightIndent = number
                    }
                case "t":
                    if value == "z" {
                        tabStops = []
                    } else if let number = Double(value) {
                        tabStops = [number]
                        parsingTabStops = true
                    }
                default:
                    break
                }
            }
            currentTabStops = tabStops
        }

        // MARK: - Font Spec: \fFontName|b0|i0|c0|p34;

        private mutating func parseFontSpec() {
            var spec = ""
            while pos < chars.count && chars[pos] != ";" {
                spec.append(chars[pos])
                pos += 1
            }
            if pos < chars.count && chars[pos] == ";" {
                pos += 1
            }

            let parts = spec.components(separatedBy: "|")
            if let name = parts.first, !name.isEmpty {
                state.fontName = name
            }
            // b0/b1 = bold
            for part in parts {
                if part.hasPrefix("b") {
                    state.bold = (part.dropFirst() == "1")
                }
                if part.hasPrefix("i") {
                    state.italic = (part.dropFirst() == "1")
                }
            }
        }

        // MARK: - Height Spec: \H2.5; or \H2.5x;

        private mutating func parseHeightSpec() {
            var numStr = ""
            var isRelative = false
            while pos < chars.count && chars[pos] != ";" {
                let ch = chars[pos]
                if ch == "x" || ch == "X" {
                    isRelative = true
                    pos += 1
                    break
                }
                if ch.isNumber || ch == "." || ch == "-" {
                    numStr.append(ch)
                }
                pos += 1
            }
            // Skip remaining chars to semicolon
            while pos < chars.count && chars[pos] != ";" {
                pos += 1
            }
            if pos < chars.count && chars[pos] == ";" {
                pos += 1
            }
            if let val = Double(numStr) {
                if isRelative {
                    state.height *= val
                } else {
                    state.height = val
                }
            }
        }

        // MARK: - Color Spec: \C1; or \cRRGGBB;

        private mutating func parseColorSpec() {
            var valStr = ""
            while pos < chars.count && chars[pos] != ";" {
                valStr.append(chars[pos])
                pos += 1
            }
            if pos < chars.count && chars[pos] == ";" {
                pos += 1
            }

            if valStr.count == 6 {
                // RGB hex
                if let rgb = UInt32(valStr, radix: 16) {
                    state.color = ColorRGBA(
                        r: UInt8((rgb >> 16) & 0xFF),
                        g: UInt8((rgb >> 8) & 0xFF),
                        b: UInt8(rgb & 0xFF)
                    )
                }
            } else if let aci = Int(valStr) {
                // ACI color index (simplified mapping)
                state.color = aciToRGBA(aci)
            }
        }

        // MARK: - Stack Spec: \Snumerator^denominator; etc.

        private mutating func parseStackSpec() {
            var spec = ""
            while pos < chars.count && chars[pos] != ";" {
                spec.append(chars[pos])
                pos += 1
            }
            if pos < chars.count && chars[pos] == ";" {
                pos += 1
            }

            let style: StackedText.Style
            let separator: Character

            if spec.contains("^") {
                style = .horizontal
                separator = "^"
            } else if spec.contains("/") {
                style = .diagonal
                separator = "/"
            } else if spec.contains("#") {
                style = .tolerance
                separator = "#"
            } else {
                // Malformed — treat as plain text
                textBuf.append(spec)
                return
            }

            let parts = spec.split(separator: separator, maxSplits: 1)
            let num = parts.count > 0 ? String(parts[0]) : ""
            let den = parts.count > 1 ? String(parts[1]) : ""

            currentRuns.append(FormattedTextRun(
                text: "",
                fontName: state.fontName,
                height: state.height,
                color: state.color,
                bold: state.bold,
                italic: state.italic,
                underline: state.underline,
                overline: state.overline,
                oblique: state.oblique,
                widthFactor: state.widthFactor,
                tracking: state.tracking,
                stack: StackedText(numerator: num, denominator: den, style: style)
            ))
        }

        // MARK: - Alignment Spec: \A0; \A1; \A2;

        private mutating func parseAlignmentSpec() {
            var valStr = ""
            while pos < chars.count && chars[pos] != ";" {
                if chars[pos].isNumber {
                    valStr.append(chars[pos])
                }
                pos += 1
            }
            if pos < chars.count && chars[pos] == ";" {
                pos += 1
            }
            if let val = Int(valStr), val >= 0 && val <= 2 {
                currentAlignment = val
            }
        }

        // MARK: - Numeric Value Helper

        @discardableResult
        private mutating func parseNumericValue() -> Double? {
            var numStr = ""
            while pos < chars.count && chars[pos] != ";" {
                let ch = chars[pos]
                if ch.isNumber || ch == "." || ch == "-" {
                    numStr.append(ch)
                }
                pos += 1
            }
            if pos < chars.count && chars[pos] == ";" {
                pos += 1
            }
            if let val = Double(numStr) {
                return val
            }
            return nil
        }

        // MARK: - Percent Code: %%u %%d %%p %%c %%

        private mutating func parsePercentCode() {
            guard pos < chars.count else { return }
            let code = chars[pos]
            pos += 1

            switch code {
            case "u", "U":
                state.underline.toggle()
            case "d", "D":
                textBuf.append("\u{00B0}")  // °
            case "p", "P":
                textBuf.append("\u{00B1}")  // ±
            case "c", "C":
                textBuf.append("\u{2205}")  // ∅
            case "%":
                textBuf.append("%")
            default:
                textBuf.append("%%")
                textBuf.append(code)
            }
        }

        // MARK: - Helpers

        private mutating func skipToSemicolon() {
            while pos < chars.count && chars[pos] != ";" {
                pos += 1
            }
            if pos < chars.count && chars[pos] == ";" {
                pos += 1
            }
        }

        /// Simplified ACI → RGBA mapping (1-9 standard colors, 250-255 grays).
        private func aciToRGBA(_ aci: Int) -> ColorRGBA {
            switch aci {
            case 1:  return ColorRGBA(r: 255, g: 0,   b: 0)     // Red
            case 2:  return ColorRGBA(r: 255, g: 255, b: 0)     // Yellow
            case 3:  return ColorRGBA(r: 0,   g: 255, b: 0)     // Green
            case 4:  return ColorRGBA(r: 0,   g: 255, b: 255)   // Cyan
            case 5:  return ColorRGBA(r: 0,   g: 0,   b: 255)   // Blue
            case 6:  return ColorRGBA(r: 255, g: 0,   b: 255)   // Magenta
            case 7:  return ColorRGBA(r: 255, g: 255, b: 255)   // White
            case 8:  return ColorRGBA(r: 128, g: 128, b: 128)   // Dark Gray
            case 9:  return ColorRGBA(r: 192, g: 192, b: 192)   // Light Gray
            case 250..<256:
                let g = UInt8(255 - (255 - aci) * 2)
                return ColorRGBA(r: g, g: g, b: g)
            default:
                return .white
            }
        }
    }
}
