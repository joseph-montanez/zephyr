import EngineAsBuiltCore
import Foundation
import ImGui

// MARK: - CommandAutocompleteUI
//
// Renders the autocomplete popup that appears above the command line
// when the user types a partial command name. This UI is displayed inside
// the ##CmdPalette child window, managed by CommandLineUI.
//
// ## Layout Structure
//
// The popup is divided into three vertical regions:
//
//    ┌──────────────────────────────────────────┐
//    │  COMMAND PALETTE       14 cmd · 6 cat    │  ← Header
//    ├──────────────────────────────────────────┤
//    │  01  DRAW  ─────────────────────  15     │  ← Category header
//    │  LINE        Line segment by 2 pts  [L]  │  ← Item
//    │  02  MODIFY  ───────────────────  8      │
//    │  MOVE        Move entities               │
//    │  ...                                     │
//    ├──────────────────────────────────────────┤
//    │  ↑↓ nav  ↵ run  Tab  esc dismiss         │  ← Footer
//    │         space to invoke · fuzzy          │
//    └──────────────────────────────────────────┘
//
// ## Item Layout
//
// Each command item row is two lines tall:
//   - Line 1: Canonical command name in the title font (gold if selected/hovered)
//   - Line 2: Description text in small font (dimmed)
//
// A pill showing the command's primary shortcut is drawn at the right edge
// (e.g. LINE shows [L], and LAYERMOVE shows [LM]).
//
// ## Selection Rendering
//
// The currently highlighted index (`clampedIndex`) gets:
//   - A warm tinted background rectangle (`commandRowHighlight` from the theme)
//   - A 3 px gold accent rail on the left
//   - Gold-colored text for the command name
//   - Automatic scroll-into-view via `igSetScrollHereY`
//
// ## Sizing Algorithm
//
// The child popup height is computed manually rather than relying on
// ImGui's auto-sizing because the content uses manual cursor positioning
// (`igSetCursorScreenPos`) for the item layout, which confuses the
// auto-size calculation. The algorithm:
//
//   1. Count distinct categories and total item rows
//   2. Estimate: itemsHeight + headerHeights + titleHeight
//   3. Clamp to 60% of display height (minus input window and footer)
//   4. Pass the computed `childHeight` to `igBeginChild_Str`
//
// ## Keyboard Navigation
//
// Navigation keys are handled by `CommandLineUI.updateSelection`, which
// updates `engine.commandProcessor.commandSelectionIndex`. This index is
// clamped into `clampedIndex` by the caller and passed here for rendering.
//
// ## THEME Command
//
// The "THEME" command receives special rendering: in addition to the command
// name and description, two inline buttons ("DARK" and "LIGHT") are drawn
// alongside the name. The active theme pill is highlighted in gold. This
// allows quick theme toggling directly from the palette without leaving
// the command line.

/// Renders autocomplete suggestions and empty-state UI for the command palette.
///
/// This struct is fully static — it holds no mutable state other than the
/// private `lastClampedIndex` cache used to detect selection changes for
/// scroll-to-selection behavior.
///
/// ## Usage
///
/// Called from `CommandLineUI.render(engine:dw:dh:)` inside the
/// `##CmdPalette` child window:
///
/// ```swift
/// if !inputMatches.isEmpty {
///     CommandAutocompleteUI.renderMatches(
///         engine: engine,
///         matches: inputMatches,
///         clampedIndex: clampedIndex,
///         cmdW: cmdW
///     )
/// } else {
///     CommandAutocompleteUI.renderNoMatches(engine: engine, cmdW: cmdW)
/// }
/// ```
///
/// ## Topics
/// - ``renderMatches(engine:matches:clampedIndex:cmdW:)``
/// - ``renderNoMatches(engine:cmdW:)``
@MainActor
struct CommandAutocompleteUI {

    // MARK: - Internal State

    /// Tracks the previous frame's clamped selection index so the renderer
    /// can detect when the user moves the highlight and trigger a
    /// `igSetScrollHereY` call to keep the selected item visible.
    ///
    /// Reset to `-1` at startup so the very first selection always scrolls.
    private static var lastClampedIndex: Int = -1

    // MARK: - Rendering

    /// Renders the autocomplete popup with matching commands grouped by category.
    ///
    /// This method draws three sections inside the current child window:
    /// 1. **Header** — "COMMAND PALETTE" title and a right-aligned stats line
    ///    showing match count and category count.
    /// 2. **Item list** — Category group headers followed by individual command
    ///    rows. Items are interactive: clicking or pressing Enter on a
    ///    highlighted item executes the command.
    /// 3. **Footer** — Keyboard shortcut hints (arrows, Enter, Tab, Esc, Space).
    ///
    /// - Parameters:
    ///   - engine: The engine instance providing access to the theme, fonts,
    ///     and `commandProcessor` for command execution.
    ///   - matches: Ordered list of `(CommandDescriptor, matchingAlias)` pairs
    ///     produced by `CADCommandProcessor.matchCommands(input:)`. The list
    ///     is pre-sorted: first by category order (Draw → Modify → View →
    ///     Layer → Block → Settings), then alphabetically within each category.
    ///   - clampedIndex: Zero-based index of the currently highlighted item,
    ///     already clamped to `0..<matches.count`. Pass `0` when there are
    ///     no matches.
    ///   - cmdW: The fixed width of the command palette window (1000 px on
    ///     a typical 1920-wide display). Used to right-align the stats line,
    ///     category count, and alias pill within the popup.
    ///
    /// ## Selection Behavior
    ///
    /// When the user clicks a selectable row or presses Enter while an item
    /// is highlighted:
    /// - The command line is dismissed (`commandLineActive = false`).
    /// - The canonical command name is executed via
    ///   `engine.commandProcessor.executeCommand(canonical)`.
    ///
    /// The selection highlight uses ImGui's `Selectable` widget with
    /// `AllowOverlap` to create a full-row background rectangle, while the
    /// actual text and alias pill are drawn on top using manual cursor
    /// positioning.
    ///
    /// ## Scroll Behavior
    ///
    /// When `clampedIndex` changes (detected by comparing against
    /// `lastClampedIndex`), `igSetScrollHereY(0.5)` is called on the
    /// selected item to center it vertically in the scroll region.
    ///
    /// ## THEME Special Case
    ///
    /// The command with canonical name `"THEME"` receives special inline
    /// rendering: two small `ImGuiButton` pills ("DARK" / "LIGHT") are
    /// drawn to the right of the command name. The currently active theme's
    /// pill is highlighted in gold (`brandGold`), and clicking either pill
    /// toggles the theme via the selectable row's click handler.
    ///
    /// - Note: This method must be called inside an active ImGui child window
    ///   created with `igBeginChild_Str`. It calls `igEndChild()` internally
    ///   and renders the footer **outside** the child.
    @MainActor
    static func renderMatches(
        engine: PhrostEngine,
        matches: [(descriptor: CommandDescriptor, matchingAlias: String)],
        clampedIndex: Int,
        cmdW: Float
    ) {
        // ---- Layout constants ----
        // These are derived from the current ImGui style and font metrics
        // to produce consistent spacing regardless of DPI or theme changes.
        let style = ImGuiGetStyle()
        let spacingY = style?.pointee.ItemSpacing.y ?? 4.0
        let rowH = ImGuiGetTextLineHeightWithSpacing()
        let descRowH = ImGuiGetTextLineHeight() + spacingY

        // Detect selection change to trigger scroll-to-selection on the
        // next frame's draw. We must check *before* updating lastClampedIndex.
        var scrollToSelection = false
        if clampedIndex != lastClampedIndex {
            scrollToSelection = true
            lastClampedIndex = clampedIndex
        }

        let visibleCount = matches.count
        var lastCategory: CommandCategory? = nil
        var categoryIndex = 1

        let popupFlags = Int32(ImGuiWindowFlags_None.rawValue)

        // Add breathing room before the first category header.
        ImGuiDummy(ImVec2(x: 0, y: 8))

        // ---- Height estimation ----
        // ImGui auto-sizing can't handle the manual cursor positioning we use
        // for the two-line item layout, so we pre-compute the child height.
        let io = ImGuiGetIO()
        let dh = io?.pointee.DisplaySize.y ?? 1080.0

        let categories = Set(matches.map { $0.descriptor.category }).count
        let itemsHeight = Float(matches.count) * (rowH + descRowH + spacingY)
        let headerHeight = Float(categories) * (descRowH + 16.0)
        let titleHeight = descRowH + 16.0
        let footerHeight: Float = 40.0
        // Reserve space for the input window above (approx 100px) and the footer.
        let maxChildHeight = (dh * 0.6) - 100.0 - footerHeight
        let estimatedHeight = itemsHeight + headerHeight + titleHeight

        let childHeight = min(estimatedHeight, maxChildHeight)

        // ---- Child region: scrollable list ----
        // Push zero padding so the selectable/hover background fills the
        // full child width. Text is manually offset by itemPadX below.
        let itemPadX: Float = 16.0
        ImGuiPushStyleVarX(Int32(ImGuiStyleVar_WindowPadding.rawValue), 0)
        ImGuiPushStyleVarY(Int32(ImGuiStyleVar_WindowPadding.rawValue), 0)
        if igBeginChild_Str("##CmdAutoComplete", ImVec2(x: 0, y: childHeight), 0, popupFlags) {
            let drawList = igGetWindowDrawList()
            let listWidth = ImGuiGetContentRegionAvail().x

            // ================================================================
            // SECTION 1 — Header
            // ================================================================
            // Two lines:
            //   Left:  "COMMAND PALETTE" in small font, dimmed
            //   Right: "N commands · M categories" in small font, dimmed
            if let smallFont = engine.ui.smallFont { ImGuiPushFont(smallFont, 0.0) }
            ImGuiPushStyleColor(Int32(ImGuiCol_Text.rawValue), engine.ui.theme.textDim)
            ImGuiTextV("COMMAND PALETTE")

            let stats = "\(matches.count) commands · \(categories) categories"
            let statsW = ImGuiCalcTextSize(stats, nil, false, -1).x
            ImGuiSameLine(listWidth - statsW - 16, 0)
            ImGuiTextV(stats)
            ImGuiPopStyleColor(1)
            if engine.ui.smallFont != nil { ImGuiPopFont() }

            // Spacer between header and first category.
            ImGuiDummy(ImVec2(x: 0, y: 16))

            // ================================================================
            // SECTION 2 — Category Groups + Command Items
            // ================================================================
            for i in 0..<visibleCount {
                let m = matches[i]
                let isSelected = i == clampedIndex

                // - - - - - - - - - - - - - - - - - - - - - - - - - - - -
                // Category Header
                // - - - - - - - - - - - - - - - - - - - - - - - - - - - -
                // Rendered when the category changes between consecutive
                // items. Each header shows:
                //   "01  DRAW  ──────────────────────────── 15"
                //    ^    ^       horizontal rule            ^
                //    |    |                                  |
                //  number  name (uppercased)        total commands in category
                if m.descriptor.category != lastCategory {
                    let cNum = String(format: "%02d", categoryIndex)
                    let cName = m.descriptor.category.rawValue.uppercased()
                    categoryIndex += 1
                    lastCategory = m.descriptor.category

                    // Offset cursor for text padding (aligns with command item text).
                    let catBaseX = igGetCursorScreenPos().x
                    let catTextY = igGetCursorScreenPos().y
                    igSetCursorScreenPos(ImVec2(x: catBaseX + itemPadX, y: catTextY))

                    // Category number in gold.
                    if let small = engine.ui.smallFont { ImGuiPushFont(small, 0.0) }

                    ImGuiPushStyleColor(Int32(ImGuiCol_Text.rawValue), engine.ui.theme.brandGold)
                    ImGuiTextV(cNum)
                    ImGuiPopStyleColor(1)

                    // Category name.
                    ImGuiSameLine(0, 8)
                    ImGuiPushStyleColor(Int32(ImGuiCol_Text.rawValue), engine.ui.theme.textDim)
                    ImGuiTextV(cName)

                    // Count of all registered commands in this category
                    // (not just filtered matches), right-aligned.
                    let catCount = CommandDescriptor.allCommands.filter { $0.category == m.descriptor.category }.count
                    let cText = "\(catCount)"
                    let numW = ImGuiCalcTextSize(cText, nil, false, -1).x
                    let categoryNumberW = ImGuiCalcTextSize(cNum, nil, false, -1).x
                    let categoryNameW = ImGuiCalcTextSize(cName, nil, false, -1).x

                    // Horizontal rule: spans from after the category name
                    // to just before the count number. Drawn with the
                    // window draw list for a sharp 1px line.
                    let pY = catTextY + (ImGuiGetTextLineHeight() / 2.0)
                    let pStartX = catBaseX + itemPadX
                        + categoryNumberW + 8.0
                        + categoryNameW + 12.0
                    let pEndX = igGetWindowPos().x + listWidth - numW - 32.0
                    let dimCol = igGetColorU32_Vec4(engine.ui.theme.borderDim)
                    ImDrawListAddLine(drawList, ImVec2(x: pStartX, y: pY), ImVec2(x: pEndX, y: pY), dimCol, 1.0)

                    // Category total count, right-aligned.
                    ImGuiSameLine(listWidth - 16 - numW, 0)
                    ImGuiTextV(cText)
                    ImGuiPopStyleColor(1)

                    if engine.ui.smallFont != nil { ImGuiPopFont() }

                    // Restore cursor X so the selectable starts at the
                    // child's left edge (no extra padding).
                    igSetCursorScreenPos(ImVec2(x: catBaseX, y: igGetCursorScreenPos().y))

                    // Spacer between category header and first item.
                    ImGuiDummy(ImVec2(x: 0, y: 8))
                }

                // - - - - - - - - - - - - - - - - - - - - - - - - - - - -
                // Command Item
                // - - - - - - - - - - - - - - - - - - - - - - - - - - - -
                // Each item is a full-width Selectable (for click/hover
                // detection and selection highlighting) with text drawn
                // on top using manual cursor positioning.
                let shortcut = m.descriptor.aliases.first
                let canonical = m.descriptor.canonicalName

                let startPos = igGetCursorScreenPos()
                let itemAvailW = ImGuiGetContentRegionAvail().x
                let itemH = rowH + descRowH + spacingY

                // ---- Selection background (always transparent via ImGui) ----
                // The visible highlight is drawn as a manual rectangle below
                // so it can extend past the child's padding to the window border.
                if isSelected && scrollToSelection {
                    igSetScrollHereY(0.5) // Center selected item vertically.
                }
                ImGuiPushStyleColor(Int32(ImGuiCol_Header.rawValue), ImVec4(x: 0, y: 0, z: 0, w: 0))
                ImGuiPushStyleColor(Int32(ImGuiCol_HeaderHovered.rawValue), ImVec4(x: 0, y: 0, z: 0, w: 0))
                ImGuiPushStyleColor(Int32(ImGuiCol_HeaderActive.rawValue), ImVec4(x: 0, y: 0, z: 0, w: 0))

                // The selectable spans the full available width and the
                // computed two-line item height. Clicking it executes the
                // command and dismisses the command line.
                if ImGuiSelectable(
                    "##CmdItem\(i)",
                    isSelected,
                    Int32(ImGuiSelectableFlags_AllowOverlap.rawValue),
                    ImVec2(x: itemAvailW, y: itemH)
                ) {
                    engine.commandProcessor.commandLineActive = false
                    engine.commandProcessor.executeCommand(canonical)
                }

                ImGuiPopStyleColor(3)

                // ---- Click detection for the entire row ----
                // ImGuiSelectable's own click is consumed by the widget,
                // but we also check for mouse click on hover as a fallback.
                let mousePos = ImGuiGetMousePos()
                let isHovered = ImGuiIsItemHovered(0)
                    || (
                        mousePos.x >= startPos.x - itemPadX
                        && mousePos.x < startPos.x
                        && mousePos.y >= startPos.y
                        && mousePos.y < startPos.y + itemH
                    )
                let clicked = isHovered && ImGuiIsMouseClicked(ImGuiMouseButton(ImGuiMouseButton_Left.rawValue), false)
                if clicked {
                    engine.commandProcessor.commandLineActive = false
                    engine.commandProcessor.executeCommand(canonical)
                }

                // ---- Full-width highlight background ----
                // Extends left through the parent popup's padding and stops at
                // the scrollable content edge, leaving the scrollbar its own lane.
                if isSelected || isHovered {
                    let childWinPos = igGetWindowPos()
                    let bgX = childWinPos.x - itemPadX
                    let bgRight = startPos.x + itemAvailW
                    let bgCol = igGetColorU32_Vec4(engine.ui.theme.commandRowHighlight)

                    // Expand this draw operation into the popup's left padding;
                    // the child window normally clips at childWinPos.x.
                    ImDrawListPushClipRect(
                        drawList,
                        ImVec2(x: bgX, y: childWinPos.y),
                        ImVec2(
                            x: bgRight,
                            y: childWinPos.y + ImGuiGetWindowHeight()
                        ),
                        false
                    )
                    ImDrawListAddRectFilled(drawList,
                        ImVec2(x: bgX, y: startPos.y),
                        ImVec2(x: bgRight, y: startPos.y + itemH),
                        bgCol, 0, 0)
                    ImDrawListAddRectFilled(drawList,
                        ImVec2(x: bgX, y: startPos.y),
                        ImVec2(x: bgX + 3.0, y: startPos.y + itemH),
                        igGetColorU32_Vec4(engine.ui.theme.brandGold), 0, 0)
                    ImDrawListPopClipRect(drawList)
                }

                // After the selectable consumes its layout space, reset
                // the cursor to the top of the item row so we can draw
                // the text overlay.
                let endPos = igGetCursorScreenPos()
                igSetCursorScreenPos(ImVec2(x: startPos.x + itemPadX, y: startPos.y + 4))

                // ---- Command name ----
                // Drawn in the title font. Gold when selected or hovered,
                // primary text color otherwise.
                //
                // THEME is a special case: inline DARK/LIGHT pills are
                // drawn next to the name instead of the normal alias pill.
                if canonical == "THEME" {
                    if let title = engine.ui.commandTitleFont { ImGuiPushFont(title, 0.0) }
                    ImGuiPushStyleColor(Int32(ImGuiCol_Text.rawValue), (isSelected || isHovered) ? engine.ui.theme.brandGold : engine.ui.theme.textPrimary)
                    ImGuiTextV(canonical)
                    ImGuiPopStyleColor(1)
                    if engine.ui.commandTitleFont != nil { ImGuiPopFont() }

                    // ---- Inline Dark / Light theme pills ----
                    // The active theme pill uses brandGold as the button
                    // background and rowHoverText as the text color. The
                    // inactive pill is transparent with dimmed text.
                    ImGuiSameLine(0, 8)
                    let isDark = engine.ui.isDarkTheme

                    // DARK pill
                    if isDark {
                        ImGuiPushStyleColor(Int32(ImGuiCol_Text.rawValue), engine.ui.theme.rowHoverText)
                        ImGuiPushStyleColor(Int32(ImGuiCol_Button.rawValue), engine.ui.theme.brandGold)
                    } else {
                        ImGuiPushStyleColor(Int32(ImGuiCol_Text.rawValue), engine.ui.theme.textDim)
                        ImGuiPushStyleColor(Int32(ImGuiCol_Button.rawValue), ImVec4(x: 0, y: 0, z: 0, w: 0))
                    }
                    ImGuiPushStyleVarX(Int32(ImGuiStyleVar_FramePadding.rawValue), 4)
                    ImGuiPushStyleVarY(Int32(ImGuiStyleVar_FramePadding.rawValue), 0)
                    ImGuiButton("DARK", ImVec2(x: 0, y: 0))
                    ImGuiPopStyleVar(2)
                    ImGuiPopStyleColor(2)

                    ImGuiSameLine(0, 4)

                    // LIGHT pill
                    if !isDark {
                        ImGuiPushStyleColor(Int32(ImGuiCol_Text.rawValue), engine.ui.theme.rowHoverText)
                        ImGuiPushStyleColor(Int32(ImGuiCol_Button.rawValue), engine.ui.theme.brandGold)
                    } else {
                        ImGuiPushStyleColor(Int32(ImGuiCol_Text.rawValue), engine.ui.theme.textDim)
                        ImGuiPushStyleColor(Int32(ImGuiCol_Button.rawValue), ImVec4(x: 0, y: 0, z: 0, w: 0))
                    }
                    ImGuiPushStyleVarX(Int32(ImGuiStyleVar_FramePadding.rawValue), 4)
                    ImGuiPushStyleVarY(Int32(ImGuiStyleVar_FramePadding.rawValue), 0)
                    ImGuiButton("LIGHT", ImVec2(x: 0, y: 0))
                    ImGuiPopStyleVar(2)
                    ImGuiPopStyleColor(2)

                } else {
                    // Normal command: just the canonical name.
                    if let title = engine.ui.commandTitleFont { ImGuiPushFont(title, 0.0) }
                    ImGuiPushStyleColor(Int32(ImGuiCol_Text.rawValue), (isSelected || isHovered) ? engine.ui.theme.brandGold : engine.ui.theme.textPrimary)
                    ImGuiTextV(canonical)
                    ImGuiPopStyleColor(1)
                    if engine.ui.commandTitleFont != nil { ImGuiPopFont() }
                }

                // ---- Description line ----
                // Positioned at the second line of the item row. Drawn in
                // small font with dimmed text color.
                igSetCursorScreenPos(ImVec2(x: startPos.x + itemPadX, y: startPos.y + rowH + 4))
                if let descriptionFont = engine.ui.commandDescriptionFont {
                    ImGuiPushFont(descriptionFont, 0.0)
                }
                ImGuiPushStyleColor(Int32(ImGuiCol_Text.rawValue), engine.ui.theme.textDim)
                ImGuiTextV(m.descriptor.description)
                ImGuiPopStyleColor(1)
                if engine.ui.commandDescriptionFont != nil { ImGuiPopFont() }

                // ---- Alias Pill (right-aligned) ----
                // Shows the command's primary short alias regardless of which
                // command spelling matched the current query.
                // The pill is a small bordered button with the shortcut text
                // in monospace font, positioned at the right edge of the popup.
                if let shortcut, !shortcut.isEmpty {
                    let pillY = startPos.y + (itemH - rowH) / 2.0

                    if let pillFont = engine.ui.commandPillFont { ImGuiPushFont(pillFont, 0.0) }
                    let aliasW = ImGuiCalcTextSize(shortcut, nil, false, -1).x + 16
                    let pillX = startPos.x + itemAvailW - 16 - aliasW
                    igSetCursorScreenPos(ImVec2(x: pillX, y: pillY))

                    // Compact padding for the pill.
                    ImGuiPushStyleVarX(Int32(ImGuiStyleVar_FramePadding.rawValue), 8)
                    ImGuiPushStyleVarY(Int32(ImGuiStyleVar_FramePadding.rawValue), 2)

                    // Pill styling: transparent background, dimmed text,
                    // thin border matching the horizontal rule color.
                    ImGuiPushStyleColor(Int32(ImGuiCol_Text.rawValue), engine.ui.theme.textDim)
                    ImGuiPushStyleColor(Int32(ImGuiCol_Button.rawValue), ImVec4(x: 0, y: 0, z: 0, w: 0))
                    ImGuiPushStyleColor(Int32(ImGuiCol_ButtonHovered.rawValue), ImVec4(x: 0, y: 0, z: 0, w: 0))
                    ImGuiPushStyleColor(Int32(ImGuiCol_ButtonActive.rawValue), ImVec4(x: 0, y: 0, z: 0, w: 0))

                    ImGuiPushStyleVar(Int32(ImGuiStyleVar_FrameBorderSize.rawValue), 1.0)
                    ImGuiPushStyleColor(Int32(ImGuiCol_Border.rawValue), engine.ui.theme.borderDim)

                    _ = ImGuiButton(shortcut.uppercased(), ImVec2(x: 0, y: 0))

                    ImGuiPopStyleColor(5)
                    ImGuiPopStyleVar(3)
                    if engine.ui.commandPillFont != nil { ImGuiPopFont() }
                }

                // Restore cursor to the end of the selectable's layout area
                // so subsequent items stack correctly.
                igSetCursorScreenPos(endPos)
                ImGuiDummy(ImVec2(x: 0, y: 0))
            }
        }

        igEndChild()
        ImGuiPopStyleVar(2)

        // ================================================================
        // SECTION 3 — Footer (outside the scrollable child)
        // ================================================================
        // Two lines of keyboard shortcut hints, drawn in small font:
        //   Left:  ↑↓ navigate   ↵ run   Tab complete   esc dismiss
        //   Right: space to invoke · fuzzy match
        ImGuiDummy(ImVec2(x: 0, y: 4))

        if let small = engine.ui.smallFont { ImGuiPushFont(small, 0.0) }
        ImGuiPushStyleColor(Int32(ImGuiCol_Text.rawValue), engine.ui.theme.textDim)
        let hintsLeft = "\u{2191}\u{2193} navigate   \u{23CE} run   Tab complete   esc dismiss"
        ImGuiTextV(hintsLeft)

        let hintsRight = "space to invoke \u{00B7} fuzzy match"
        let hw = ImGuiCalcTextSize(hintsRight, nil, false, -1).x
        ImGuiSameLine(cmdW - 32 - hw, 0)
        ImGuiTextV(hintsRight)
        ImGuiPopStyleColor(1)
        if engine.ui.smallFont != nil { ImGuiPopFont() }
    }

    /// Renders the empty-state UI shown when no commands match the user's input.
    ///
    /// Displays a centered "No matching commands" message in dimmed text
    /// inside a short child window.
    ///
    /// - Parameters:
    ///   - engine: The engine instance providing the theme for text styling.
    ///   - cmdW: The fixed width of the command palette window (unused in
    ///     the current implementation but accepted for API symmetry with
    ///     `renderMatches`).
    ///
    /// - Note: This method must be called inside an active ImGui child window
    ///   created with `igBeginChild_Str`. It calls `igEndChild()` internally.
    @MainActor
    static func renderNoMatches(engine: PhrostEngine, cmdW: Float) {
        ImGuiDummy(ImVec2(x: 0, y: 8))

        if igBeginChild_Str("##CmdNoMatch", ImVec2(x: 0, y: 100.0), 0, Int32(ImGuiWindowFlags_None.rawValue)) {
            ImGuiPushStyleColor(Int32(ImGuiCol_Text.rawValue), engine.ui.theme.textDim)
            ImGuiTextV("No matching commands")
            ImGuiPopStyleColor(1)
        }
        igEndChild()
    }
}
