import Foundation

// =========================================================================
// MARK: - CADTextFormatter
//
// Handles AutoCAD-style MText layout: word wrapping at a maximum width,
// underline ranges (%%u...%%u), and special character codes (%%c=diameter,
// %%d=degree, %%p=plus/minus).
//
// Used by the engine's text rendering pipeline to break long text into
// lines and generate underline primitives for %%u spans.

public enum CADTextFormatter {
    public struct Glyph: Sendable {
        public let text: String
        public let underline: Bool
        public let bold: Bool
        public let italic: Bool
        public let heightScale: Double

        public init(
            _ text: String,
            underline: Bool,
            bold: Bool = false,
            italic: Bool = false,
            heightScale: Double = 1.0
        ) {
            self.text = text
            self.underline = underline
            self.bold = bold
            self.italic = italic
            self.heightScale = heightScale.isFinite && heightScale > 0 ? heightScale : 1.0
        }
    }

    public struct Line: Sendable {
        public let glyphs: [Glyph]
        public let alignment: Int

        public init(glyphs: [Glyph], alignment: Int = 0) {
            self.glyphs = glyphs
            self.alignment = alignment
        }

        public var text: String {
            glyphs.map { $0.text }.joined()
        }

        public var isEmpty: Bool {
            glyphs.isEmpty || text.isEmpty
        }
    }

    public static func layout(
        formatted: FormattedText,
        maxWidth: Double?,
        measure: (String) -> Double
    ) -> [Line] {
        let paragraphs = formatted.paragraphs.map { paragraph in
            (
                glyphs: paragraph.runs.flatMap { run -> [Glyph] in
                    let value: String
                    if let stack = run.stack {
                        value = "\(stack.numerator)/\(stack.denominator)"
                    } else {
                        value = run.text
                    }
                    let baseHeight = formatted.defaultHeight
                    let runScale: Double = {
                        guard baseHeight.isFinite && baseHeight > 0 else { return 1.0 }
                        let h = run.height ?? baseHeight
                        guard h.isFinite && h > 0 else { return 1.0 }
                        return h / baseHeight
                    }()
                    return value.map {
                        Glyph(
                            String($0),
                            underline: run.underline,
                            bold: run.bold,
                            italic: run.italic,
                            heightScale: runScale)
                    }
                    /* Superseded: pre-scale MTEXT map kept for reference.
                       The scale-aware block above returns instead.
                        Glyph(
                            String($0),
                            underline: run.underline,
                            bold: run.bold,
                            italic: run.italic)
                    }
                    */
                },
                alignment: paragraph.alignment
            )
        }
        return layoutParagraphs(paragraphs, maxWidth: maxWidth, measure: measure)
    }

    public static func layout(
        _ raw: String,
        maxWidth: Double?,
        measure: (String) -> Double
    ) -> [Line] {
        layoutParagraphs(
            parse(raw).map { (glyphs: $0, alignment: 0) },
            maxWidth: maxWidth,
            measure: measure)
    }

    /// Width of glyphs at their own height scales: contiguous runs of equal
    /// scale are measured once and scaled, so `\H` runs wrap where the
    /// shrunken glyphs actually fit. Uniform-scale text measures exactly
    /// like `measure(string(from:))`.
    private static func widthOfGlyphs(_ glyphs: [Glyph], measure: (String) -> Double) -> Double {
        var total = 0.0
        var index = glyphs.startIndex
        while index < glyphs.endIndex {
            let scale = glyphs[index].heightScale
            var end = glyphs.index(after: index)
            while end < glyphs.endIndex && glyphs[end].heightScale == scale {
                end = glyphs.index(after: end)
            }
            total += measure(string(from: Array(glyphs[index..<end]))) * scale
            index = end
        }
        return total
    }

    private static func layoutParagraphs(
        _ paragraphs: [(glyphs: [Glyph], alignment: Int)],
        maxWidth: Double?,
        measure: (String) -> Double
    ) -> [Line] {
        guard let maxWidth, maxWidth > 0 else {
            return paragraphs.map {
                Line(glyphs: $0.glyphs, alignment: $0.alignment)
            }
        }

        var lines: [Line] = []

        for paragraph in paragraphs {
            let runs = splitRuns(paragraph.glyphs)

            if runs.isEmpty {
                lines.append(Line(glyphs: [], alignment: paragraph.alignment))
                continue
            }

            var current: [Glyph] = []
            var pendingWhitespace: [Glyph] = []

            for run in runs {
                if run.isWhitespace {
                    if current.isEmpty {
                        current.append(contentsOf: run.glyphs)
                    } else {
                        pendingWhitespace.append(contentsOf: run.glyphs)
                    }
                    continue
                }

                let candidate = current + pendingWhitespace + run.glyphs
                let currentHasText = current.contains { !isWhitespace($0) }

                if currentHasText && widthOfGlyphs(candidate, measure: measure) > maxWidth {
                    lines.append(Line(
                        glyphs: current,
                        alignment: paragraph.alignment))
                    current = run.glyphs
                } else {
                    current = candidate
                }
                pendingWhitespace.removeAll(keepingCapacity: true)
            }

            if !pendingWhitespace.isEmpty {
                current.append(contentsOf: pendingWhitespace)
            }
            if !current.isEmpty {
                lines.append(Line(
                    glyphs: current,
                    alignment: paragraph.alignment))
            }
        }

        return lines.isEmpty ? [Line(glyphs: [], alignment: 0)] : lines
    }

    public static func underlineRanges(
        for line: Line,
        measure: (String) -> Double
    ) -> [(x: Double, width: Double)] {
        var ranges: [(x: Double, width: Double)] = []
        var x = 0.0
        var start: Double?

        for glyph in line.glyphs {
            let w = measure(glyph.text) * glyph.heightScale

            if glyph.underline {
                if start == nil { start = x }
            } else if let s = start {
                if x > s { ranges.append((s, x - s)) }
                start = nil
            }

            x += w
        }

        if let s = start, x > s {
            ranges.append((s, x - s))
        }

        return ranges
    }

    private static func parse(_ raw: String) -> [[Glyph]] {
        let chars = Array(raw)
        var paragraphs: [[Glyph]] = [[]]
        var underline = false
        var i = 0

        func add(_ s: String) {
            paragraphs[paragraphs.count - 1].append(Glyph(s, underline: underline))
        }

        func newline() {
            paragraphs.append([])
        }

        func skipToSemicolon() {
            while i < chars.count && chars[i] != ";" {
                i += 1
            }
            if i < chars.count && chars[i] == ";" {
                i += 1
            }
        }

        while i < chars.count {
            let c = chars[i]

            if c == "%", i + 2 < chars.count, chars[i + 1] == "%" {
                let code = String(chars[i + 2]).lowercased()

                switch code {
                case "u":
                    underline.toggle()
                    i += 3
                    continue
                case "d":
                    add("°")
                    i += 3
                    continue
                case "p":
                    add("±")
                    i += 3
                    continue
                case "c":
                    add("Ø")
                    i += 3
                    continue
                case "%":
                    add("%")
                    i += 3
                    continue
                default:
                    add(String(c))
                    i += 1
                    continue
                }
            }

            if c == "^", i + 1 < chars.count {
                let next = chars[i + 1]
                switch next {
                case "I", "i":
                    add("\t")
                    i += 2
                    continue
                case "J", "j", "M", "m":
                    newline()
                    i += 2
                    continue
                case "^":
                    add("^")
                    i += 2
                    continue
                default:
                    break
                }
            }

            if c == "\\" || c == "¥" {
                guard i + 1 < chars.count else {
                    i += 1
                    continue
                }

                let next = chars[i + 1]

                switch next {
                case "P":
                    newline()
                    i += 2
                    continue
                case "p":
                    i += 2
                    skipToSemicolon()
                    continue
                case "L":
                    underline = true
                    i += 2
                    continue
                case "l":
                    underline = false
                    i += 2
                    continue
                case "O", "o", "K", "k":
                    i += 2
                    continue
                case "\\", "{", "}":
                    add(String(next))
                    i += 2
                    continue
                case "F", "f", "H", "h", "W", "w", "Q", "q", "T", "t", "A", "a", "C", "c":
                    i += 2
                    skipToSemicolon()
                    continue
                case "S":
                    i += 2
                    var top = ""
                    var bottom = ""
                    var isBottom = false

                    while i < chars.count && chars[i] != ";" {
                        if chars[i] == "^" || chars[i] == "/" || chars[i] == "#" {
                            isBottom = true
                        } else if isBottom {
                            bottom.append(chars[i])
                        } else {
                            top.append(chars[i])
                        }
                        i += 1
                    }

                    if i < chars.count && chars[i] == ";" {
                        i += 1
                    }

                    if !top.isEmpty && !bottom.isEmpty {
                        add("\(top)/\(bottom)")
                    } else {
                        add(top + bottom)
                    }
                    continue
                default:
                    add(String(next))
                    i += 2
                    continue
                }
            }

            if c == "{" || c == "}" {
                i += 1
                continue
            }

            if c == "\n" || c == "\r" {
                newline()
                i += 1
                continue
            }

            add(String(c))
            i += 1
        }

        return paragraphs
    }

    private struct GlyphRun {
        var glyphs: [Glyph]
        var isWhitespace: Bool
    }

    private static func splitRuns(_ glyphs: [Glyph]) -> [GlyphRun] {
        var runs: [GlyphRun] = []
        var current: [Glyph] = []
        var currentIsWhitespace: Bool?

        func flush() {
            guard let isWhitespace = currentIsWhitespace, !current.isEmpty else { return }
            runs.append(GlyphRun(glyphs: current, isWhitespace: isWhitespace))
            current.removeAll(keepingCapacity: true)
        }

        for glyph in glyphs {
            let whitespace = isWhitespace(glyph)
            if currentIsWhitespace != nil && currentIsWhitespace != whitespace {
                flush()
            }
            currentIsWhitespace = whitespace

            if glyph.text == "\t" {
                for _ in 0..<4 {
                    current.append(Glyph(
                        " ",
                        underline: glyph.underline,
                        bold: glyph.bold,
                        italic: glyph.italic))
                }
            } else {
                current.append(glyph)
            }
        }

        flush()
        return runs
    }

    private static func isWhitespace(_ glyph: Glyph) -> Bool {
        glyph.text == " " || glyph.text == "\t"
    }

    private static func string(from glyphs: [Glyph]) -> String {
        glyphs.map { $0.text }.joined()
    }
}