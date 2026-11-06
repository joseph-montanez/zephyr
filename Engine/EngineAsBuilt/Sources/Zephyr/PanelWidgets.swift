import Foundation
import ImGui
import ZephyrCore

// Flow-layout icon widgets for docked panels. The ribbon widgets take
// absolute rects; panels use the ImGui cursor, so these draw from the
// item rect instead while matching the ribbon's hover/active/checked
// treatment and procedural icons from `RibbonIconPainter`.

@MainActor
enum PanelWidgets {

    /// Square icon-only button with a tooltip. Returns true on click.
    @discardableResult
    static func iconButton(
        id: String,
        icon: String,
        tooltip: String,
        theme: AppTheme,
        size: Float,
        enabled: Bool = true,
        checked: Bool = false,
        danger: Bool = false
    ) -> Bool {
        let drawList = ImGuiGetWindowDrawList()
        if !enabled { ImGuiBeginDisabled(true) }
        let clicked = igInvisibleButton(
            "##\(id)", ImVec2(x: size, y: size), 0)
        if !enabled { ImGuiEndDisabled() }
        let hovered = ImGuiIsItemHovered(0)
        let active = ImGuiIsItemActive()
        let min = ImGuiGetItemRectMin()
        let max = ImGuiGetItemRectMax()

        if checked {
            ImDrawListAddRectFilled(
                drawList, min, max,
                igGetColorU32_Vec4(withAlpha(theme.brandGold, 0.28)), 4, 0)
        } else if hovered && enabled {
            ImDrawListAddRectFilled(
                drawList, min, max,
                igGetColorU32_Vec4(danger ? theme.dangerBg : theme.hoverBg),
                4, 0)
        } else {
            ImDrawListAddRectFilled(
                drawList, min, max,
                igGetColorU32_Vec4(theme.buttonBg), 4, 0)
        }
        if active && enabled {
            ImDrawListAddRect(
                drawList, min, max,
                igGetColorU32_Vec4(withAlpha(theme.brandGold, 0.65)),
                4, 1.0, 0)
        }

        let iconSize = size * 0.62
        let iconColor = checked
            ? theme.brandGold
            : (enabled ? theme.textPrimary : dim(theme.textDim))
        RibbonIconPainter.draw(
            name: icon, drawList: drawList,
            rect: RibbonRect(
                x: min.x + (size - iconSize) * 0.5,
                y: min.y + (size - iconSize) * 0.5,
                width: iconSize, height: iconSize),
            color: iconColor, fallbackText: tooltip)

        if hovered, !tooltip.isEmpty {
            ImGuiBeginTooltip()
            ImGuiTextV(tooltip)
            ImGuiEndTooltip()
        }
        return clicked && enabled
    }

    /// Fitting width for `labelButton`, for reserving space in a row.
    static func labelButtonWidth(
        icon: String?, label: String, size: Float, chevron: Bool
    ) -> Float {
        let pad: Float = 8
        var width = pad
            + ImGuiCalcTextSize(label, nil, false, -1).x + pad
        if icon != nil { width += size * 0.58 + 6 }
        if chevron { width += 12 }
        return width
    }

    /// Icon + label button, optionally with a dropdown chevron.
    /// Height matches `size`; width fits the content.
    @discardableResult
    static func labelButton(
        id: String,
        icon: String?,
        label: String,
        tooltip: String = "",
        theme: AppTheme,
        size: Float,
        enabled: Bool = true,
        checked: Bool = false,
        chevron: Bool = false
    ) -> Bool {
        let drawList = ImGuiGetWindowDrawList()
        let pad: Float = 8
        let iconSize = size * 0.58
        let width = labelButtonWidth(
            icon: icon, label: label, size: size, chevron: chevron)

        if !enabled { ImGuiBeginDisabled(true) }
        let clicked = igInvisibleButton(
            "##\(id)", ImVec2(x: width, y: size), 0)
        if !enabled { ImGuiEndDisabled() }
        let hovered = ImGuiIsItemHovered(0)
        let active = ImGuiIsItemActive()
        let min = ImGuiGetItemRectMin()
        let max = ImGuiGetItemRectMax()

        if checked {
            ImDrawListAddRectFilled(
                drawList, min, max,
                igGetColorU32_Vec4(withAlpha(theme.brandGold, 0.28)), 4, 0)
        } else if hovered && enabled {
            ImDrawListAddRectFilled(
                drawList, min, max,
                igGetColorU32_Vec4(theme.hoverBg), 4, 0)
        } else {
            ImDrawListAddRectFilled(
                drawList, min, max,
                igGetColorU32_Vec4(theme.buttonBg), 4, 0)
        }
        if active && enabled {
            ImDrawListAddRect(
                drawList, min, max,
                igGetColorU32_Vec4(withAlpha(theme.brandGold, 0.65)),
                4, 1.0, 0)
        }

        let textColor = enabled ? theme.textPrimary : dim(theme.textDim)
        let iconColor = checked ? theme.brandGold : textColor
        var x = min.x + pad
        if let icon {
            RibbonIconPainter.draw(
                name: icon, drawList: drawList,
                rect: RibbonRect(
                    x: x, y: min.y + (size - iconSize) * 0.5,
                    width: iconSize, height: iconSize),
                color: iconColor, fallbackText: label)
            x += iconSize + 6
        }
        let textH = ImGuiCalcTextSize(label, nil, false, -1).y
        ImDrawListAddText(
            drawList,
            ImVec2(x: x, y: min.y + (size - textH) * 0.5),
            igGetColorU32_Vec4(textColor), label)
        if chevron {
            let cx = max.x - 9
            let cy = min.y + size * 0.5
            ImDrawListAddTriangleFilled(
                drawList,
                ImVec2(x: cx - 3, y: cy - 1.5),
                ImVec2(x: cx + 3, y: cy - 1.5),
                ImVec2(x: cx, y: cy + 2.5),
                igGetColorU32_Vec4(textColor))
        }

        if hovered, !tooltip.isEmpty {
            ImGuiBeginTooltip()
            ImGuiTextV(tooltip)
            ImGuiEndTooltip()
        }
        return clicked && enabled
    }

    /// Flow helper: call before every item after the first in a
    /// wrapping row. Stays on the line when the item fits, otherwise
    /// wraps to the panel's left indent.
    static func flow(itemWidth: Float, gap: Float = 4) {
        if ImGuiGetContentRegionAvail().x >= itemWidth {
            ImGuiSameLine(0, gap)
        } else {
            ImGuiSetCursorPosX(6)
        }
    }

    /// Draw a small icon centered at a point (row indicators, markers).
    static func drawIcon(
        _ name: String,
        drawList: UnsafeMutablePointer<ImDrawList>?,
        center: ImVec2,
        size: Float,
        color: ImVec4
    ) {
        RibbonIconPainter.draw(
            name: name, drawList: drawList,
            rect: RibbonRect(
                x: center.x - size * 0.5, y: center.y - size * 0.5,
                width: size, height: size),
            color: color, fallbackText: "")
    }

    /// Filled sort/dropdown triangle (font glyphs for these are missing).
    static func drawTriangle(
        drawList: UnsafeMutablePointer<ImDrawList>?,
        center: ImVec2,
        halfWidth: Float,
        pointingDown: Bool,
        color: ImVec4
    ) {
        let h = halfWidth * 1.1
        let u = igGetColorU32_Vec4(color)
        if pointingDown {
            ImDrawListAddTriangleFilled(
                drawList,
                ImVec2(x: center.x - halfWidth, y: center.y - h * 0.5),
                ImVec2(x: center.x + halfWidth, y: center.y - h * 0.5),
                ImVec2(x: center.x, y: center.y + h * 0.5), u)
        } else {
            ImDrawListAddTriangleFilled(
                drawList,
                ImVec2(x: center.x, y: center.y - h * 0.5),
                ImVec2(x: center.x + halfWidth, y: center.y + h * 0.5),
                ImVec2(x: center.x - halfWidth, y: center.y + h * 0.5), u)
        }
    }

    static func withAlpha(_ color: ImVec4, _ alpha: Float) -> ImVec4 {
        ImVec4(x: color.x, y: color.y, z: color.z, w: alpha)
    }

    private static func dim(_ color: ImVec4) -> ImVec4 {
        ImVec4(
            x: color.x, y: color.y, z: color.z, w: color.w * 0.45)
    }
}
