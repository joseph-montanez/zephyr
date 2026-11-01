import XCTest
@testable import ZephyrCore

/// Phase 2: `PlotDeviceCatalog` + `PlotSettingsValidator` tests (§2 rules 1–6).
final class PlotSettingsValidatorTests: XCTestCase {

    // MARK: - Catalog

    func testCanonicalDisplayNameRoundTrip() {
        let canonical = "ISO_full_bleed_A3_(420.00_x_297.00_MM)"
        let display = PlotDeviceCatalog.displayName(forCanonical: canonical)
        XCTAssertEqual(display, "ISO full bleed A3 (420.00 x 297.00 MM)")
        XCTAssertEqual(PlotDeviceCatalog.canonicalName(forDisplay: display), canonical)
    }

    func testBuiltinPDFDevice() {
        let pdf = try? XCTUnwrap(PlotDeviceCatalog.device(named: "DWG To PDF.pc3"))
        XCTAssertEqual(pdf?.isPDF, true)
        XCTAssertEqual(pdf?.referenceDPI, 200)
        XCTAssertFalse(pdf?.media.isEmpty ?? true)
        XCTAssertNotNil(pdf?.medium(canonicalName: "ISO_full_bleed_A3_(420.00_x_297.00_MM)"))
        XCTAssertEqual(pdf?.defaultMedium?.canonicalName, "ISO_A4_(297.00_x_210.00_MM)")
        // Case-insensitive + unknown passthrough.
        XCTAssertNotNil(PlotDeviceCatalog.device(named: "dwg to pdf.pc3"))
        XCTAssertNil(PlotDeviceCatalog.device(named: "HP DesignJet 800.pc3"))
        XCTAssertFalse(PlotDeviceCatalog.isKnownDevice("HP DesignJet 800.pc3"))
    }

    // MARK: - Rule 1: device change + PAPERUPDATE

    func testDeviceChangeWarnsOrSilentlySwitches() {
        var ps = CADPlotSettings(paperWidthMM: 297, paperHeightMM: 210,
                                 plotPaperUnits: 1,
                                 canonicalMediaName: "ISO_A4_(297.00_x_210.00_MM)")
        // A4 exists on the PDF device → no warning.
        let kept = PlotSettingsValidator.applyDeviceChange(
            settings: ps, newDeviceName: "DWG To PDF.pc3", paperUpdate: 0)
        XCTAssertNil(kept.warning)
        XCTAssertEqual(kept.settings.plotConfigName, "DWG To PDF.pc3")
        // Unknown media + PAPERUPDATE=0 → warning + default media.
        ps.canonicalMediaName = "Custom_Weird_Size"
        let warned = PlotSettingsValidator.applyDeviceChange(
            settings: ps, newDeviceName: "DWG To PDF.pc3", paperUpdate: 0)
        XCTAssertNotNil(warned.warning)
        XCTAssertEqual(warned.settings.canonicalMediaName, "ISO_A4_(297.00_x_210.00_MM)")
        // PAPERUPDATE=1 → silent.
        let silent = PlotSettingsValidator.applyDeviceChange(
            settings: ps, newDeviceName: "DWG To PDF.pc3", paperUpdate: 1)
        XCTAssertNil(silent.warning)
        // Unknown device name preserved, media untouched.
        let foreign = PlotSettingsValidator.applyDeviceChange(
            settings: ps, newDeviceName: "HP DesignJet 800.pc3", paperUpdate: 0)
        XCTAssertNil(foreign.warning)
        XCTAssertEqual(foreign.settings.plotConfigName, "HP DesignJet 800.pc3")
        XCTAssertEqual(foreign.settings.canonicalMediaName, "Custom_Weird_Size")
    }

    // MARK: - Rule 2: paper change auto-matches units + margins

    func testPaperChangeAutoMatchesUnits() {
        let ps = CADPlotSettings(plotPaperUnits: 1)
        let letter = try? XCTUnwrap(PlotDeviceCatalog.dwgToPDF.medium(
            canonicalName: "Letter_(8.50_x_11.00_Inches)"))
        let next = PlotSettingsValidator.applyPaperSize(settings: ps, media: letter!)
        XCTAssertEqual(next.plotPaperUnits, 0)
        XCTAssertEqual(next.paperWidthMM, 215.9, accuracy: 1e-9)
        XCTAssertEqual(next.marginLM, 6.35, accuracy: 1e-9)
    }

    // MARK: - Rule 3: Layout disables Fit/Center

    func testLayoutDisablesFitAndCenter() {
        XCTAssertFalse(PlotSettingsValidator.isFitEnabled(plotType: 5))
        XCTAssertFalse(PlotSettingsValidator.isCenterEnabled(plotType: 5))
        XCTAssertTrue(PlotSettingsValidator.isFitEnabled(plotType: 1))
        XCTAssertTrue(PlotSettingsValidator.isOffsetEditable(plotType: 1, centered: false))
        XCTAssertFalse(PlotSettingsValidator.isOffsetEditable(plotType: 1, centered: true))
        var ps = CADPlotSettings(plotFlags: 4, plotType: 5, standardScaleType: 0)
        let enforced = PlotSettingsValidator.enforcePlotTypeRules(settings: ps)
        XCTAssertEqual(enforced.plotFlags & 4, 0)
        XCTAssertEqual(enforced.standardScaleType, 16)
    }

    // MARK: - Rule 4: centering math (+ PLOTOFFSET)

    func testCenteredOffset() {
        // Screenshot case shape: printable 400x277, area 774.5x533.76 at 1:2.
        let off = PlotSettingsValidator.centeredOffset(
            printableWidth: 400, printableHeight: 277,
            plotAreaWidth: 774.5, plotAreaHeight: 533.76,
            scale: 0.5)
        XCTAssertEqual(off.x, (400 - 774.5 * 0.5) / 2, accuracy: 1e-9)
        XCTAssertEqual(off.y, (277 - 533.76 * 0.5) / 2, accuracy: 1e-9)
        // PLOTOFFSET=1 adds left/bottom margins.
        let edge = PlotSettingsValidator.centeredOffset(
            printableWidth: 400, printableHeight: 277,
            plotAreaWidth: 774.5, plotAreaHeight: 533.76,
            scale: 0.5, plotOffset: 1, marginLeft: 10, marginBottom: 10)
        XCTAssertEqual(edge.x, off.x + 10, accuracy: 1e-9)
        XCTAssertEqual(edge.y, off.y + 10, accuracy: 1e-9)
        // Fit scale fills printable bounds.
        XCTAssertEqual(PlotSettingsValidator.fitScale(
            printableWidth: 400, printableHeight: 277,
            plotAreaWidth: 800, plotAreaHeight: 277), 0.5, accuracy: 1e-9)
    }

    // MARK: - Rule 5: plot-style coupling

    func testPlotStyleToggleCouplesLineweights() {
        let ps = CADPlotSettings(plotFlags: 0)
        let on = PlotSettingsValidator.applyingPlotStylesToggled(settings: ps, on: true)
        XCTAssertNotEqual(on.plotFlags & 32, 0)
        XCTAssertNotEqual(on.plotFlags & 128, 0)
        let off = PlotSettingsValidator.applyingPlotStylesToggled(settings: on, on: false)
        XCTAssertEqual(off.plotFlags & 32, 0)
        XCTAssertNotEqual(off.plotFlags & 128, 0) // lineweights stay on
    }

    // MARK: - Rule 6: shade DPI

    func testShadeDPICaps() {
        XCTAssertEqual(PlotSettingsValidator.effectiveDPI(quality: 0, customDPI: 300, referenceDPI: 200), 0)
        XCTAssertEqual(PlotSettingsValidator.effectiveDPI(quality: 1, customDPI: 300, referenceDPI: 200), 50)
        // Reference screenshot: Normal on DWG To PDF (200 DPI base) shows 100.
        XCTAssertEqual(PlotSettingsValidator.effectiveDPI(quality: 2, customDPI: 300, referenceDPI: 200), 100)
        XCTAssertEqual(PlotSettingsValidator.effectiveDPI(quality: 3, customDPI: 300, referenceDPI: 200), 200)
        XCTAssertEqual(PlotSettingsValidator.effectiveDPI(quality: 4, customDPI: 300, referenceDPI: 1200), 1200)
        XCTAssertEqual(PlotSettingsValidator.effectiveDPI(quality: 5, customDPI: 450, referenceDPI: 200), 450)
        XCTAssertEqual(PlotSettingsValidator.effectiveDPI(quality: 5, customDPI: 50, referenceDPI: 200), 100)
        XCTAssertFalse(PlotSettingsValidator.isDPIEditable(quality: 2))
        XCTAssertTrue(PlotSettingsValidator.isDPIEditable(quality: 5))
    }
}

/// Phase 2 catalog coverage (dropdown contents, defaults, raster devices).
final class PlotDeviceCatalogTests: XCTestCase {
    func testBuiltinDevicesAndDefaults() {
        XCTAssertEqual(PlotDeviceCatalog.builtins.count, 4)
        XCTAssertEqual(PlotDeviceCatalog.noneDevice.media.count, 0)
        XCTAssertNotNil(PlotDeviceCatalog.publishJPG.defaultMedium)
        XCTAssertNotNil(PlotDeviceCatalog.publishPNG.defaultMedium)
        // Full-bleed media carry zero margins.
        let fb = PlotDeviceCatalog.dwgToPDF.medium(
            canonicalName: "ISO_full_bleed_A3_(420.00_x_297.00_MM)")
        XCTAssertEqual(fb?.marginLM ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(fb?.widthMM ?? -1, 420, accuracy: 1e-9)
    }
}
