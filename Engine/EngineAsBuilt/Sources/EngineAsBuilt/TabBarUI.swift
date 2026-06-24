import EngineAsBuiltCore
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
                    let isDirty = tab.document.isDirty
                    let label = isDirty ? "\(tab.displayName)*" : tab.displayName

                    var tabFlags: Int32 = 0
                    if isActive && shouldForceSelection {
                        tabFlags |= Int32(ImGuiTabItemFlags_SetSelected.rawValue)
                    }
                    if isDirty {
                        tabFlags |= Int32(ImGuiTabItemFlags_UnsavedDocument.rawValue)
                    }

                    if isActive, let boldFont = engine.ui.boldFont {
                        ImGuiPushFont(boldFont, ImGuiGetFontSize())
                    }
                    
                    let tabVisible = ImGuiBeginTabItem("\(label)###Tab_\(tab.id.uuidString)", nil, tabFlags)
                    
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


                }

                // Add the '+' button at the trailing end
                let addTabFlags = Int32(ImGuiTabItemFlags_Trailing.rawValue | ImGuiTabItemFlags_NoTooltip.rawValue)
                if ImGuiTabItemButton("+", addTabFlags) {
                    engine.tabManager.newTab()
                    engine.zoomExtents()
                }
                if ImGuiIsItemHovered(0) {
                    ImGuiBeginTooltip()
                    ImGuiTextV("Ctrl+N to create a new drawing")
                    ImGuiEndTooltip()
                }

                ImGuiEndTabBar()
            }
        }
        igEnd()

        ImGuiPopStyleVar(4)
        ImGuiPopStyleColor(1)

        // Modal popup for unsaved changes when closing a dirty tab.
        if _tabCloseDirty {
            _tabCloseDirty = false
            ImGuiOpenPopup("Unsaved Changes##TabClose", Int32(ImGuiPopupFlags_None.rawValue))
        }

        let popupW: Float = 320
        let popupH: Float = 100
        ImGuiSetNextWindowPos(
            ImVec2(x: (dw - popupW) * 0.5, y: 150),
            Int32(ImGuiCond_Appearing.rawValue),
            ImVec2(x: 0, y: 0))
        ImGuiSetNextWindowSize(ImVec2(x: popupW, y: popupH), Int32(ImGuiCond_Appearing.rawValue))

        var closePopup = true
        if ImGuiBeginPopupModal("Unsaved Changes##TabClose", &closePopup,
                                Int32(ImGuiWindowFlags_NoSavedSettings.rawValue)) {
            defer { ImGuiEndPopup() }

            if !closePopup {
                _tabClosePending = -1
                _tabCloseDirty = false
                return
            }

            let tabName = (_tabClosePending >= 0 && _tabClosePending < engine.tabManager.tabs.count)
                ? engine.tabManager.tabs[_tabClosePending].displayName : ""
            ImGuiTextV("Save changes to \"\(tabName)\" before closing?")

            igSeparator()

            if igSmallButton("Save") {
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
            ImGuiSameLine(0, 8)
            if igSmallButton("Discard") {
                engine.tabManager.closeTab(at: _tabClosePending)
                _tabClosePending = -1
                ImGuiCloseCurrentPopup()
            }
            ImGuiSameLine(0, 8)
            if igSmallButton("Cancel") {
                _tabClosePending = -1
                ImGuiCloseCurrentPopup()
            }
        }
    }
}
