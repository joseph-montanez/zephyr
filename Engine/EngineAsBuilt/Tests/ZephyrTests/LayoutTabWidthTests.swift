import XCTest
import ImGui
@testable import ZephyrCore

/// Layout-tab label width regressions.
///
/// ImGui sizes a tab bar in `TabBarLayout()` from the labels it registered on
/// the previous frame, measured in whichever font is current when that layout
/// runs — the bar's *first* tab, not necessarily the tab being measured. Two
/// things therefore used to clip a layout tab's label while the bar had plenty
/// of room, drawing "MyLayo…" instead of "MyLayout":
///
/// - a tab that appeared this frame is not registered yet and `TabBarGetTabName()`
///   answers "N/A", so it was laid out three characters wide;
/// - the selected tab is drawn bold but measured regular, so the bold label
///   never fit the width its regular metrics asked for.
///
/// `DrawingViewTabBarUI` now pushes each tab's natural width (see
/// `DrawingViewTabWidthPolicy`) before `BeginTabItem()`, which ImGui stores as
/// the tab's `RequestedWidth` and prefers over the remembered name.
final class LayoutTabWidthTests: XCTestCase {

    private struct Config {
        var pushRequestedWidth: Bool
        var realFonts: Bool
    }

    private func makeContext(realFonts: Bool) -> (bold: UnsafeMutablePointer<ImFont>?, regular: UnsafeMutablePointer<ImFont>?) {
        _ = ImGuiCreateContext(nil)
        let io = ImGuiGetIO()!
        io.pointee.IniFilename = nil
        io.pointee.DisplaySize = ImVec2(x: 1920, y: 1080)
        io.pointee.DeltaTime = 1.0 / 60.0
        var regular: UnsafeMutablePointer<ImFont>? = nil
        var bold: UnsafeMutablePointer<ImFont>? = nil
        if realFonts {
            regular = ImFontAtlas_AddFontFromFileTTF(
                io.pointee.Fonts, fontPath("Geist-Regular.ttf"), 16, nil, nil)
            bold = ImFontAtlas_AddFontFromFileTTF(
                io.pointee.Fonts, fontPath("Geist-Bold.ttf"), 16, nil, nil)
            XCTAssertNotNil(regular)
            XCTAssertNotNil(bold)
        } else {
            _ = ImFontAtlas_AddFontDefault(io.pointee.Fonts, nil)
        }
        igImFontAtlasBuildMain(io.pointee.Fonts)
        return (bold, regular)
    }

    private func fontPath(_ name: String) -> String {
        URL(fileURLWithPath: #filePath)                  // Tests/ZephyrTests/<file>
            .deletingLastPathComponent()                 // Tests/ZephyrTests
            .deletingLastPathComponent()                 // Tests
            .deletingLastPathComponent()                 // package root
            .appendingPathComponent("Fonts/\(name)").path
    }

    /// Renders the layout tab strip the way `DrawingViewTabBarUI.render` does
    /// (same window placement, style pushes and tab-bar flags) and returns the
    /// width tab index 1 was drawn with, per frame. 0 means ImGui skipped the
    /// tab that frame.
    private func measureSecondTab(
        _ config: Config,
        frames: [(names: [String], selected: Int)]
    ) -> (widths: [Float], tabNames: [String], boldTextWidths: [Float], framePaddingX: Float) {
        let fonts = makeContext(realFonts: config.realFonts)
        defer { ImGuiDestroyContext(igGetCurrentContext()) }

        let dw: Float = 1920
        let dh: Float = 1080
        let barH = ImGuiGetFrameHeight() + 8
        let barY = dh - (ImGuiGetTextLineHeight() + 12) - barH

        var widths: [Float] = []
        var tabNames: [String] = []
        var boldTextWidths: [Float] = []
        var lastSelected = 0

        for frame in frames {
            ImGuiNewFrame()
            // The strip only exists while the document has a second view.
            if frame.names.count > 1 {
                ImGuiSetNextWindowPos(
                    ImVec2(x: 0, y: barY), Int32(ImGuiCond_Always.rawValue), ImVec2(x: 0, y: 0))
                ImGuiSetNextWindowSize(
                    ImVec2(x: dw, y: barH), Int32(ImGuiCond_Always.rawValue))
                ImGuiPushStyleVarX(Int32(ImGuiStyleVar_WindowPadding.rawValue), 8)
                ImGuiPushStyleVarY(Int32(ImGuiStyleVar_WindowPadding.rawValue), 3)
                ImGuiPushStyleVarX(Int32(ImGuiStyleVar_ItemSpacing.rawValue), 2)
                let flags: Int32 =
                    Int32(ImGuiWindowFlags_NoTitleBar.rawValue)
                    | Int32(ImGuiWindowFlags_NoCollapse.rawValue)
                    | Int32(ImGuiWindowFlags_NoResize.rawValue)
                    | Int32(ImGuiWindowFlags_NoMove.rawValue)
                    | Int32(ImGuiWindowFlags_NoSavedSettings.rawValue)
                var opened = true
                if igBegin("##DrawingViewTabBar", &opened, flags) {
                    ImGuiPushStyleVar(Int32(ImGuiStyleVar_TabMinWidthShrink.rawValue), 1e9)
                    let tabBarFlags = Int32(ImGuiTabBarFlags_NoTooltip.rawValue)
                        | Int32(ImGuiTabBarFlags_FittingPolicyScroll.rawValue)
                    if ImGuiBeginTabBar("DrawingViews", tabBarFlags) {
                        for (index, name) in frame.names.enumerated() {
                            let isSelected = index == frame.selected
                            var itemFlags: Int32 = 0
                            if isSelected && frame.selected != lastSelected {
                                itemFlags |= Int32(ImGuiTabItemFlags_SetSelected.rawValue)
                            }
                            if isSelected, let bold = fonts.bold {
                                ImGuiPushFont(bold, ImGuiGetFontSize())
                            }
                            if config.pushRequestedWidth {
                                ImGuiSetNextItemWidth(DrawingViewTabWidthPolicy.requestedWidth(
                                    labelWidth: ImGuiCalcTextSize(name, nil, true, -1).x,
                                    framePaddingX: ImGuiGetStyle().pointee.FramePadding.x,
                                    fontSize: ImGuiGetFontSize()))
                            }
                            let visible = ImGuiBeginTabItem(
                                "\(name)###DrawingView_probe_\(index)", nil, itemFlags)
                            if index == 1 {
                                let min = ImGuiGetItemRectMin()
                                let max = ImGuiGetItemRectMax()
                                widths.append(max.x - min.x)
                                tabNames.append(name)
                                boldTextWidths.append(
                                    ImGuiCalcTextSize(name, nil, true, -1).x)
                            }
                            if isSelected, fonts.bold != nil { ImGuiPopFont() }
                            if visible { ImGuiEndTabItem() }
                        }
                        let addLayoutFlags = Int32(
                            ImGuiTabItemFlags_Trailing.rawValue | ImGuiTabItemFlags_NoTooltip.rawValue)
                        _ = ImGuiTabItemButton("+", addLayoutFlags)
                        ImGuiEndTabBar()
                    }
                    ImGuiPopStyleVar(1)
                }
                igEnd()
                ImGuiPopStyleVar(3)
            }
            ImGuiRender()
            lastSelected = frame.selected
        }
        return (widths, tabNames, boldTextWidths, ImGuiGetStyle().pointee.FramePadding.x)
    }

    /// The reported bug: after `LAYOUT N` the new (selected, bold) layout tab
    /// was drawn narrower than its label, so it read "MyLayo…".
    func testSelectedBoldLayoutTabFitsItsLabel() {
        let fixed = measureSecondTab(
            Config(pushRequestedWidth: true, realFonts: true),
            frames: [(["Model"], 0), (["Model"], 0)]
                + Array(repeating: (["Model", "MyLayout"], 1), count: 4))
        let painted = zip(fixed.widths, fixed.boldTextWidths).filter { $0.0 > 0 }
        XCTAssertFalse(painted.isEmpty, "layout tab was never painted")
        for (width, textWidth) in painted {
            // Tab background is the bold label plus frame padding on both
            // sides, so a narrower tab means ImGui ellipsized the name.
            XCTAssertGreaterThanOrEqual(
                width, textWidth + fixed.framePaddingX * 2,
                "tab drawn \(width)pt for a \(textWidth)pt bold label: \(fixed.widths)")
        }

        // Guard the mechanism: ImGui's own sizing measures the selected tab in
        // the regular font of the bar's first tab, so the bold label is clipped.
        let stale = measureSecondTab(
            Config(pushRequestedWidth: false, realFonts: true),
            frames: [(["Model"], 0), (["Model"], 0)]
                + Array(repeating: (["Model", "MyLayout"], 1), count: 4))
        let stalePainted = zip(stale.widths, stale.boldTextWidths).filter { $0.0 > 0 }
        XCTAssertFalse(stalePainted.isEmpty, "layout tab was never painted")
        XCTAssertTrue(
            stalePainted.contains { $0.0 < $0.1 + stale.framePaddingX * 2 },
            "regular-font sizing no longer clips the bold label: \(stale.widths)")
    }

    /// ImGui needs a frame after a tab appears before it knows the label, so
    /// the first painted frame used the "N/A" placeholder width. The requested
    /// width removes that frame.
    func testNewLayoutTabFitsFromFirstPaintedFrame() {
        let probe = measureSecondTab(
            Config(pushRequestedWidth: true, realFonts: false),
            frames: [(["Model"], 0), (["Model"], 0)]
                + Array(repeating: (["Model", "MyLayout"], 1), count: 6))
        let painted = zip(probe.widths, probe.boldTextWidths).filter { $0.0 > 0 }
        XCTAssertFalse(painted.isEmpty, "layout tab was never painted")
        for (width, textWidth) in painted {
            XCTAssertGreaterThanOrEqual(
                width, textWidth + probe.framePaddingX * 2,
                "first painted frames were narrow: \(probe.widths)")
        }
    }

    func testRequestedWidthMatchesImGuiTabSizing() {
        // Text plus frame padding each side and the 1pt ImGui adds for a tab
        // without a close button: the same 65 ImGui derives itself.
        XCTAssertEqual(
            DrawingViewTabWidthPolicy.requestedWidth(
                labelWidth: 56, framePaddingX: 4, fontSize: 13),
            65)
        // Capped like TabBarCalcMaxTabWidth().
        XCTAssertEqual(
            DrawingViewTabWidthPolicy.requestedWidth(
                labelWidth: 900, framePaddingX: 4, fontSize: 13),
            260)
        // Font metrics not available yet: leave the sizing to ImGui.
        XCTAssertEqual(
            DrawingViewTabWidthPolicy.requestedWidth(
                labelWidth: 0, framePaddingX: 4, fontSize: 13),
            0)
    }
}
