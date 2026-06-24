import Foundation

// =========================================================================
// MARK: - CADShapeFont
//
// Protocol and registry for shape-based fonts (SHX). Provides the interface
// for measuring text and generating line-segment geometry from AutoCAD
// shape font files, decoupled from the specific SHX parsing implementation.

// =========================================================================
// MARK: - CADShapeFont
// =========================================================================

/// Explodes SHX shape-font text strings into line-segment primitives for PDF export.
///
/// When a CAD text entity uses an SHX font, the PDF exporter cannot use `BT`/`Tj`
/// text operators — the font must be rendered as stroked vector geometry. This
/// utility wraps `CADFontManager.getOrLoadSHXFont` and `SHXShapeFont.renderText`
/// to produce `CADPrimitive` line segments from a text string.
public enum CADShapeFont {

    /// Convert a text string with an SHX style into line primitives in world space.
    /// Returns an empty array if the font cannot be loaded or is not an SHX font.
    /// - Parameters:
    ///   - text: The text string to render.
    ///   - position: Insertion point in world coordinates.
    ///   - height: Cap height in world units.
    ///   - rotation: Text rotation in radians.
    ///   - fontName: SHX font filename (e.g., "simplex.shx", "romans.shx").
    ///   - alignH: Horizontal alignment (0=left, 1=center, 2=right).
    ///   - alignV: Vertical alignment (0=baseline, 1=bottom, 2=middle, 3=top).
    ///   - mtextWidth: Optional max width for MTEXT wrapping.
    /// - Returns: Array of line primitives ready for PDF path emission.
    public static func explode(
        text: String,
        position: Vector3,
        height: Double,
        rotation: Double = 0,
        fontName: String,
        alignH: Int = 0,
        alignV: Int = 0,
        mtextWidth: Double? = nil
    ) -> [CADPrimitive] {
        guard !text.isEmpty,
              let shxFont = CADFontManager.getOrLoadSHXFont(filename: fontName)
        else { return [] }

        return shxFont.renderText(
            text,
            origin: position,
            height: height,
            rotation: rotation,
            alignH: alignH,
            alignV: alignV,
            maxWidth: mtextWidth
        )
    }

    /// Check whether a font style name refers to an SHX shape font (not TTF/OTF).
    /// Used by PDFExporter to decide between `BT`/`Tj` text operators and shape
    /// font explosion.
    public static func isSHXFont(_ fontName: String) -> Bool {
        let name = fontName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasSuffix(".ttf") || name.hasSuffix(".otf") || name.hasSuffix(".ttc") {
            return false
        }
        // If we can load it as SHX, it's an SHX font.
        return CADFontManager.getOrLoadSHXFont(filename: fontName) != nil
    }
}
