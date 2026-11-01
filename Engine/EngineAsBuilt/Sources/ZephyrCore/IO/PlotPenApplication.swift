import Foundation

// =========================================================================
// MARK: - PlotPenApplication
//
// Phase 3 step 19: shared CTB/STB pen application for
// (a) the canvas when `ShowPlotStyles` (DXF 70 bit 2) is set, and
// (b) `PDFExporter` when `PlotPlotStyles` (bit 32) is set.
//
// Canvas hook point (not wired in this pass): `CADRendererBridge`
// `computeSpecs` resolves `entityColor` per entity — apply
// `resolve(objectACI:objectRGB:pen:…)` there when the active layout has
// ShowPlotStyles, honoring `PSTYLEMODE` for CTB-vs-STB pen lookup.
// =========================================================================

public enum PlotPenApplication {
    /// Resolved pen for one object.
    public struct ResolvedPen: Sendable, Equatable {
        public var r: UInt8
        public var g: UInt8
        public var b: UInt8
        /// Ink coverage 0–1 from `screen` (screening percent / 100).
        public var screening01: Double
        /// Final lineweight in mm (nil = use object lineweight).
        public var lineweightMM: Double?

        public init(r: UInt8, g: UInt8, b: UInt8,
                    screening01: Double = 1, lineweightMM: Double? = nil) {
            self.r = r; self.g = g; self.b = b
            self.screening01 = screening01
            self.lineweightMM = lineweightMM
        }
    }

    /// ARGB int32 → RGB (alpha is carried separately via screening).
    public static func argbToRGB(_ argb: UInt32) -> (UInt8, UInt8, UInt8) {
        (UInt8((argb >> 16) & 0xFF), UInt8((argb >> 8) & 0xFF), UInt8(argb & 0xFF))
    }

    /// Luminance grayscale (Rec. 601 luma).
    public static func grayscale(r: UInt8, g: UInt8, b: UInt8) -> (UInt8, UInt8, UInt8) {
        let y = UInt8(min(max((0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b)).rounded(), 0), 255))
        return (y, y, y)
    }

    /// Resolve one object's plotted pen.
    /// - objectACI: ACI 1–255 when known (preferred CTB key).
    /// - objectRGB: fallback RGB (nearest ACI via caller's palette when needed).
    /// - pen: style pen for the ACI/name, or nil (no table assigned).
    /// - objectLineweightMM: entity/layer lineweight.
    /// - scaleLineweights/plotScale: DXF 70 bit 64 scaling.
    public static func resolve(
        objectACI: Int?,
        objectRGB: (UInt8, UInt8, UInt8),
        pen: PlotStylePen?,
        objectLineweightMM: Double,
        scaleLineweights: Bool = false,
        plotScale: Double = 1
    ) -> ResolvedPen {
        guard let pen else {
            return ResolvedPen(r: objectRGB.0, g: objectRGB.1, b: objectRGB.2)
        }
        let rgb: (UInt8, UInt8, UInt8)
        switch pen.colorPolicy {
        case 5, 0:
            if let argb = pen.colorARGB {
                rgb = argbToRGB(argb)
            } else {
                rgb = objectRGB
            }
        case 3:
            rgb = grayscale(r: objectRGB.0, g: objectRGB.1, b: objectRGB.2)
        default:
            rgb = objectRGB // policy 1 (and unknown): object color
        }
        var lw = pen.lineweightMM ?? objectLineweightMM
        if scaleLineweights, plotScale.isFinite, plotScale > 0 {
            lw *= plotScale
        }
        return ResolvedPen(
            r: rgb.0, g: rgb.1, b: rgb.2,
            screening01: Double(pen.screeningPercent) / 100.0,
            lineweightMM: lw)
    }
}
