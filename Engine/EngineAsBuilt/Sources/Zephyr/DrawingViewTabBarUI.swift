import ZephyrCore
import Foundation
import ImGui

@MainActor
struct DrawingViewTabBarUI {
    private static var lastViewIndexByTabID: [UUID: Int] = [:]

    static func render(
        engine: PhrostEngine,
        dw: Float,
        dh: Float,
        tab: DocumentTab,
        selectedViewIndex: Int,
        canSwitch: Bool
    ) {
        guard tab.editingBlockID == nil,
              tab.drawingViews.count > 1 else { return }

        let selectedIndex = DrawingViewTabBarPolicy.clampedViewIndex(
            selectedViewIndex, viewCount: tab.drawingViews.count)
        var effectiveSelectedIndex = selectedIndex

        let barH = AppLayout.drawingViewTabBarHeight
        let barY = dh - AppLayout.statusBarHeight - barH
        let flags: Int32 =
            Int32(ImGuiWindowFlags_NoTitleBar.rawValue) |
            Int32(ImGuiWindowFlags_NoCollapse.rawValue) |
            Int32(ImGuiWindowFlags_NoResize.rawValue) |
            Int32(ImGuiWindowFlags_NoMove.rawValue) |
            Int32(ImGuiWindowFlags_NoSavedSettings.rawValue)

        ImGuiSetNextWindowPos(
            ImVec2(x: 0, y: barY),
            Int32(ImGuiCond_Always.rawValue),
            ImVec2(x: 0, y: 0))
        ImGuiSetNextWindowSize(
            ImVec2(x: dw, y: barH),
            Int32(ImGuiCond_Always.rawValue))

        ImGuiPushStyleVarX(Int32(ImGuiStyleVar_WindowPadding.rawValue), 8)
        ImGuiPushStyleVarY(Int32(ImGuiStyleVar_WindowPadding.rawValue), 3)
        ImGuiPushStyleVarX(Int32(ImGuiStyleVar_ItemSpacing.rawValue), 2)
        ImGuiPushStyleColor(Int32(ImGuiCol_WindowBg.rawValue), engine.ui.theme.tabBarBg)

        var opened = true
        if igBegin("##DrawingViewTabBar", &opened, flags) {
            // Each OS window has its own ImGui tab-bar state, while this
            // Swift static is shared. Key forced selection by document tab
            // so alternating main/float frames do not reset one another.
            let forceSelection = !canSwitch
                || lastViewIndexByTabID[tab.id] != selectedIndex

            let tabBarFlags = Int32(ImGuiTabBarFlags_NoTooltip.rawValue)

            if ImGuiBeginTabBar("DrawingViews", tabBarFlags) {
                for index in tab.drawingViews.indices {
                    let view = tab.drawingViews[index]
                    let isSelected = index == selectedIndex
                    var itemFlags: Int32 = 0
                    if isSelected && forceSelection {
                        itemFlags |= Int32(ImGuiTabItemFlags_SetSelected.rawValue)
                    }

                    if isSelected, let boldFont = engine.ui.boldFont {
                        ImGuiPushFont(boldFont, ImGuiGetFontSize())
                    }

                    let visible = ImGuiBeginTabItem(
                        "\(view.name)###DrawingView_\(tab.id.uuidString)_\(index)",
                        nil,
                        itemFlags)

                    if isSelected, engine.ui.boldFont != nil {
                        ImGuiPopFont()
                    }

                    if visible {
                        if DrawingViewTabBarPolicy.shouldSwitch(
                            showsActiveTab: canSwitch,
                            selectedViewIndex: selectedIndex,
                            clickedViewIndex: index) {
                            let incomingCamera = view.cameraState
                            let needsInitialFit =
                                abs(incomingCamera.offsetX) < 1e-12 &&
                                abs(incomingCamera.offsetY) < 1e-12 &&
                                abs(incomingCamera.zoom - 1.0) < 1e-12 &&
                                abs(incomingCamera.rotation) < 1e-12

                            if engine.tabManager.switchToView(at: index) {
                                effectiveSelectedIndex = index
                                if needsInitialFit {
                                    engine.zoomExtents()
                                }
                            }
                        }

                        if igBeginPopupContextItem("##DrawingView_\(tab.id.uuidString)_\(index)_ctx", Int32(ImGuiPopupFlags_MouseButtonRight.rawValue)) {
                            if view.kind == .sheet {
                                if igMenuItem_Bool("Page Setup…", nil, false, true) {
                                    engine.commandProcessor.executeCommand("PAGESETUP")
                                }
                            }
                            ImGuiEndPopup()
                        }

                        if index == effectiveSelectedIndex {
                            let min = ImGuiGetItemRectMin()
                            let max = ImGuiGetItemRectMax()
                            ImDrawListAddRectFilled(
                                igGetWindowDrawList(),
                                ImVec2(x: min.x, y: max.y - 3),
                                ImVec2(x: max.x, y: max.y),
                                igGetColorU32_Vec4(engine.ui.theme.brandGold),
                                0,
                                0)
                        }

                        ImGuiEndTabItem()
                    }
                }
                ImGuiEndTabBar()
            }

            lastViewIndexByTabID[tab.id] = effectiveSelectedIndex
        }
        igEnd()

        ImGuiPopStyleColor(1)
        ImGuiPopStyleVar(3)
    }
}
