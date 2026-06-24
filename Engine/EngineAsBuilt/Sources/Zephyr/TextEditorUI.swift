import ZephyrCore
import Foundation
import ImGui

// =========================================================================
// MARK: - TextEditorUI
//
// Renders a modal dialog for creating or editing text entities.
// Provides multi-line text input, font selection dropdown, height,
// rotation, alignment, and MTEXT width controls.
//
// Activated by the TEXT command (new text) or DDEDIT command / double-click
// (edit existing). The engine's `_textEditorActive` flag and
// `_textEditorState` struct control visibility and pre-populated values.
//
// Note: `TextEditorState` is defined in ZephyrCore so the Engine
// can store it directly.

// MARK: - TextEditorUI

@MainActor
public struct TextEditorUI {

    /// Available fonts cache (populated lazily from CADFontManager).
    private static var _cachedFonts: [CADFontManager.AvailableFont] = []
    private static var _fontsLoaded: Bool = false

    /// Render the text editor modal. Returns `.active` while still open,
    /// `.confirmed(state)` when OK clicked, `.cancelled` when dismissed.
    @discardableResult
    public static func render(state: inout TextEditorState, dw: Float, dh: Float) -> TextEditorResult {
        if !_fontsLoaded {
            _cachedFonts = CADFontManager.availableFonts()
            _fontsLoaded = true
        }

        let isCreating = (state.targetHandle == nil)
        let title = isCreating ? "Create Text##TextEditor" : "Edit Text##TextEditor"

        // Center the dialog
        let popupW: Float = 480
        let popupH: Float = 420
        let x = (dw - popupW) / 2
        let y = (dh - popupH) / 2

        ImGuiSetNextWindowPos(ImVec2(x: x, y: y), Int32(ImGuiCond_Always.rawValue), ImVec2(x: 0, y: 0))
        ImGuiSetNextWindowSize(ImVec2(x: popupW, y: popupH), Int32(ImGuiCond_Always.rawValue))

        // No close button — we handle closing ourselves
        let flags = Int32(ImGuiWindowFlags_NoSavedSettings.rawValue)
            | Int32(ImGuiWindowFlags_NoResize.rawValue)
            | Int32(ImGuiWindowFlags_NoCollapse.rawValue)

        var opened = true
        if !igBegin(title, &opened, flags) {
            return .active
        }
        defer { ImGuiEnd() }

        if !opened {
            return .cancelled
        }

        var result: TextEditorResult = .active

        // ---- Text input area ----
        ImGuiTextV("Text:")
        let inputW = popupW - 24
        let textH: Float = 120

        // Build a C-string buffer from the current text for ImGui input.
        let bufSize = 4096
        var cBuf = [CChar](repeating: 0, count: bufSize)
        let initBytes = state.text.utf8CString
        let copyLen = min(initBytes.count, bufSize - 1)
        cBuf.withUnsafeMutableBufferPointer { ptr in
            _ = ptr.initialize(from: initBytes.prefix(copyLen))
        }

        ImGuiPushItemWidth(inputW)
        let textChanged = cBuf.withUnsafeMutableBufferPointer { bufPtr -> Bool in
            guard let base = bufPtr.baseAddress else { return false }
            return igInputTextMultiline(
                "##TextEditInput",
                base,
                bufSize,
                ImVec2(x: inputW, y: textH),
                0,
                { _ in return 0 },
                nil
            )
        }
        ImGuiPopItemWidth()

        if textChanged {
            let newText = cBuf.withUnsafeBufferPointer { ptr -> String in
                let bytes = UnsafeRawBufferPointer(ptr).prefix(while: { $0 != 0 })
                return String(decoding: bytes, as: UTF8.self)
            }
            state.text = newText
        }


        igSpacing()

        // ---- Font selection ----
        ImGuiTextV("Font:")
        ImGuiSameLine(0, 8)
        ImGuiPushItemWidth(200)

        let currentFontName = state.fontName
        let fontDisplay = currentFontName.isEmpty ? "simplex.shx" : currentFontName

        if ImGuiBeginCombo("##FontCombo", fontDisplay, Int32(ImGuiComboFlags_None.rawValue)) {
            for font in _cachedFonts {
                let label = "\(font.name) [\(font.type.rawValue)]"
                let isSelected = (font.name == currentFontName)
                    || (font.path == currentFontName)

                if ImGuiSelectable(label, isSelected, 0, ImVec2(x: 0, y: 0)) {
                    state.fontName = font.name
                }
                if isSelected {
                    ImGuiSetItemDefaultFocus()
                }
            }
            ImGuiEndCombo()
        }
        ImGuiPopItemWidth()

        igSpacing()

        // ---- Height ----
        ImGuiTextV("Height:")
        ImGuiSameLine(0, 8)
        ImGuiPushItemWidth(100)
        var h = Float(state.height)
        if ImGuiDragFloat("##HeightDrag", &h, 0.1, 0.1, 1000.0, "%.2f", ImGuiSliderFlags(0)) {
            state.height = Double(h)
        }
        ImGuiPopItemWidth()

        ImGuiSameLine(0, 20)

        // ---- Rotation ----
        ImGuiTextV("Rotation:")
        ImGuiSameLine(0, 8)
        ImGuiPushItemWidth(80)
        var rot = Float(state.rotation * 180.0 / .pi)
        if ImGuiDragFloat("##RotDrag", &rot, 0.5, -360.0, 360.0, "%.1f°", ImGuiSliderFlags(0)) {
            state.rotation = Double(rot) * .pi / 180.0
        }
        ImGuiPopItemWidth()

        igSpacing()

        // ---- Alignment ----
        ImGuiTextV("H-Align:")
        ImGuiSameLine(0, 8)
        let hAlignLabels = ["Left", "Center", "Right"]
        var hAlign = Int32(state.alignH)
        for (i, label) in hAlignLabels.enumerated() {
            if i > 0 { ImGuiSameLine(0, 4) }
            if ImGuiRadioButton(label, &hAlign, Int32(i)) {
                state.alignH = i
            }
        }

        ImGuiTextV("V-Align:")
        ImGuiSameLine(0, 8)
        let vAlignLabels = ["Baseline", "Bottom", "Middle", "Top"]
        var vAlign = Int32(state.alignV)
        for (i, label) in vAlignLabels.enumerated() {
            if i > 0 { ImGuiSameLine(0, 4) }
            if ImGuiRadioButton(label, &vAlign, Int32(i)) {
                state.alignV = i
            }
        }

        igSpacing()

        // ---- MTEXT Width ----
        var isMText = state.mtextWidth > 0
        if ImGuiCheckbox("MTEXT (word wrap)", &isMText) {
            state.mtextWidth = isMText ? 100.0 : 0.0
        }

        if isMText {
            ImGuiSameLine(0, 8)
            ImGuiTextV("Width:")
            ImGuiSameLine(0, 4)
            ImGuiPushItemWidth(100)
            var mw = Float(state.mtextWidth)
            if ImGuiDragFloat("##MTextWidth", &mw, 1.0, 1.0, 10000.0, "%.1f", ImGuiSliderFlags(0)) {
                state.mtextWidth = Double(mw)
            }
            ImGuiPopItemWidth()
        }

        igSpacing()
        igSeparator()
        igSpacing()

        // ---- Buttons ----
        let buttonW: Float = 100
        let totalButtonW = buttonW * 2 + 8
        let buttonStartX = (popupW - totalButtonW) / 2
        ImGuiSetCursorPosX(buttonStartX)

        if igButton("OK", ImVec2(x: buttonW, y: 0)) {
            result = .confirmed(state)
        }

        ImGuiSameLine(0, 8)

        if igButton("Cancel", ImVec2(x: buttonW, y: 0)) {
            result = .cancelled
        }

        // Keyboard shortcuts
        if ImGuiIsKeyPressed(ImGuiKey_Enter, false) || ImGuiIsKeyPressed(ImGuiKey_KeypadEnter, false) {
            if !igIsItemActive() {
                result = .confirmed(state)
            }
        }
        if ImGuiIsKeyPressed(ImGuiKey_Escape, false) {
            result = .cancelled
        }

        return result
    }

    /// Reset the font cache (call after adding/removing font files).
    public static func refreshFonts() {
        _fontsLoaded = false
        _cachedFonts = []
    }
}
