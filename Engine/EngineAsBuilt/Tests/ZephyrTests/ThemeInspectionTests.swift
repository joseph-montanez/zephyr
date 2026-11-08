import XCTest
import ImGui
@testable import ZephyrCore

@MainActor
final class ThemeInspectionTests: XCTestCase {

    func testThemeApplicationAndContrast() {
        let ctx = ImGuiCreateContext(nil)!
        defer { ImGuiDestroyContext(ctx) }
        let ui = EngineUIManager()
        let io = ImGuiGetIO()!
        io.pointee.DisplaySize = ImVec2(x: 1920, y: 1080)
        io.pointee.DeltaTime = 1.0 / 60.0
        _ = ImFontAtlas_AddFontDefault(io.pointee.Fonts, nil)
        igImFontAtlasBuildMain(io.pointee.Fonts)

        func luminance(_ col: ImVec4) -> Double {
            return 0.2126 * Double(col.x) + 0.7152 * Double(col.y) + 0.0722 * Double(col.z)
        }
        func contrastRatio(_ c1: ImVec4, _ c2: ImVec4) -> Double {
            let l1 = luminance(c1)
            let l2 = luminance(c2)
            let top = max(l1, l2) + 0.05
            let bottom = min(l1, l2) + 0.05
            return top / bottom
        }

        // 1. Dark theme verification
        ui.isDarkTheme = true
        ui.applyTheme()
        XCTAssertTrue(ui.isDarkTheme)
        XCTAssertEqual(ui.theme.panelBg.x, AppTheme.dark.panelBg.x, accuracy: 0.001)
        XCTAssertEqual(ui.theme.panelBg.y, AppTheme.dark.panelBg.y, accuracy: 0.001)
        XCTAssertEqual(ui.theme.panelBg.z, AppTheme.dark.panelBg.z, accuracy: 0.001)

        ImGuiNewFrame()
        let darkWinBg = ImGuiGetStyleColorVec4(Int32(ImGuiCol_WindowBg.rawValue))!.pointee
        let darkText = ImGuiGetStyleColorVec4(Int32(ImGuiCol_Text.rawValue))!.pointee
        let darkSliderGrab = ImGuiGetStyleColorVec4(Int32(ImGuiCol_SliderGrab.rawValue))!.pointee
        let darkCheckMark = ImGuiGetStyleColorVec4(Int32(ImGuiCol_CheckMark.rawValue))!.pointee
        let darkFrameBg = ImGuiGetStyleColorVec4(Int32(ImGuiCol_FrameBg.rawValue))!.pointee
        let darkButton = ImGuiGetStyleColorVec4(Int32(ImGuiCol_Button.rawValue))!.pointee
        let darkTextDisabled = ImGuiGetStyleColorVec4(Int32(ImGuiCol_TextDisabled.rawValue))!.pointee

        XCTAssertEqual(darkWinBg.x, AppTheme.dark.panelBg.x, accuracy: 0.001)
        XCTAssertEqual(darkText.x, AppTheme.dark.textPrimary.x, accuracy: 0.001)
        XCTAssertEqual(darkSliderGrab.x, AppTheme.dark.brandGold.x, accuracy: 0.001)
        XCTAssertEqual(darkCheckMark.x, AppTheme.dark.brandGold.x, accuracy: 0.001)
        XCTAssertEqual(darkTextDisabled.x, AppTheme.dark.textDim.x, accuracy: 0.001)

        // Dark theme frame and button should be subtle dark values
        XCTAssertLessThan(darkFrameBg.x, 0.3)
        XCTAssertEqual(darkButton.x, AppTheme.dark.border.x, accuracy: 0.001)

        ImGuiRender()

        // 2. Light theme verification via property didSet
        ui.isDarkTheme = false
        XCTAssertFalse(ui.isDarkTheme)
        XCTAssertEqual(ui.theme.panelBg.x, AppTheme.light.panelBg.x, accuracy: 0.001)
        XCTAssertEqual(ui.theme.panelBg.y, AppTheme.light.panelBg.y, accuracy: 0.001)
        XCTAssertEqual(ui.theme.panelBg.z, AppTheme.light.panelBg.z, accuracy: 0.001)

        ImGuiNewFrame()
        let lightWinBg = ImGuiGetStyleColorVec4(Int32(ImGuiCol_WindowBg.rawValue))!.pointee
        let lightText = ImGuiGetStyleColorVec4(Int32(ImGuiCol_Text.rawValue))!.pointee
        let lightSliderGrab = ImGuiGetStyleColorVec4(Int32(ImGuiCol_SliderGrab.rawValue))!.pointee
        let lightCheckMark = ImGuiGetStyleColorVec4(Int32(ImGuiCol_CheckMark.rawValue))!.pointee
        let lightFrameBg = ImGuiGetStyleColorVec4(Int32(ImGuiCol_FrameBg.rawValue))!.pointee
        let lightButton = ImGuiGetStyleColorVec4(Int32(ImGuiCol_Button.rawValue))!.pointee
        let lightTextDisabled = ImGuiGetStyleColorVec4(Int32(ImGuiCol_TextDisabled.rawValue))!.pointee

        // Light panel background should be pale/white (~0.97), text should be dark navy (~0.086)
        XCTAssertGreaterThan(lightWinBg.x, 0.9)
        XCTAssertGreaterThan(lightWinBg.y, 0.9)
        XCTAssertGreaterThan(lightWinBg.z, 0.9)

        XCTAssertLessThan(lightText.x, 0.2)
        XCTAssertLessThan(lightText.y, 0.3)
        XCTAssertLessThan(lightText.z, 0.4)

        // Light frame and button should be soft pale tones (not dark or hardcoded dark navy)
        XCTAssertGreaterThan(lightFrameBg.x, 0.8)
        XCTAssertGreaterThan(lightButton.x, 0.8)

        XCTAssertEqual(lightSliderGrab.x, AppTheme.light.brandGold.x, accuracy: 0.001)
        XCTAssertEqual(lightCheckMark.x, AppTheme.light.brandGold.x, accuracy: 0.001)
        XCTAssertEqual(lightTextDisabled.x, AppTheme.light.textDim.x, accuracy: 0.001)

        // 3. Contrast verification: ensure text is readable against panel and button backgrounds
        let darkTextWinContrast = contrastRatio(darkText, darkWinBg)
        let lightTextWinContrast = contrastRatio(lightText, lightWinBg)
        let lightTextBtnContrast = contrastRatio(lightText, lightButton)

        XCTAssertGreaterThan(darkTextWinContrast, 3.0, "Dark theme must provide high contrast between text and panelBg")
        XCTAssertGreaterThan(lightTextWinContrast, 3.0, "Light theme must provide high contrast between text and panelBg")
        XCTAssertGreaterThan(lightTextBtnContrast, 3.0, "Light theme must provide high contrast between text and button background")

        // 4. Verify unselected segment button contrast in light mode
        let unselectedBtnBgLight = ImVec4(x: 0.88, y: 0.92, z: 0.96, w: 1.0)
        let unselectedTextLight = AppTheme.light.textPrimary
        let segmentBtnContrast = contrastRatio(unselectedTextLight, unselectedBtnBgLight)
        XCTAssertGreaterThan(segmentBtnContrast, 4.0, "Unselected segment button in light mode must be easily legible")

        ImGuiRender()

        // 5. toggleTheme() toggles between dark and light seamlessly
        ui.toggleTheme()
        XCTAssertTrue(ui.isDarkTheme)
        ui.toggleTheme()
        XCTAssertFalse(ui.isDarkTheme)
    }

    func testCatppuccinThemes() {
        let ctx = ImGuiCreateContext(nil)!
        defer { ImGuiDestroyContext(ctx) }
        let ui = EngineUIManager()
        let io = ImGuiGetIO()!
        io.pointee.DisplaySize = ImVec2(x: 1920, y: 1080)
        io.pointee.DeltaTime = 1.0 / 60.0
        _ = ImFontAtlas_AddFontDefault(io.pointee.Fonts, nil)
        igImFontAtlasBuildMain(io.pointee.Fonts)

        // 1. Verify all presets are registered
        XCTAssertEqual(AppTheme.allPresets.count, 8)
        let presetIDs = AppTheme.allPresets.map(\.id)
        XCTAssertTrue(presetIDs.contains("dark"))
        XCTAssertTrue(presetIDs.contains("light"))
        XCTAssertTrue(presetIDs.contains("catppuccin-latte"))
        XCTAssertTrue(presetIDs.contains("catppuccin-frappe"))
        XCTAssertTrue(presetIDs.contains("catppuccin-macchiato"))
        XCTAssertTrue(presetIDs.contains("catppuccin-mocha"))
        XCTAssertTrue(presetIDs.contains("cotton-candy"))
        XCTAssertTrue(presetIDs.contains("galactic-purple"))

        // 2. Verify name resolution & aliases
        XCTAssertEqual(AppTheme.theme(named: "latte")?.id, "catppuccin-latte")
        XCTAssertEqual(AppTheme.theme(named: "Catppuccin Latte")?.id, "catppuccin-latte")
        XCTAssertEqual(AppTheme.theme(named: "catppuccin-latte")?.id, "catppuccin-latte")

        XCTAssertEqual(AppTheme.theme(named: "frappe")?.id, "catppuccin-frappe")
        XCTAssertEqual(AppTheme.theme(named: "Frappe")?.id, "catppuccin-frappe")
        XCTAssertEqual(AppTheme.theme(named: "FRAPPE")?.id, "catppuccin-frappe")
        XCTAssertEqual(AppTheme.theme(named: "Frappé")?.id, "catppuccin-frappe")
        XCTAssertEqual(AppTheme.theme(named: "catppuccin-frappe")?.id, "catppuccin-frappe")

        XCTAssertEqual(AppTheme.theme(named: "macchiato")?.id, "catppuccin-macchiato")
        XCTAssertEqual(AppTheme.theme(named: "Catppuccin Macchiato")?.id, "catppuccin-macchiato")

        XCTAssertEqual(AppTheme.theme(named: "mocha")?.id, "catppuccin-mocha")
        XCTAssertEqual(AppTheme.theme(named: "Catppuccin Mocha")?.id, "catppuccin-mocha")
        XCTAssertEqual(AppTheme.theme(named: "candy")?.id, "cotton-candy")
        XCTAssertEqual(AppTheme.theme(named: "Cotton Candy")?.id, "cotton-candy")
        XCTAssertEqual(AppTheme.theme(named: "barbie")?.id, "cotton-candy")
        XCTAssertEqual(AppTheme.theme(named: "BARBIE")?.id, "cotton-candy")
        XCTAssertEqual(AppTheme.theme(named: "rainbow")?.id, "cotton-candy")

        XCTAssertEqual(AppTheme.theme(named: "galaxy")?.id, "galactic-purple")
        XCTAssertEqual(AppTheme.theme(named: "Galactic Purple")?.id, "galactic-purple")
        XCTAssertEqual(AppTheme.theme(named: "GALACTIC")?.id, "galactic-purple")
        XCTAssertEqual(ThemeCommand.resolve("GALAXY"), .named("GALAXY"))

        // 3. Test applying Catppuccin Mocha
        XCTAssertTrue(ui.setTheme(named: "mocha"))
        XCTAssertEqual(ui.theme.id, "catppuccin-mocha")
        XCTAssertTrue(ui.isDarkTheme)
        XCTAssertEqual(ui.theme.panelBg.x, AppTheme.catppuccinMocha.panelBg.x, accuracy: 0.001)

        ImGuiNewFrame()
        let mochaWinBg = ImGuiGetStyleColorVec4(Int32(ImGuiCol_WindowBg.rawValue))!.pointee
        let mochaText = ImGuiGetStyleColorVec4(Int32(ImGuiCol_Text.rawValue))!.pointee
        XCTAssertEqual(mochaWinBg.x, AppTheme.catppuccinMocha.panelBg.x, accuracy: 0.001)
        XCTAssertEqual(mochaText.x, AppTheme.catppuccinMocha.textPrimary.x, accuracy: 0.001)
        ImGuiRender()

        // 4. Test applying Catppuccin Latte (light flavor)
        XCTAssertTrue(ui.setTheme(named: "latte"))
        XCTAssertEqual(ui.theme.id, "catppuccin-latte")
        XCTAssertFalse(ui.isDarkTheme)
        XCTAssertEqual(ui.theme.panelBg.x, AppTheme.catppuccinLatte.panelBg.x, accuracy: 0.001)

        // 5. Test cycling through themes
        ui.setTheme(AppTheme.dark)
        XCTAssertEqual(ui.theme.id, "dark")
        ui.cycleTheme()
        XCTAssertEqual(ui.theme.id, "light")
        ui.cycleTheme()
        XCTAssertEqual(ui.theme.id, "catppuccin-latte")
        ui.cycleTheme()
        XCTAssertEqual(ui.theme.id, "catppuccin-frappe")
        ui.cycleTheme()
        XCTAssertEqual(ui.theme.id, "catppuccin-macchiato")
        ui.cycleTheme()
        XCTAssertEqual(ui.theme.id, "catppuccin-mocha")
        ui.cycleTheme()
        XCTAssertEqual(ui.theme.id, "cotton-candy")
        ui.cycleTheme()
        XCTAssertEqual(ui.theme.id, "galactic-purple")
        ui.cycleTheme()
        XCTAssertEqual(ui.theme.id, "dark")
    }

    func testIdleHairlinesUseDimBorderTone() {
        let ctx = ImGuiCreateContext(nil)!
        defer { ImGuiDestroyContext(ctx) }
        let ui = EngineUIManager()
        let io = ImGuiGetIO()!
        io.pointee.DisplaySize = ImVec2(x: 1920, y: 1080)
        io.pointee.DeltaTime = 1.0 / 60.0
        _ = ImFontAtlas_AddFontDefault(io.pointee.Fonts, nil)
        igImFontAtlasBuildMain(io.pointee.Fonts)

        // Idle panel hairlines (separators, window/child borders) must use
        // each theme's dim border tone so they sit back; the opaque tone is
        // reserved for hover and brand gold for the active/resizing state.
        for preset in AppTheme.allPresets {
            ui.setTheme(preset.theme)
            ImGuiNewFrame()
            let separator = ImGuiGetStyleColorVec4(Int32(ImGuiCol_Separator.rawValue))!.pointee
            let hovered = ImGuiGetStyleColorVec4(Int32(ImGuiCol_SeparatorHovered.rawValue))!.pointee
            let active = ImGuiGetStyleColorVec4(Int32(ImGuiCol_SeparatorActive.rawValue))!.pointee
            let border = ImGuiGetStyleColorVec4(Int32(ImGuiCol_Border.rawValue))!.pointee
            XCTAssertEqual(separator.x, preset.theme.borderDim.x, accuracy: 0.001, "\(preset.id): Separator")
            XCTAssertEqual(separator.w, preset.theme.borderDim.w, accuracy: 0.001, "\(preset.id): Separator alpha")
            XCTAssertEqual(border.x, preset.theme.borderDim.x, accuracy: 0.001, "\(preset.id): Border")
            XCTAssertEqual(hovered.x, preset.theme.border.x, accuracy: 0.001, "\(preset.id): SeparatorHovered")
            XCTAssertEqual(active.x, preset.theme.brandGold.x, accuracy: 0.001, "\(preset.id): SeparatorActive")
            ImGuiRender()
        }
    }

    func testCottonCandyTheme() {
        let ctx = ImGuiCreateContext(nil)!
        defer { ImGuiDestroyContext(ctx) }
        let ui = EngineUIManager()
        let io = ImGuiGetIO()!
        io.pointee.DisplaySize = ImVec2(x: 1920, y: 1080)
        io.pointee.DeltaTime = 1.0 / 60.0
        _ = ImFontAtlas_AddFontDefault(io.pointee.Fonts, nil)
        igImFontAtlasBuildMain(io.pointee.Fonts)

        // Barbie / cotton-candy / rainbow aliases all resolve to the new preset.
        XCTAssertEqual(AppTheme.theme(named: "barbie")?.id, "cotton-candy")
        XCTAssertEqual(AppTheme.theme(named: "rainbow")?.id, "cotton-candy")
        XCTAssertEqual(AppTheme.theme(named: "candy")?.id, "cotton-candy")
        XCTAssertEqual(ThemeCommand.resolve("BARBIE"), .named("CANDY"))
        XCTAssertEqual(ThemeCommand.resolve("rainbow"), .named("CANDY"))
        XCTAssertEqual(ThemeCommand.resolve("CANDY"), .named("CANDY"))
        XCTAssertTrue(ThemeCommand.promptText(currentName: "Cotton Candy").contains("CANDY"))
        XCTAssertTrue(ThemeCommand.listLine().contains("CANDY"))

        // Applying it works through the shared UI manager path.
        XCTAssertTrue(ui.setTheme(named: "barbie"))
        XCTAssertEqual(ui.theme.id, "cotton-candy")
        XCTAssertFalse(ui.isDarkTheme)

        // Deep-raspberry text on near-white pink keeps contrast high.
        func luminance(_ col: ImVec4) -> Double {
            return 0.2126 * Double(col.x) + 0.7152 * Double(col.y) + 0.0722 * Double(col.z)
        }
        let top = max(luminance(ui.theme.textPrimary), luminance(ui.theme.panelBg)) + 0.05
        let bottom = min(luminance(ui.theme.textPrimary), luminance(ui.theme.panelBg)) + 0.05
        XCTAssertGreaterThan(top / bottom, 3.0, "Cotton Candy must keep text readable on panelBg")

        ImGuiNewFrame()
        let candyWinBg = ImGuiGetStyleColorVec4(Int32(ImGuiCol_WindowBg.rawValue))!.pointee
        XCTAssertEqual(candyWinBg.x, AppTheme.cottonCandy.panelBg.x, accuracy: 0.001)
        ImGuiRender()

        // Cotton Candy sits after Mocha, Galactic after Candy, then wraps to Dark.
        ui.setTheme(AppTheme.catppuccinMocha)
        ui.cycleTheme()
        XCTAssertEqual(ui.theme.id, "cotton-candy")
        ui.cycleTheme()
        XCTAssertEqual(ui.theme.id, "galactic-purple")
        ui.cycleTheme()
        XCTAssertEqual(ui.theme.id, "dark")
    }

    func testGalacticPurpleThemeAndStarfield() {
        let ctx = ImGuiCreateContext(nil)!
        defer { ImGuiDestroyContext(ctx) }
        let ui = EngineUIManager()
        let io = ImGuiGetIO()!
        io.pointee.DisplaySize = ImVec2(x: 1920, y: 1080)
        io.pointee.DeltaTime = 1.0 / 60.0
        _ = ImFontAtlas_AddFontDefault(io.pointee.Fonts, nil)
        igImFontAtlasBuildMain(io.pointee.Fonts)

        // Aliases resolve to the new preset.
        XCTAssertEqual(AppTheme.theme(named: "galaxy")?.id, "galactic-purple")
        XCTAssertEqual(AppTheme.theme(named: "purple")?.id, "galactic-purple")
        XCTAssertEqual(AppTheme.theme(named: "space")?.id, "galactic-purple")
        XCTAssertTrue(ThemeCommand.promptText(currentName: "Galactic Purple").contains("GALAXY"))
        XCTAssertTrue(ThemeCommand.listLine().contains("GALAXY"))

        // Fresh manager: stars off and inactive.
        XCTAssertFalse(ui.starfieldPanoramaEnabled)
        XCTAssertFalse(ui.isStarfieldActive)

        // Entering Galactic Purple auto-enables the panorama.
        XCTAssertTrue(ui.setTheme(named: "galaxy"))
        XCTAssertEqual(ui.theme.id, "galactic-purple")
        XCTAssertTrue(ui.isDarkTheme)
        XCTAssertTrue(ui.starfieldPanoramaEnabled)
        XCTAssertTrue(ui.isStarfieldActive)

        // Leaving Galactic disables it again.
        ui.setTheme(AppTheme.dark)
        XCTAssertFalse(ui.starfieldPanoramaEnabled)
        XCTAssertFalse(ui.isStarfieldActive)

        // Manual toggle within Galactic; re-selecting keeps it.
        ui.setTheme(AppTheme.galacticPurple)
        XCTAssertTrue(ui.isStarfieldActive)
        ui.starfieldPanoramaEnabled = false
        XCTAssertFalse(ui.isStarfieldActive)
        XCTAssertEqual(ui.theme.id, "galactic-purple")
        ui.setTheme(AppTheme.galacticPurple)
        XCTAssertFalse(ui.starfieldPanoramaEnabled)

        // Starlight text stays readable on the deep-space panel and button.
        func luminance(_ col: ImVec4) -> Double {
            return 0.2126 * Double(col.x) + 0.7152 * Double(col.y) + 0.0722 * Double(col.z)
        }
        func contrast(_ c1: ImVec4, _ c2: ImVec4) -> Double {
            return (max(luminance(c1), luminance(c2)) + 0.05) / (min(luminance(c1), luminance(c2)) + 0.05)
        }
        XCTAssertGreaterThan(contrast(ui.theme.textPrimary, ui.theme.panelBg), 3.0)
        XCTAssertGreaterThan(contrast(ui.theme.textPrimary, ui.theme.buttonBg), 3.0)

        ImGuiNewFrame()
        let galacticWinBg = ImGuiGetStyleColorVec4(Int32(ImGuiCol_WindowBg.rawValue))!.pointee
        XCTAssertEqual(galacticWinBg.x, AppTheme.galacticPurple.panelBg.x, accuracy: 0.001)
        ImGuiRender()

        // Starfield math: twinkle stays in range, positions stay in bounds.
        for index in [0, 1, 7, 42, 159] {
            for t in [0.0, 0.5, 1.7, 30.0] {
                let a = GalacticStarfield.twinkleAlpha(index: index, timeSec: t)
                XCTAssertGreaterThanOrEqual(a, 0.30)
                XCTAssertLessThanOrEqual(a, 1.00)
                let p = GalacticStarfield.screenPosition(index: index, timeSec: t, width: 1920, height: 1080)
                XCTAssertGreaterThanOrEqual(p.x, 0.0)
                XCTAssertLessThan(p.x, 1920.0)
                XCTAssertGreaterThanOrEqual(p.y, 0.0)
                XCTAssertLessThan(p.y, 1080.0)
            }
            let r = GalacticStarfield.radius(index: index)
            XCTAssertGreaterThanOrEqual(r, 1.0)
            XCTAssertLessThanOrEqual(r, 3.5)
        }

        // Panorama drifts left at constant height and wraps after one sweep.
        var driftIndex = 0
        for i in 0..<GalacticStarfield.starCount {
            if GalacticStarfield.basePosition(index: i, width: 1000, height: 800).x > 500 {
                driftIndex = i
                break
            }
        }
        let e0 = GalacticStarfield.screenPosition(index: driftIndex, timeSec: 0, width: 1000, height: 800)
        let e1 = GalacticStarfield.screenPosition(index: driftIndex, timeSec: 1, width: 1000, height: 800)
        XCTAssertLessThan(e1.x, e0.x, "panorama drifts left")
        XCTAssertEqual(e0.y, e1.y, accuracy: 0.001, "panorama holds height")
        let par = Double(GalacticStarfield.parallax(index: 5))
        let period = Double(1000) / (Double(GalacticStarfield.baseSpeed) * par)
        let w0 = GalacticStarfield.screenPosition(index: 5, timeSec: 0, width: 1000, height: 800)
        let w1 = GalacticStarfield.screenPosition(index: 5, timeSec: period, width: 1000, height: 800)
        XCTAssertEqual(w0.x, w1.x, accuracy: 0.001, "panorama wraps")

        // Clock clamps spikes, ignores rewind, wraps hourly.
        XCTAssertEqual(GalacticStarfield.advance(current: 10, by: -5), 10, "negative delta holds")
        XCTAssertEqual(GalacticStarfield.advance(current: 10, by: 100), 10.25, accuracy: 0.001, "large delta clamps")
        XCTAssertEqual(
            GalacticStarfield.advance(current: 3599.9, by: 0.25),
            3599.9 + 0.25 - 3600.0, accuracy: 0.001, "clock wraps")

        // Time advances through the manager.
        ui.advanceStarfield(by: 1.0 / 60.0)
        XCTAssertGreaterThan(ui.starfieldTimeSec, 0.0)
    }

    func testStarfieldZoomFlyThrough() {
        // Zoom scale: unity at the reference zoom, clamped at extremes.
        XCTAssertEqual(GalacticStarfield.zoomScale(zoom: 2, referenceZoom: 2), 1.0)
        XCTAssertEqual(GalacticStarfield.zoomScale(zoom: 4, referenceZoom: 2), 2.0)
        XCTAssertEqual(GalacticStarfield.zoomScale(zoom: 0, referenceZoom: 0), 1.0)
        XCTAssertEqual(GalacticStarfield.zoomScale(zoom: 100, referenceZoom: 1), 6.0)
        XCTAssertEqual(GalacticStarfield.zoomScale(zoom: 0.001, referenceZoom: 1), 0.25)

        // At the reference zoom the field matches the unzoomed panorama.
        for index in [0, 5, 42] {
            let plain = GalacticStarfield.screenPosition(index: index, timeSec: 1.7, width: 1000, height: 800)
            let zoomed = GalacticStarfield.screenPosition(
                index: index, timeSec: 1.7, width: 1000, height: 800,
                speed: GalacticStarfield.baseSpeed, zoom: 3, referenceZoom: 3)
            XCTAssertEqual(plain.x, zoomed.x, accuracy: 0.01)
            XCTAssertEqual(plain.y, zoomed.y, accuracy: 0.01)
        }

        // Screenspace at every zoom: stars span the full viewport, and drift
        // runs faster zoomed in (fly-through) while positions never clump.
        for (z, ref) in [(0.25, 1.0), (6.0, 1.0)] {
            var minX: Float = 1000
            var maxX: Float = -1000
            for i in 0..<GalacticStarfield.starCount {
                let p = GalacticStarfield.screenPosition(
                    index: i, timeSec: 3.7, width: 1000, height: 800,
                    speed: GalacticStarfield.baseSpeed, zoom: z, referenceZoom: ref)
                minX = min(minX, p.x)
                maxX = max(maxX, p.x)
                XCTAssertGreaterThanOrEqual(p.y, 0.0)
                XCTAssertLessThan(p.y, 800.0)
            }
            XCTAssertLessThan(minX, 100.0, "stars reach the left edge")
            XCTAssertGreaterThan(maxX, 900.0, "stars reach the right edge")
        }

        // Drift speed scales with zoom over the same time span.
        var driftStar: Int? = nil
        for i in 0..<GalacticStarfield.starCount {
            let bx = GalacticStarfield.basePosition(index: i, width: 1000, height: 800).x
            if bx > 100 && bx < 900 { driftStar = i; break }
        }
        XCTAssertNotNil(driftStar)
        if let s = driftStar {
            func travel(zoom: Double) -> Double {
                let a = Double(GalacticStarfield.screenPosition(
                    index: s, timeSec: 0, width: 1000, height: 800,
                    speed: GalacticStarfield.baseSpeed, zoom: zoom, referenceZoom: 1).x)
                let b = Double(GalacticStarfield.screenPosition(
                    index: s, timeSec: 1, width: 1000, height: 800,
                    speed: GalacticStarfield.baseSpeed, zoom: zoom, referenceZoom: 1).x)
                return a - b
            }
            XCTAssertEqual(travel(zoom: 4) / travel(zoom: 1), 4.0, accuracy: 0.05)
            XCTAssertGreaterThan(
                GalacticStarfield.scaledRadius(index: s, zoom: 4, referenceZoom: 1),
                GalacticStarfield.scaledRadius(index: s, zoom: 1, referenceZoom: 1))
        }
        // Radius follows zoom exactly at unity and clamps at extremes.
        XCTAssertEqual(
            GalacticStarfield.scaledRadius(index: 9, zoom: 2, referenceZoom: 2),
            GalacticStarfield.radius(index: 9))
        XCTAssertLessThanOrEqual(GalacticStarfield.scaledRadius(index: 9, zoom: 100, referenceZoom: 1), 7.0)

        // Fly-through fade: exact expectations from each star's size.
        var bigIndex = 0
        var bigRadius: Float = 0
        var smallIndex = 0
        var smallRadius: Float = .greatestFiniteMagnitude
        for i in 0..<GalacticStarfield.starCount {
            let r = GalacticStarfield.radius(index: i)
            if r > bigRadius { bigRadius = r; bigIndex = i }
            if r < smallRadius { smallRadius = r; smallIndex = i }
        }
        let bigNorm = (Double(bigRadius) - 1.0) / 2.3
        XCTAssertEqual(
            GalacticStarfield.zoomFade(index: bigIndex, zoom: 8, referenceZoom: 1),
            1.0 - 0.9 * bigNorm, accuracy: 0.001,
            "big stars dissolve zoomed in")
        XCTAssertEqual(GalacticStarfield.zoomFade(index: bigIndex, zoom: 1, referenceZoom: 1), 1.0, accuracy: 0.001)
        let smallNorm = (Double(smallRadius) - 1.0) / 2.3
        XCTAssertEqual(
            GalacticStarfield.zoomFade(index: smallIndex, zoom: 0.125, referenceZoom: 1),
            1.0 - 0.7 * (1.0 - smallNorm), accuracy: 0.001,
            "small stars dissolve zoomed far out")
        for z in [0.05, 0.25, 0.5, 1.0, 2.0, 4.0, 8.0, 32.0] {
            for i in [0, 3, 77, 159] {
                let f = GalacticStarfield.zoomFade(index: i, zoom: z, referenceZoom: 1)
                XCTAssertGreaterThanOrEqual(f, 0.0)
                XCTAssertLessThanOrEqual(f, 1.0)
            }
        }

        // Reference zoom resets when leaving Galactic.
        let ui = EngineUIManager()
        ui.setTheme(AppTheme.galacticPurple)
        ui.starfieldReferenceZoom = 2.5
        ui.setTheme(AppTheme.dark)
        XCTAssertNil(ui.starfieldReferenceZoom)
    }

    func testStarfieldMouseParallax() {
        // Opposite the mouse: mouse right/below center pushes stars left/up.
        XCTAssertLessThan(
            GalacticStarfield.mouseParallaxTarget(delta: -100, halfExtent: 500, parallax: 1), 0.0)
        XCTAssertGreaterThan(
            GalacticStarfield.mouseParallaxTarget(delta: 100, halfExtent: 500, parallax: 1), 0.0)
        XCTAssertEqual(
            GalacticStarfield.mouseParallaxTarget(delta: 0, halfExtent: 500, parallax: 1), 0.0)
        // Clamped at the edges and scaled by depth.
        XCTAssertEqual(
            GalacticStarfield.mouseParallaxTarget(delta: -5000, halfExtent: 500, parallax: 1),
            -GalacticStarfield.mouseParallaxStrength)
        XCTAssertEqual(
            GalacticStarfield.mouseParallaxTarget(delta: 250, halfExtent: 500, parallax: 0.5),
            GalacticStarfield.mouseParallaxTarget(delta: 250, halfExtent: 500, parallax: 1) * 0.5,
            accuracy: 0.001)
        XCTAssertEqual(GalacticStarfield.mouseParallaxTarget(delta: 100, halfExtent: 0, parallax: 1), 0.0)

        // Smoothing converges monotonically and holds without time.
        let first = GalacticStarfield.smoothOffset(current: 0, target: -20, deltaSec: 1.0 / 60.0)
        XCTAssertLessThan(first, 0.0)
        XCTAssertGreaterThan(first, -20.0)
        let second = GalacticStarfield.smoothOffset(current: first, target: -20, deltaSec: 1.0 / 60.0)
        XCTAssertLessThan(second, first)
        XCTAssertEqual(GalacticStarfield.smoothOffset(current: 5, target: -20, deltaSec: 0), 5.0)
        XCTAssertEqual(GalacticStarfield.smoothOffset(current: 5, target: -20, deltaSec: -1), 5.0)

        // Wrapped application stays in bounds.
        let shifted = GalacticStarfield.applyMouseParallax(
            x: 5, y: 5, offsetX: -30, offsetY: 900, parallax: 1, width: 1000, height: 800)
        XCTAssertGreaterThanOrEqual(shifted.x, 0.0)
        XCTAssertLessThan(shifted.x, 1000.0)
        XCTAssertGreaterThanOrEqual(shifted.y, 0.0)
        XCTAssertLessThan(shifted.y, 800.0)
        XCTAssertEqual(shifted.x, 975.0, accuracy: 0.001)
        XCTAssertEqual(shifted.y, 105.0, accuracy: 0.001)

        // Manager: offset moves opposite the mouse, decays when invalid.
        let ui = EngineUIManager()
        ui.updateStarfieldMouse(
            mouseX: 1400, mouseY: 200, valid: true,
            centerX: 960, centerY: 540, halfW: 960, halfH: 540, deltaSec: 1.0 / 60.0)
        XCTAssertLessThan(ui.starfieldMouseOffset.x, 0.0, "mouse right pushes stars left")
        XCTAssertGreaterThan(ui.starfieldMouseOffset.y, 0.0, "mouse above center pushes stars down")
        ui.updateStarfieldMouse(
            mouseX: 1400, mouseY: 200, valid: true,
            centerX: 960, centerY: 540, halfW: 960, halfH: 540, deltaSec: 1.0 / 60.0)
        XCTAssertLessThan(ui.starfieldMouseOffset.x, -0.1, "offset keeps easing while held")
        ui.starfieldMouseOffset = (x: 10, y: -8)
        ui.updateStarfieldMouse(
            mouseX: 0, mouseY: 0, valid: false,
            centerX: 960, centerY: 540, halfW: 960, halfH: 540, deltaSec: 1.0 / 60.0)
        XCTAssertLessThan(abs(ui.starfieldMouseOffset.x), 10.0)
        XCTAssertLessThan(abs(ui.starfieldMouseOffset.y), 8.0)
        XCTAssertGreaterThan(
            abs(GalacticStarfield.mouseParallaxTarget(delta: 500, halfExtent: 500, parallax: 1)),
            GalacticStarfield.baseSpeed,
            "mouse response outweighs one second of ambient drift")
    }

    func testStarfieldRealStarColors() {
        // Real stars are never green and are always bright: no tint may peak
        // in green, and every tint peaks at a high channel value.
        var seen = Set<String>()
        for i in 0..<GalacticStarfield.starCount {
            let t = GalacticStarfield.tint(index: i)
            XCTAssertFalse(t.g > t.r && t.g > t.b, "stars cannot peak in green")
            XCTAssertGreaterThanOrEqual(max(t.r, max(t.g, t.b)), 200, "stars are bright")
            seen.insert("\(t.r),\(t.g),\(t.b)")
        }
        // A spread of spectral classes, not a single white.
        XCTAssertGreaterThan(seen.count, 3)
    }

    func testThemeSyncsStaleWindowContexts() {
        // Each OS window owns an ImGui context (and therefore a style). A
        // switch made while window B is current styles only B; window A must
        // heal on its next activation instead of rendering dropdowns and
        // popups in the previous theme's colors.
        let ctxA = ImGuiCreateContext(nil)!
        defer { ImGuiDestroyContext(ctxA) }
        let ctxB = ImGuiCreateContext(nil)!
        defer { ImGuiDestroyContext(ctxB) }
        let ui = EngineUIManager()
        let manager = EngineWindowManager()
        let winA = manager.register(handle: OpaquePointer(bitPattern: 0xA1)!, id: 101, isMain: true)
        let winB = manager.register(handle: OpaquePointer(bitPattern: 0xB2)!, id: 102, isMain: false)
        winA.imguiContext = ctxA
        winB.imguiContext = ctxB

        igSetCurrentContext(ctxA)
        ui.setTheme(AppTheme.dark)
        ui.syncThemeIfNeeded(for: winA)
        XCTAssertEqual(winA.appliedThemeRevision, ui.themeRevision)

        // Switch while B is current: only B's style updates eagerly.
        igSetCurrentContext(ctxB)
        ui.setTheme(AppTheme.light)
        ui.syncThemeIfNeeded(for: winB)
        XCTAssertEqual(winB.appliedThemeRevision, ui.themeRevision)
        XCTAssertNotEqual(winA.appliedThemeRevision, ui.themeRevision)

        // A still shows the old theme...
        igSetCurrentContext(ctxA)
        let staleBg = ImGuiGetStyleColorVec4(Int32(ImGuiCol_WindowBg.rawValue))!.pointee
        XCTAssertEqual(staleBg.x, AppTheme.dark.panelBg.x, accuracy: 0.001)

        // ...until the render path's activation-time sync heals it.
        ui.syncThemeIfNeeded(for: winA)
        let healedBg = ImGuiGetStyleColorVec4(Int32(ImGuiCol_WindowBg.rawValue))!.pointee
        XCTAssertEqual(healedBg.x, AppTheme.light.panelBg.x, accuracy: 0.001)
        XCTAssertEqual(winA.appliedThemeRevision, ui.themeRevision)

        // A fresh window is a no-op.
        ui.syncThemeIfNeeded(for: winA)
        XCTAssertEqual(winA.appliedThemeRevision, ui.themeRevision)
    }
}
