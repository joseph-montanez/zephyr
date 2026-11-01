import Foundation

// =========================================================================
// MARK: - PlotSettingsValidator
//
// Pure, UI-free validation service (Phase 2). Both the Page Setup dialog
// and the `-PLOT`/`-PAGESETUP` CLI state machines consume these functions;
// all dialog enable/disable and auto-calculation rules (§2 rules 1–6) are
// unit-tested here without ImGui.
//
// Bit meanings (DXF 70): 4 = PlotCentered, 16 = UseStandardScale,
// 32 = PlotPlotStyles, 128 = PrintLineweights.
// Plot types (DXF 74): 0 Display, 1 Extents, 2 Limits, 3 View, 4 Window,
// 5 Layout. Shade levels (DXF 77): 0 Draft, 1 Preview, 2 Normal,
// 3 Presentation, 4 Maximum, 5 Custom.
// =========================================================================

public enum PlotSettingsValidator {

    // MARK: - Device change (rule 1)

    public struct DeviceChangeResult {
        public var settings: CADPlotSettings
        /// Non-nil when PAPERUPDATE=0 and the old media was unsupported.
        public var warning: String?
    }

    /// Reload the media list for a new device. Unknown device names are
    /// preserved as-is (missing-plotter behavior); media stays untouched.
    public static func applyDeviceChange(
        settings: CADPlotSettings,
        newDeviceName: String,
        paperUpdate: Int = 0
    ) -> DeviceChangeResult {
        var next = settings
        next.plotConfigName = newDeviceName
        guard let device = PlotDeviceCatalog.device(named: newDeviceName) else {
            return DeviceChangeResult(settings: next, warning: nil)
        }
        if device.medium(canonicalName: next.canonicalMediaName) != nil {
            return DeviceChangeResult(settings: next, warning: nil)
        }
        let fallback = device.defaultMedium ?? device.media.first
        guard let fallback else {
            return DeviceChangeResult(settings: next, warning: nil)
        }
        next = applyPaperSize(settings: next, media: fallback)
        if paperUpdate == 1 {
            return DeviceChangeResult(settings: next, warning: nil)
        }
        let warning = "Paper size '\(settings.canonicalMediaName)' is not supported by " +
            "'\(newDeviceName)'; using '\(fallback.canonicalName)' instead."
        return DeviceChangeResult(settings: next, warning: warning)
    }

    // MARK: - Paper change (rule 2)

    /// Apply a media entry: canonical name, physical dims, margins, and
    /// auto-match of plot-paper units (72) to the media's native units.
    public static func applyPaperSize(settings: CADPlotSettings, media: PlotPaperSize) -> CADPlotSettings {
        var next = settings
        next.canonicalMediaName = media.canonicalName
        next.paperName = media.canonicalName
        next.paperWidthMM = media.widthMM
        next.paperHeightMM = media.heightMM
        next.marginLM = media.marginLM
        next.marginBM = media.marginBM
        next.marginRM = media.marginRM
        next.marginTM = media.marginTM
        next.plotPaperUnits = media.paperUnits
        return next
    }

    // MARK: - Plot-type state rules (rule 3)

    /// Layout mode plots the printable area 1:1; Fit and Center are forced off.
    public static func isFitEnabled(plotType: Int) -> Bool { plotType != 5 }
    public static func isCenterEnabled(plotType: Int) -> Bool { plotType != 5 }
    public static func isOffsetEditable(plotType: Int, centered: Bool) -> Bool {
        plotType != 5 && !centered
    }

    /// Enforce Layout-mode invariants: clear Fit (75=0 → keep type but clear
    /// bit 16? AutoCAD forces unchecked) and Centered bit.
    public static func enforcePlotTypeRules(settings: CADPlotSettings) -> CADPlotSettings {
        guard settings.plotType == 5 else { return settings }
        var next = settings
        next.plotFlags &= ~4 // Center the plot off
        if next.standardScaleType == 0 {
            // Scaled-to-Fit is meaningless for Layout; fall back to 1:1 standard.
            next.standardScaleType = 16
            next.useStandardScale = true
        }
        return next
    }

    // MARK: - Centering math (rule 4)

    /// Offset_X = (W_printable − W_plotArea × S)/2 (same for Y).
    /// With PLOTOFFSET=1 (origin at paper edge) add left/bottom margins.
    /// S = paperUnits/drawingUnits effective scale.
    public static func centeredOffset(
        printableWidth: Double, printableHeight: Double,
        plotAreaWidth: Double, plotAreaHeight: Double,
        scale: Double,
        plotOffset: Int = 0,
        marginLeft: Double = 0, marginBottom: Double = 0
    ) -> (x: Double, y: Double) {
        let s = scale.isFinite ? scale : 1
        var x = (printableWidth - plotAreaWidth * s) / 2
        var y = (printableHeight - plotAreaHeight * s) / 2
        if plotOffset == 1 {
            x += marginLeft
            y += marginBottom
        }
        return (x, y)
    }

    /// Non-standard scale filling the printable bounds.
    public static func fitScale(
        printableWidth: Double, printableHeight: Double,
        plotAreaWidth: Double, plotAreaHeight: Double
    ) -> Double {
        guard plotAreaWidth > 0, plotAreaHeight > 0,
              printableWidth.isFinite, printableHeight.isFinite else { return 1 }
        return min(printableWidth / plotAreaWidth, printableHeight / plotAreaHeight)
    }

    // MARK: - Plot-style coupling (rule 5)

    /// Checking Plot-with-plot-styles auto-checks Plot-object-lineweights.
    public static func applyingPlotStylesToggled(settings: CADPlotSettings, on: Bool) -> CADPlotSettings {
        var next = settings
        if on {
            next.plotFlags |= 32
            next.plotFlags |= 128
        } else {
            next.plotFlags &= ~32
        }
        return next
    }

    // MARK: - Shade DPI (rule 6)

    /// Effective DPI for a shade quality level against a device reference DPI.
    /// Draft = 0 (wireframe); Preview = min(ref/4, 150); Normal = min(ref/2, 300);
    /// Presentation = min(ref, 600); Maximum = ref; Custom = clamped field.
    public static func effectiveDPI(quality: Int, customDPI: Int, referenceDPI: Int) -> Int {
        switch quality {
        case 0: return 0
        case 1: return min(Int(Double(referenceDPI) / 4.0), 150)
        case 2: return min(Int(Double(referenceDPI) / 2.0), 300)
        case 3: return min(referenceDPI, 600)
        case 4: return referenceDPI
        default: return min(max(customDPI, 100), 32767)
        }
    }

    public static func isDPIEditable(quality: Int) -> Bool { quality == 5 }

    // MARK: - Scale labels

    public static func scaleLabel(for type: Int) -> String {
        switch type {
        case 0: return "Scaled to Fit"
        case 1: return "1/128\"=1'"
        case 2: return "1/64\"=1'"
        case 3: return "1/32\"=1'"
        case 4: return "1/16\"=1'"
        case 5: return "3/32\"=1'"
        case 6: return "1/8\"=1'"
        case 7: return "3/16\"=1'"
        case 8: return "1/4\"=1'"
        case 9: return "3/8\"=1'"
        case 10: return "1/2\"=1'"
        case 11: return "3/4\"=1'"
        case 12: return "1\"=1'"
        case 13: return "3\"=1'"
        case 14: return "6\"=1'"
        case 15: return "1'=1'"
        case 16: return "1:1"
        case 17: return "1:2"
        case 18: return "1:4"
        case 19: return "1:8"
        case 20: return "1:10"
        case 21: return "1:16"
        case 22: return "1:20"
        case 23: return "1:30"
        case 24: return "1:40"
        case 25: return "1:50"
        case 26: return "1:100"
        case 27: return "2:1"
        case 28: return "4:1"
        case 29: return "8:1"
        case 30: return "10:1"
        case 31: return "100:1"
        case 32: return "1000:1"
        default: return "Custom"
        }
    }
}
