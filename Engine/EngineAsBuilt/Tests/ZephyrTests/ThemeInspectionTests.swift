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
        XCTAssertEqual(AppTheme.allPresets.count, 7)
        let presetIDs = AppTheme.allPresets.map(\.id)
        XCTAssertTrue(presetIDs.contains("dark"))
        XCTAssertTrue(presetIDs.contains("light"))
        XCTAssertTrue(presetIDs.contains("catppuccin-latte"))
        XCTAssertTrue(presetIDs.contains("catppuccin-frappe"))
        XCTAssertTrue(presetIDs.contains("catppuccin-macchiato"))
        XCTAssertTrue(presetIDs.contains("catppuccin-mocha"))
        XCTAssertTrue(presetIDs.contains("cotton-candy"))

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

        // Cotton Candy sits after Mocha in the cycle, then wraps to Dark.
        ui.setTheme(AppTheme.catppuccinMocha)
        ui.cycleTheme()
        XCTAssertEqual(ui.theme.id, "cotton-candy")
        ui.cycleTheme()
        XCTAssertEqual(ui.theme.id, "dark")
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
