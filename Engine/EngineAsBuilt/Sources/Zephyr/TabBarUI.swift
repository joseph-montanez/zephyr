import ZephyrCore
import Foundation
import ImGui

// MARK: - TabBarUI
//
// Renders the document tab bar at the very top of the window.
// Supports multiple open documents with tab-style navigation:
//   - Click a tab to switch documents
//   - "+" button creates a new empty drawing (Ctrl+N)
//   - "x" button closes a tab
//   - Dirty tabs show an asterisk (*) and prompt to save before closing
//   - Tooltips show the full file path on hover
//
// The active tab is visually highlighted. When closing a dirty tab, a modal
// popup appears with Save/Discard/Cancel options.

@MainActor
struct TabBarUI {
    /// Tracks which tab index has a pending close request (when dirty).
    static var _tabClosePending: Int = -1
    /// Whether the pending close is for a dirty (unsaved) tab.
    static var _tabCloseDirty: Bool = false
    /// Tracks the last known active index to avoid spamming ImGui with SetSelected.
    static var _lastActiveIdx: Int = -1

    /// Renders the tab bar at the top of the window.
    /// - Parameters:
    ///   - engine: The engine instance.
    ///   - dw: Display width for full-width positioning.
    static func render(engine: PhrostEngine, dw: Float) {
        let chromeH = AppLayout.topChromeHeight
        let tabH = AppLayout.tabBarHeight
        let flags: Int32 = 1 | 2 | 4 | 8 | 256

        // ==========================================
        // 1. Tab Bar
        // ==========================================
        ImGuiSetNextWindowPos(ImVec2(x: 0, y: chromeH), Int32(ImGuiCond_Always.rawValue), ImVec2(x: 0, y: 0))
        ImGuiSetNextWindowSize(ImVec2(x: dw, y: tabH), Int32(ImGuiCond_Always.rawValue))

        ImGuiPushStyleVarX(Int32(ImGuiStyleVar_WindowPadding.rawValue), 16)
        ImGuiPushStyleVarY(Int32(ImGuiStyleVar_WindowPadding.rawValue), 4) // top margin
        ImGuiPushStyleVarX(Int32(ImGuiStyleVar_ItemSpacing.rawValue), 12) // more horizontal spacing

        if let style = igGetStyle() {
            let defaultFramePadding = style.pointee.FramePadding
            ImGuiPushStyleVar(Int32(ImGuiStyleVar_FramePadding.rawValue), ImVec2(x: defaultFramePadding.x + 8.0, y: defaultFramePadding.y + 4.0))
        } else {
            ImGuiPushStyleVar(Int32(ImGuiStyleVar_FramePadding.rawValue), ImVec2(x: 12.0, y: 7.0))
        }
        
        ImGuiPushStyleColor(Int32(ImGuiCol_WindowBg.rawValue), engine.ui.theme.tabBarBg)

        var requestedCloseIndex: Int?
        var opened = true
        if igBegin("##TabBar", &opened, flags) {
            let tabs = engine.tabManager.tabs
            let activeIdx = engine.tabManager.activeIndex
            
            let shouldForceSelection = (activeIdx != _lastActiveIdx)
            if shouldForceSelection {
                _lastActiveIdx = activeIdx
            }

            let tabBarFlags = Int32(ImGuiTabBarFlags_Reorderable.rawValue | ImGuiTabBarFlags_AutoSelectNewTabs.rawValue | ImGuiTabBarFlags_NoTooltip.rawValue)
            if ImGuiBeginTabBar("DocumentTabs", tabBarFlags) {

                for i in 0..<tabs.count {
                    let tab = tabs[i]
                    let isActive = (i == activeIdx)
                    let hasUnsaved = tab.hasUnsavedChanges
                    let label = tab.displayName

                    var tabFlags: Int32 = 0
                    if isActive && shouldForceSelection {
                        tabFlags |= Int32(ImGuiTabItemFlags_SetSelected.rawValue)
                    }
                    if hasUnsaved {
                        tabFlags |= Int32(ImGuiTabItemFlags_UnsavedDocument.rawValue)
                    }

                    if isActive, let boldFont = engine.ui.boldFont {
                        ImGuiPushFont(boldFont, ImGuiGetFontSize())
                    }
                    
                    var tabOpen = true
                    let tabVisible = ImGuiBeginTabItem("\(label)###Tab_\(tab.id.uuidString)", &tabOpen, tabFlags)
                    
                    if isActive, engine.ui.boldFont != nil {
                        ImGuiPopFont()
                    }

                    if tabVisible {
                        if !isActive {
                            engine.tabManager.switchToTab(at: i)
                            _lastActiveIdx = i
                        }
                        
                        if isActive {
                            let min = ImGuiGetItemRectMin()
                            let max = ImGuiGetItemRectMax()
                            let drawList = igGetWindowDrawList()
                            let goldCol = igGetColorU32_Vec4(engine.ui.theme.brandGold)
                            ImDrawListAddRectFilled(drawList, ImVec2(x: min.x, y: max.y - 3), ImVec2(x: max.x, y: max.y), goldCol, 0.0, 0)
                        }
                        
                        if ImGuiIsItemHovered(0) {
                            ImGuiBeginTooltip()
                            if let url = tab.fileURL {
                                ImGuiTextV(url.path)
                            } else {
                                ImGuiTextV("Unsaved document")
                            }
                            ImGuiEndTooltip()
                        }
                        
                        ImGuiEndTabItem()
                    }

                    if !tabOpen {
                        requestedCloseIndex = i
                    }
                }

                // Add the '+' button at the trailing end
                let addTabFlags = Int32(ImGuiTabItemFlags_Trailing.rawValue | ImGuiTabItemFlags_NoTooltip.rawValue)
                if ImGuiTabItemButton("+", addTabFlags) {
                    engine.tabManager.newTab()
                    engine.zoomExtents()
                }
                if ImGuiIsItemHovered(0) {
                    ImGuiBeginTooltip()
#if os(macOS)
                    ImGuiTextV("Cmd+N to create a new drawing")
#else
                    ImGuiTextV("Ctrl+N to create a new drawing")
#endif
                    ImGuiEndTooltip()
                }

                ImGuiEndTabBar()
            }
        }
        igEnd()

        ImGuiPopStyleVar(4)
        ImGuiPopStyleColor(1)

        if let index = requestedCloseIndex {
            _ = engine.tabManager.requestCloseTab(at: index)
        }

        // Modal popup for unsaved changes when closing a dirty tab.
        if _tabCloseDirty {
            _tabCloseDirty = false
            ImGuiOpenPopup("Unsaved Changes##TabClose", Int32(ImGuiPopupFlags_None.rawValue))
        }

        let io = ImGuiGetIO()!.pointee
        let uiScale = max(0.75, engine.effectiveUiScale)
        let popupW = min(460.0 * uiScale, max(180.0, dw - 32.0 * uiScale))
        let popupMinH = min(160.0 * uiScale, max(120.0, io.DisplaySize.y - 48.0 * uiScale))
        let popupMaxH = max(popupMinH, io.DisplaySize.y - 48.0 * uiScale)
        ImGuiSetNextWindowPos(
            ImVec2(x: dw * 0.5, y: io.DisplaySize.y * 0.5),
            Int32(ImGuiCond_Appearing.rawValue),
            ImVec2(x: 0.5, y: 0.5))
        ImGuiSetNextWindowSize(
            ImVec2(x: popupW, y: popupMinH),
            Int32(ImGuiCond_Appearing.rawValue))
        ImGuiSetNextWindowSizeConstraints(
            ImVec2(x: popupW, y: popupMinH),
            ImVec2(x: popupW, y: popupMaxH),
            { _ in },
            nil)

        var closePopup = true
        if ImGuiBeginPopupModal("Unsaved Changes##TabClose", &closePopup,
                                Int32(ImGuiWindowFlags_NoSavedSettings.rawValue
                                    | ImGuiWindowFlags_AlwaysAutoResize.rawValue)) {
            defer { ImGuiEndPopup() }

            if !closePopup {
                _tabClosePending = -1
                _tabCloseDirty = false
                return
            }

            let tabName = (_tabClosePending >= 0 && _tabClosePending < engine.tabManager.tabs.count)
                ? engine.tabManager.tabs[_tabClosePending].displayName : ""
            ImGuiTextWrappedV("Save changes to \"\(tabName)\" before closing?")

            igSeparator()
            let buttonGap = 8.0 * uiScale
            let buttonH = max(ImGuiGetFrameHeight(), 36.0 * uiScale)
            ImGuiDummy(ImVec2(x: 0, y: 4.0 * uiScale))
            let buttonW = max(72.0 * uiScale, (ImGuiGetContentRegionAvail().x - buttonGap * 2.0) / 3.0)

            if igButton("Save", ImVec2(x: buttonW, y: buttonH)) {
                do {
                    try engine.tabManager.saveActiveTab()
                    engine.tabManager.closeTab(at: _tabClosePending)
                } catch let error as TabManager.TabError {
                    print("Save failed (no file URL): \(error)")
                    engine.tabManager.closeTab(at: _tabClosePending)
                } catch {
                    print("Save failed: \(error)")
                    engine.tabManager.closeTab(at: _tabClosePending)
                }
                _tabClosePending = -1
                ImGuiCloseCurrentPopup()
            }
            ImGuiSameLine(0, buttonGap)
            if igButton("Discard", ImVec2(x: buttonW, y: buttonH)) {
                engine.tabManager.closeTab(at: _tabClosePending)
                _tabClosePending = -1
                ImGuiCloseCurrentPopup()
            }
            ImGuiSameLine(0, buttonGap)
            if igButton("Cancel", ImVec2(x: buttonW, y: buttonH)) {
                _tabClosePending = -1
                ImGuiCloseCurrentPopup()
            }
        }
    }
}
