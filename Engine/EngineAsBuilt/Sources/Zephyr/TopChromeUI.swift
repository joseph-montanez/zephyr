import ZephyrCore
import Foundation
import ImGui
import SwiftSDL

// MARK: - TopChromeUI
//
// Renders the custom window title bar (header) at the very top of the window.
// Includes macOS-style Close (Red), Minimize (Yellow), and Maximize (Green) window controls
// that trigger native SDL window actions.
//
@MainActor
struct TopChromeUI {
    static func render(engine: PhrostEngine, dw: Float) {
        let topChromeH = AppLayout.topChromeHeight
        let flags: Int32 = 
            Int32(ImGuiWindowFlags_NoTitleBar.rawValue) |
            Int32(ImGuiWindowFlags_NoResize.rawValue) |
            Int32(ImGuiWindowFlags_NoMove.rawValue) |
            Int32(ImGuiWindowFlags_NoScrollbar.rawValue) |
            Int32(ImGuiWindowFlags_NoSavedSettings.rawValue) |
            Int32(ImGuiWindowFlags_NoBringToFrontOnFocus.rawValue) |
            Int32(ImGuiWindowFlags_NoNavFocus.rawValue)

        ImGuiSetNextWindowPos(ImVec2(x: 0, y: 0), Int32(ImGuiCond_Always.rawValue), ImVec2(x: 0, y: 0))
        ImGuiSetNextWindowSize(ImVec2(x: dw, y: topChromeH), Int32(ImGuiCond_Always.rawValue))

        ImGuiPushStyleVarX(Int32(ImGuiStyleVar_WindowPadding.rawValue), 0)
        ImGuiPushStyleVarY(Int32(ImGuiStyleVar_WindowPadding.rawValue), 0)
        ImGuiPushStyleVar(Int32(ImGuiStyleVar_WindowBorderSize.rawValue), Float(0.0))
        ImGuiPushStyleColor(Int32(ImGuiCol_WindowBg.rawValue), engine.ui.theme.topChromeBg)

        var opened = true
        if igBegin("##TopChrome", &opened, flags) {
            let drawList = igGetWindowDrawList()
            let centerY = topChromeH * 0.5

            #if os(Windows)
            // --- Windows Style Window Controls on the Right ---
            let btnWidth: Float = 46.0
            let btnHeight: Float = topChromeH
            
            // Minimize Button
            let minBtnX = dw - btnWidth * 3
            ImGuiSetCursorScreenPos(ImVec2(x: minBtnX, y: 0))
            if igInvisibleButton("##MinBtn", ImVec2(x: btnWidth, y: btnHeight), 0) {
                SDL_MinimizeWindow(engine.window)
            }
            let minHovered = ImGuiIsItemHovered(0)
            
            // Maximize Button
            let maxBtnX = dw - btnWidth * 2
            ImGuiSetCursorScreenPos(ImVec2(x: maxBtnX, y: 0))
            if igInvisibleButton("##MaxBtn", ImVec2(x: btnWidth, y: btnHeight), 0) {
                let winFlags = SDL_GetWindowFlags(engine.window)
                let isMaximized = (winFlags & 0x0000_0000_0000_0080) != 0
                if isMaximized {
                    SDL_RestoreWindow(engine.window)
                } else {
                    SDL_MaximizeWindow(engine.window)
                }
            }
            let maxHovered = ImGuiIsItemHovered(0)
            
            // Close Button
            let closeBtnX = dw - btnWidth
            ImGuiSetCursorScreenPos(ImVec2(x: closeBtnX, y: 0))
            if igInvisibleButton("##CloseBtn", ImVec2(x: btnWidth, y: btnHeight), 0) {
                engine.stop()
            }
            let closeHovered = ImGuiIsItemHovered(0)

            // --- Custom Windows Icons & Background Drawings ---
            let winFlags = SDL_GetWindowFlags(engine.window)
            let isMaximized = (winFlags & 0x0000_0000_0000_0080) != 0
            
            let iconCol = igGetColorU32_Vec4(engine.ui.theme.textIcon)
            let hoverBgCol = igGetColorU32_Vec4(engine.ui.theme.hoverBg)
            let closeHoverBgCol = igGetColorU32_Vec4(engine.ui.theme.dangerBg)
            
            // Minimize
            if minHovered {
                ImDrawListAddRectFilled(drawList, ImVec2(x: minBtnX, y: 0), ImVec2(x: minBtnX + btnWidth, y: btnHeight), hoverBgCol, 0.0, 0)
            }
            let minLineY = centerY
            ImDrawListAddLine(drawList, ImVec2(x: minBtnX + 18, y: minLineY), ImVec2(x: minBtnX + 28, y: minLineY), iconCol, 1.0)
            
            // Maximize / Restore
            if maxHovered {
                ImDrawListAddRectFilled(drawList, ImVec2(x: maxBtnX, y: 0), ImVec2(x: maxBtnX + btnWidth, y: btnHeight), hoverBgCol, 0.0, 0)
            }
            if isMaximized {
                // Restore icon (two overlapping squares)
                ImDrawListAddRect(drawList, ImVec2(x: maxBtnX + 20, y: centerY - 5), ImVec2(x: maxBtnX + 28, y: centerY + 3), iconCol, 0.0, 1.0, 0)
                ImDrawListAddRectFilled(drawList, ImVec2(x: maxBtnX + 17, y: centerY - 2), ImVec2(x: maxBtnX + 25, y: centerY + 6), igGetColorU32_Vec4(engine.ui.theme.topChromeBg), 0.0, 0) // clear background of main square
                ImDrawListAddRect(drawList, ImVec2(x: maxBtnX + 17, y: centerY - 2), ImVec2(x: maxBtnX + 25, y: centerY + 6), iconCol, 0.0, 1.0, 0)
            } else {
                // Maximize icon (single square)
                ImDrawListAddRect(drawList, ImVec2(x: maxBtnX + 18, y: centerY - 5), ImVec2(x: maxBtnX + 28, y: centerY + 5), iconCol, 0.0, 1.0, 0)
            }
            
            // Close
            if closeHovered {
                ImDrawListAddRectFilled(drawList, ImVec2(x: closeBtnX, y: 0), ImVec2(x: closeBtnX + btnWidth, y: btnHeight), closeHoverBgCol, 0.0, 0)
            }
            // Close icon (X)
            let iconSize: Float = 5.0
            ImDrawListAddLine(drawList, ImVec2(x: closeBtnX + 23 - iconSize, y: centerY - iconSize), ImVec2(x: closeBtnX + 23 + iconSize, y: centerY + iconSize), iconCol, 1.0)
            ImDrawListAddLine(drawList, ImVec2(x: closeBtnX + 23 - iconSize, y: centerY + iconSize), ImVec2(x: closeBtnX + 23 + iconSize, y: centerY - iconSize), iconCol, 1.0)

            #else
            // --- macOS Style window controls on the Left ---
            let circleRadius: Float = 8.0
            let spacing: Float = 24.0
            let startX: Float = 18.0

            let redCol = igGetColorU32_Vec4(engine.ui.theme.macClose) // #FF5F56
            let redHover = igGetColorU32_Vec4(engine.ui.theme.macCloseHover)
            let yellowCol = igGetColorU32_Vec4(engine.ui.theme.macMin) // #FFBD2E
            let yellowHover = igGetColorU32_Vec4(engine.ui.theme.macMinHover)
            let greenCol = igGetColorU32_Vec4(engine.ui.theme.macMax) // #27C93F
            let greenHover = igGetColorU32_Vec4(engine.ui.theme.macMaxHover)

            // Close
            ImGuiSetCursorScreenPos(ImVec2(x: startX - circleRadius - 4, y: centerY - circleRadius - 4))
            if igInvisibleButton("##CloseBtn", ImVec2(x: circleRadius * 2 + 8, y: circleRadius * 2 + 8), 0) {
                engine.stop()
            }
            let closeHovered = ImGuiIsItemHovered(0)

            // Minimize
            ImGuiSetCursorScreenPos(ImVec2(x: startX + spacing - circleRadius - 4, y: centerY - circleRadius - 4))
            if igInvisibleButton("##MinBtn", ImVec2(x: circleRadius * 2 + 8, y: circleRadius * 2 + 8), 0) {
                SDL_MinimizeWindow(engine.window)
            }
            let minHovered = ImGuiIsItemHovered(0)

            // Maximize / Restore
            ImGuiSetCursorScreenPos(ImVec2(x: startX + spacing * 2 - circleRadius - 4, y: centerY - circleRadius - 4))
            if igInvisibleButton("##MaxBtn", ImVec2(x: circleRadius * 2 + 8, y: circleRadius * 2 + 8), 0) {
                let winFlags = SDL_GetWindowFlags(engine.window)
                let isMaximized = (winFlags & 0x0000_0000_0000_0080) != 0 // SDL_WINDOW_MAXIMIZED
                if isMaximized {
                    SDL_RestoreWindow(engine.window)
                } else {
                    SDL_MaximizeWindow(engine.window)
                }
            }
            let maxHovered = ImGuiIsItemHovered(0)

            ImDrawListAddCircleFilled(drawList, ImVec2(x: startX, y: centerY), circleRadius, closeHovered ? redHover : redCol, 12)
            ImDrawListAddCircleFilled(drawList, ImVec2(x: startX + spacing, y: centerY), circleRadius, minHovered ? yellowHover : yellowCol, 12)
            ImDrawListAddCircleFilled(drawList, ImVec2(x: startX + spacing * 2, y: centerY), circleRadius, maxHovered ? greenHover : greenCol, 12)
            #endif

            // --- Window Title Text (Centered) ---
            let activeTabName = engine.tabManager.activeTab?.displayName ?? "Untitled"
            let title = "Zephyr — \(activeTabName)"
            let textSize = ImGuiCalcTextSize(title, nil, false, -1)
            
            let textX = (dw - textSize.x) * 0.5
            let textY = (topChromeH - textSize.y) * 0.5
            
            ImGuiSetCursorScreenPos(ImVec2(x: textX, y: textY))
            ImGuiPushStyleColor(Int32(ImGuiCol_Text.rawValue), engine.ui.theme.textDim)
            ImGuiTextV(title)
            // --- FPS Display ---
            if engine.ui.showFPS {
                let io = ImGuiGetIO()
                engine._fpsCacheFrame += 1
                if engine._fpsCacheFrame >= engine.ui.fpsCacheFrame {
                    engine._fpsCacheFrame = 0
                    engine._cachedFpsText = String(format: "FPS: %.0f", io?.pointee.Framerate ?? 0)
                }

                let fpsTextSize = ImGuiCalcTextSize(engine._cachedFpsText, nil, false, -1)
                let fpsY = (topChromeH - fpsTextSize.y) * 0.5
                
                #if os(Windows)
                let fpsX: Float = 16.0
                #else
                let fpsX = dw - fpsTextSize.x - 16.0
                #endif
                
                ImGuiSetCursorScreenPos(ImVec2(x: fpsX, y: fpsY))
                ImGuiTextV(engine._cachedFpsText)
            }

            ImGuiPopStyleColor(1)
        }
        igEnd()

        ImGuiPopStyleVar(3)
        ImGuiPopStyleColor(1)
    }
}
