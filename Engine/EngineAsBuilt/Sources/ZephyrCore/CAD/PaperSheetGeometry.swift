import Foundation

// =========================================================================
// MARK: - PaperSheetGeometry
//
// Pure paper-space sheet math implementing revised spec §4 verbatim:
// sheet size via 44/45 ÷ S_unit × 143/142 with portrait/landscape swap,
// 4-state unprintable-margin permutation, PLOTOFFSET origin, per-PlotType
// plot-area rects, and LIMMIN/LIMMAX sync values.
//
// All coordinates are paper-space units. The "paper frame" has the
// lower-left physical paper corner at (0,0) and the upper-right at
// (sheetWidth, sheetHeight). Consumers (GPU canvas overlay, Page Setup
// Partial Preview) share this helper so the two can never disagree.
// =========================================================================

/// Paper-space sheet geometry derived from one layout's plot settings.
public enum PaperSheetGeometry {

    /// S_unit divisor: 1.0 for mm (72=1), 25.4 for inches (72=0).
    public static func unitDivisor(for settings: CADPlotSettings) -> Double {
        settings.plotPaperUnits == 0 ? 25.4 : 1.0
    }

    /// Plot-scale multiplier 143/142 (denominator/numerator; 1.0 at 1:1).
    public static func plotScaleMultiplier(for settings: CADPlotSettings) -> Double {
        let num = settings.customScaleNumerator != 0 ? settings.customScaleNumerator : 1
        let den = settings.customScaleDenominator != 0 ? settings.customScaleDenominator : 1
        return den / num
    }

    /// Unrotated sheet size in paper-space units.
    /// W_unrotated = DXF44 / S_unit × (143/142).
    public static func unrotatedSheetSize(for settings: CADPlotSettings) -> (width: Double, height: Double) {
        let s = unitDivisor(for: settings)
        let k = plotScaleMultiplier(for: settings)
        return (settings.paperWidthMM / s * k, settings.paperHeightMM / s * k)
    }

    /// Physical unrotated sheet size in paper-space units (without plot-scale multiplier 143/142).
    public static func physicalUnrotatedSheetSize(for settings: CADPlotSettings) -> (width: Double, height: Double) {
        let s = unitDivisor(for: settings)
        return (settings.paperWidthMM / s, settings.paperHeightMM / s)
    }

    /// Rotated sheet size. Portrait (73=0/2): as-is; Landscape (73=1/3): swapped.
    public static func sheetSize(for settings: CADPlotSettings) -> (width: Double, height: Double) {
        let u = unrotatedSheetSize(for: settings)
        switch settings.plotRotation {
        case 1, 3: return (u.height, u.width)
        default: return u
        }
    }

    /// Physical rotated sheet size in paper-space units (without plot-scale multiplier 143/142).
    public static func physicalSheetSize(for settings: CADPlotSettings) -> (width: Double, height: Double) {
        let u = physicalUnrotatedSheetSize(for: settings)
        switch settings.plotRotation {
        case 1, 3: return (u.height, u.width)
        default: return u
        }
    }

    /// Unprintable margins [L, B, R, T] in scaled paper units, permuted by
    /// PlotRotation (stored unrotated in DXF 40–43, always millimeters).
    /// 73=0: (M_L,M_B,M_R,M_T); 73=1: (M_T,M_L,M_B,M_R);
    /// 73=2: (M_R,M_T,M_L,M_B); 73=3: (M_B,M_R,M_T,M_L).
    public static func permutedMargins(for settings: CADPlotSettings) -> (left: Double, bottom: Double, right: Double, top: Double) {
        let s = unitDivisor(for: settings)
        let k = plotScaleMultiplier(for: settings)
        let l = settings.marginLM / s * k
        let b = settings.marginBM / s * k
        let r = settings.marginRM / s * k
        let t = settings.marginTM / s * k
        switch settings.plotRotation {
        case 1: return (t, l, b, r) // 90° CCW
        case 2: return (r, t, l, b) // 180°
        case 3: return (b, r, t, l) // 90° CW
        default: return (l, b, r, t) // 0° portrait
        }
    }

    /// Physical unprintable margins [L, B, R, T] in paper units (without plot-scale multiplier 143/142).
    public static func physicalPermutedMargins(for settings: CADPlotSettings) -> (left: Double, bottom: Double, right: Double, top: Double) {
        let s = unitDivisor(for: settings)
        let l = settings.marginLM / s
        let b = settings.marginBM / s
        let r = settings.marginRM / s
        let t = settings.marginTM / s
        switch settings.plotRotation {
        case 1: return (t, l, b, r) // 90° CCW
        case 2: return (r, t, l, b) // 180°
        case 3: return (b, r, t, l) // 90° CW
        default: return (l, b, r, t) // 0° portrait
        }
    }

    /// Printable (dashed) rect in the paper frame.
    public static func printableRect(for settings: CADPlotSettings) -> (minX: Double, minY: Double, maxX: Double, maxY: Double) {
        let sheet = sheetSize(for: settings)
        let m = permutedMargins(for: settings)
        return (m.left, m.bottom, sheet.width - m.right, sheet.height - m.top)
    }

    /// Paper-space origin (0,0) expressed in the paper frame.
    /// PLOTOFFSET=0: lower-left printable corner offset by (-ox,-oy);
    /// PLOTOFFSET=1: lower-left physical paper edge offset by (-ox,-oy).
    /// Offsets convert from mm like margins.
    public static func paperSpaceOrigin(for settings: CADPlotSettings, plotOffset: Int = 0) -> (x: Double, y: Double) {
        let s = unitDivisor(for: settings)
        let k = plotScaleMultiplier(for: settings)
        let ox = settings.plotOriginXMM / s * k
        let oy = settings.plotOriginYMM / s * k
        if plotOffset == 1 {
            return (-ox, -oy)
        }
        let m = permutedMargins(for: settings)
        return (m.left - ox, m.bottom - oy)
    }

    /// LIMMIN/LIMMAX sync values: paper corners in scaled paper units
    /// relative to the plot origin (spec §4.3). Delegates to the model so
    /// the writer and the validator share one implementation.
    public static func syncedLimits(for settings: CADPlotSettings) -> (min: (x: Double, y: Double), max: (x: Double, y: Double)) {
        settings.syncedLimits
    }

    /// Sheet + printable rects in paper-space (entity) coordinates, for the
    /// canvas overlay. The paper frame is shifted by −origin so paper-space
    /// (0,0) lands on `paperSpaceOrigin`.
    public static func overlayRects(
        for settings: CADPlotSettings,
        plotOffset: Int = 0
    ) -> (paper: (minX: Double, minY: Double, maxX: Double, maxY: Double),
            printable: (minX: Double, minY: Double, maxX: Double, maxY: Double))? {
        let sheet = sheetSize(for: settings)
        guard sheet.width > 0, sheet.height > 0, sheet.width.isFinite, sheet.height.isFinite else { return nil }
        let printable = printableRect(for: settings)
        let origin = paperSpaceOrigin(for: settings, plotOffset: plotOffset)
        let paper = (-origin.x, -origin.y, sheet.width - origin.x, sheet.height - origin.y)
        let printShifted = (printable.minX - origin.x, printable.minY - origin.y,
                            printable.maxX - origin.x, printable.maxY - origin.y)
        return (paper: paper, printable: printShifted)
    }

    /// Effective plot-area rect in the paper frame, when statically known.
    /// Layout → printable rect; Window → stored window coords; Limits →
    /// synced paper corners; Display/Extents/View need live drawing data and
    /// return nil (the caller computes them from the viewport/model).
    public static func staticPlotAreaRect(for settings: CADPlotSettings) -> (minX: Double, minY: Double, maxX: Double, maxY: Double)? {
        switch settings.plotType {
        case 5: // Layout
            let p = printableRect(for: settings)
            return p
        case 4: // Window (stored Paper Space coordinates)
            return (settings.plotWindowMinX, settings.plotWindowMinY,
                    settings.plotWindowMaxX, settings.plotWindowMaxY)
        case 2: // Limits (paper corners)
            let l = syncedLimits(for: settings)
            return (l.min.x, l.min.y, l.max.x, l.max.y)
        default:
            return nil
        }
    }
}
