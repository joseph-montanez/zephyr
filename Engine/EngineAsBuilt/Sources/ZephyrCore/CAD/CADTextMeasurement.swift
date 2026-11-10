import Foundation

// =========================================================================
// MARK: - CADTextBoundsContext
//
// Document-level context that lets text bounding boxes use the same SHX
// metrics the renderers draw with. All members default to empty, in which
// case measurement degrades gracefully to the legacy character-count
// estimate (see `CADEntity.estimateTextLocalBounds`).
// =========================================================================

/// Carries the style tables and per-primitive xdata needed to resolve the
/// effective SHX face, height, width factor, and oblique angle for a text
/// primitive — the same inputs `CADRendererBridge` and `CADDocument`
/// render bounds use.
public struct CADTextBoundsContext: Sendable {
    /// STYLE name -> font file (e.g. "R80-50" -> "ROMANS.shx").
    public var textStyleFonts: [String: String] = [:]
    /// STYLE name -> text style (width factor, oblique, fixed height).
    public var textStyles: [String: CADTextStyle] = [:]
    /// Block-primitive index -> that primitive's xdata
    /// (`dxf.textWidthScale`, `dxf.textWidthScaleOverride`, `dxf.textOblique`,
    /// `dxf.textObliqueOverride`, `dxf.textHeightOverride`,
    /// `dxf.textEntityType`, `dxf.textFitWidth`).
    public var xdataByIndex: [Int: [String: XDataValue]] = [:]
    /// xdata used when no per-index entry exists (loose-geometry entities
    /// carry their text keys on the entity itself).
    public var defaultXData: [String: XDataValue] = [:]

    public init(
        textStyleFonts: [String: String] = [:],
        textStyles: [String: CADTextStyle] = [:],
        xdataByIndex: [Int: [String: XDataValue]] = [:],
        defaultXData: [String: XDataValue] = [:]
    ) {
        self.textStyleFonts = textStyleFonts
        self.textStyles = textStyles
        self.xdataByIndex = xdataByIndex
        self.defaultXData = defaultXData
    }
}

// =========================================================================
// MARK: - CADTextMeasurement
//
// Single home for SHX text measurement shared by bounding boxes,
// hit-testing, selection, and background masks. Precedence mirrors the
// renderers exactly:
// - absent group 41/51 default to 1.0/0 (DXF spec), never the style value;
//   an explicit `dxf.textWidthScaleOverride` / `dxf.textObliqueOverride`
//   flag of 1 makes the entity value authoritative (the importer always
//   writes 1 for non-MTEXT, so entity values win there too);
// - otherwise the text style's width factor / oblique apply;
// - MTEXT ignores the width-scale slot (its group 41 is the reference
//   rectangle width, carried separately as `mtextWidth`).
// =========================================================================

public enum CADTextMeasurement: Sendable {

    /// Effective (widthFactor, obliqueAngle) for a text primitive from its
    /// xdata and resolved style. MTEXT always uses the style values.
    public static func effectiveFactors(
        xdata: [String: XDataValue],
        isMText: Bool,
        textStyle: CADTextStyle
    ) -> (widthFactor: Double, obliqueAngle: Double) {
        if isMText {
            return (textStyle.widthFactor, textStyle.obliqueAngle)
        }
        let entityWidth: Double
        if let value = xdata["dxf.textWidthScale"],
           case .double(let v) = value, v > 0 {
            entityWidth = v
        } else {
            entityWidth = 1.0
        }
        let widthOverride: Bool
        if let value = xdata["dxf.textWidthScaleOverride"],
           case .int(let flag) = value {
            widthOverride = flag != 0
        } else {
            widthOverride = abs(entityWidth - 1.0) > 1e-12
        }
        let entityOblique: Double
        if let value = xdata["dxf.textOblique"],
           case .double(let angle) = value {
            entityOblique = angle
        } else {
            entityOblique = 0
        }
        let obliqueOverride: Bool
        if let value = xdata["dxf.textObliqueOverride"],
           case .int(let flag) = value {
            obliqueOverride = flag != 0
        } else {
            obliqueOverride = abs(entityOblique) > 1e-12
        }
        return (
            widthOverride ? entityWidth : textStyle.widthFactor,
            obliqueOverride ? entityOblique : textStyle.obliqueAngle)
    }

    /// Effective cap height: the entity height wins when the height-override
    /// flag is set (explicit group 40) or the style has no fixed height.
    public static func effectiveHeight(
        baseHeight: Double,
        xdata: [String: XDataValue],
        textStyle: CADTextStyle
    ) -> Double {
        let heightOverride: Bool
        if let value = xdata["dxf.textHeightOverride"],
           case .int(let flag) = value {
            heightOverride = flag != 0
        } else {
            heightOverride = xdata["dxf.textEntityType"] != nil
        }
        if heightOverride || textStyle.fixedHeight <= 0 {
            return baseHeight
        }
        return textStyle.fixedHeight
    }

    public static func isMText(
        xdata: [String: XDataValue],
        mtextWidth: Double?
    ) -> Bool {
        if let value = xdata["dxf.textEntityType"],
           case .string(let entityType) = value {
            return entityType.uppercased() == "MTEXT"
        }
        return mtextWidth != nil
    }

    /// SHX ink bounds for a text primitive in its own local frame, or nil
    /// when the style does not resolve to a loadable SHX face (TTF/sprite
    /// text) or the string draws nothing. Blank-but-nonempty text falls
    /// back to the advance width so spaces still select.
    public static func measuredBounds(
        text: String,
        style: String?,
        height: Double,
        alignH: Int,
        alignV: Int,
        mtextWidth: Double?,
        context: CADTextBoundsContext?,
        primitiveIndex: Int? = nil
    ) -> (minX: Double, maxX: Double, minY: Double, maxY: Double)? {
        guard let style, !style.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              height.isFinite, height > 0, !text.isEmpty else { return nil }
        let map = context?.textStyleFonts ?? [:]
        let fontFile = CADFontManager.resolveTextStyleFont(
            styleName: style, textStyleFonts: map)
        guard let font = CADFontManager.getOrLoadSHXFont(
            filename: fontFile, allowFallback: false) else { return nil }
        let xdata: [String: XDataValue]
        if let context, let index = primitiveIndex,
           let indexed = context.xdataByIndex[index] {
            xdata = indexed
        } else {
            xdata = context?.defaultXData ?? [:]
        }
        let textStyle = CADTextStyle.resolve(style, in: context?.textStyles ?? [:])
        let mtext = isMText(xdata: xdata, mtextWidth: mtextWidth)
        let effHeight = effectiveHeight(
            baseHeight: height, xdata: xdata, textStyle: textStyle)
        guard effHeight.isFinite, effHeight > 0 else { return nil }
        let factors = effectiveFactors(xdata: xdata, isMText: mtext, textStyle: textStyle)
        let fitWidth: Double?
        if !mtext,
           let value = xdata["dxf.textFitWidth"],
           case .double(let span) = value, span > 0 {
            fitWidth = span
        } else {
            fitWidth = nil
        }
        if let ink = font.measuredLocalBounds(
            text,
            height: effHeight,
            widthFactor: factors.widthFactor,
            obliqueAngle: factors.obliqueAngle,
            alignH: alignH,
            alignV: alignV,
            maxWidth: mtext ? mtextWidth : nil,
            fitWidth: fitWidth) {
            return ink
        }
        // Blank text draws no ink but still occupies the advance width
        // (or the fitted span for Fit/Aligned text).
        let advance = font.measuredAdvanceWidth(
            text, height: effHeight, widthFactor: factors.widthFactor)
        guard advance.isFinite, advance > 0 else { return nil }
        return advanceFallbackBox(
            advance: advance, height: effHeight,
            alignH: alignH, alignV: alignV,
            mtextWidth: mtext ? mtextWidth : fitWidth)
    }

    /// Direct variant for callers that already resolved every metric (the
    /// render bridges pass the exact arguments they render with, so the
    /// box matches the ink by construction).
    public static func measuredBoundsDirect(
        text: String,
        font: SHXShapeFont,
        height: Double,
        widthFactor: Double,
        obliqueAngle: Double,
        alignH: Int,
        alignV: Int,
        maxWidth: Double?,
        fitWidth: Double? = nil
    ) -> (minX: Double, maxX: Double, minY: Double, maxY: Double)? {
        guard !text.isEmpty, height.isFinite, height > 0 else { return nil }
        if let ink = font.measuredLocalBounds(
            text,
            height: height,
            widthFactor: widthFactor,
            obliqueAngle: obliqueAngle,
            alignH: alignH,
            alignV: alignV,
            maxWidth: maxWidth,
            fitWidth: fitWidth) {
            return ink
        }
        let advance = font.measuredAdvanceWidth(
            text, height: height, widthFactor: widthFactor)
        guard advance.isFinite, advance > 0 else { return nil }
        return advanceFallbackBox(
            advance: advance, height: height,
            alignH: alignH, alignV: alignV, mtextWidth: maxWidth)
    }

    private static func advanceFallbackBox(
        advance: Double,
        height: Double,
        alignH: Int,
        alignV: Int,
        mtextWidth: Double?
    ) -> (minX: Double, maxX: Double, minY: Double, maxY: Double) {
        let width = mtextWidth ?? advance
        let minX: Double
        let maxX: Double
        switch alignH {
        case 1, 4:
            minX = -0.5 * width
            maxX = 0.5 * width
        case 2:
            minX = -width
            maxX = 0
        default:
            minX = 0
            maxX = width
        }
        let (minY, maxY): (Double, Double)
        switch alignV {
        case 1:
            minY = 0.2 * height
            maxY = height + 0.2 * height
        case 2:
            minY = -0.5 * height
            maxY = 0.5 * height
        case 3:
            minY = -height
            maxY = 0
        default:
            minY = -height
            maxY = 0
        }
        return (minX, maxX, minY, maxY)
    }
}
