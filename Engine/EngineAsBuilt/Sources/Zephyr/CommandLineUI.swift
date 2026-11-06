import ZephyrCore
import Foundation
import ImGui

// MARK: - CommandLineUI
//
// Renders the command-line interface at the bottom of the screen.
// Activated by typing any letter key, this provides an AutoCAD-style command prompt
// with input buffer, autocomplete popup, and Up/Down arrow history.
//
// Key behaviors (Space == Enter):
//   - Space/Enter: Submit the current buffer (one token per keypress).
//     At a `.line` prompt (names, paths, text) Space stays literal and
//     only Enter submits. Repeat-last-command only fires when idle.
//   - Tab: Auto-complete to the first match
//   - Up/Down: Navigate through autocomplete matches
//   - Esc: Cancel / close command line
//
// The command buffer is persisted in engine.commandProcessor.commandBuffer
// between frames, allowing incremental typing and live filtering of matches.

@MainActor
struct CommandLineUI {
    /// Cached autocomplete matches updated each frame while the command line is open.
    static var _cmdAutoMatches: [(descriptor: CommandDescriptor, matchingAlias: String)] = []

    /// When true, the next InputText callback frame will clear any text selection
    /// and move the cursor to the end. Set after the buffer changes
    /// programmatically (submit round-trips, Tab completion).
    static var _needsClearSelection: Bool = false

    /// Tracks previous frame's command line state to detect when it just opened.
    static var _wasCommandLineActive: Bool = false
    static var _needsFocus: Bool = false

    /// Renders the command line at the bottom of the screen.
    /// - Parameters:
    ///   - engine: The engine instance for command execution and state.
    ///   - dw: Display width for full-width positioning.
    ///   - dh: Display height for bottom-anchored positioning.
    static func render(engine: PhrostEngine, dw: Float, dh: Float) {
        let isCommandLineActive = engine.commandProcessor.commandLineActive

        if !isCommandLineActive {
            _wasCommandLineActive = false
            if let prompt = engine.commandProcessor.commandPrompt,
               !prompt.isEmpty {
                renderPassiveFeaturePrompt(engine: engine, prompt: prompt, dw: dw)
            }
            return
        }

        if !_wasCommandLineActive {
            _needsClearSelection = true
            _needsFocus = true
        }
        _wasCommandLineActive = true

        let cmdW: Float = 1000 // Centered fixed width
        let winX = (dw - cmdW) / 2.0
        let winY = dh * 0.3

        // Position centered
        ImGuiSetNextWindowPos(
            ImVec2(x: winX, y: winY),
            Int32(ImGuiCond_Always.rawValue),
            ImVec2(x: 0, y: 0)
        )
        // Let it auto-resize height based on autocomplete matches up to a max
        ImGuiSetNextWindowSizeConstraints(
            ImVec2(x: cmdW, y: 0),
            ImVec2(x: cmdW, y: dh * 0.6),
            { _ in },
            nil
        )

        ImGuiPushStyleVarX(Int32(ImGuiStyleVar_WindowPadding.rawValue), 16)
        ImGuiPushStyleVarY(Int32(ImGuiStyleVar_WindowPadding.rawValue), 16)
        ImGuiPushStyleVar(Int32(ImGuiStyleVar_WindowRounding.rawValue), 14.0)
        ImGuiPushStyleColor(Int32(ImGuiCol_WindowBg.rawValue), engine.ui.theme.panelBg)
        
        ImGuiPushStyleColor(Int32(ImGuiCol_FrameBg.rawValue), ImVec4(x: 0, y: 0, z: 0, w: 0))
        ImGuiPushStyleColor(Int32(ImGuiCol_Border.rawValue), engine.ui.theme.borderDim)
        ImGuiPushStyleVar(Int32(ImGuiStyleVar_WindowBorderSize.rawValue), 1.0)

        let wflags: Int32 = 1 | 2 | 4 | 8 | 64 | 256 // Added ImGuiWindowFlags_AlwaysAutoResize (64)
        let paletteFlags: Int32 = wflags | 4096 // ImGuiWindowFlags_NoFocusOnAppearing
        
        // Active feature commands own their text input. Do not offer global
        // command autocomplete while entering an option or annotation.
        let newText = engine.commandProcessor.commandBuffer
        let activeFeatureCommand = engine.commandProcessor.activeFeatureCommand
        let featureInputActive = activeFeatureCommand != nil
        let featureOptions = activeFeatureCommand?.commandTextOptions(for: newText) ?? []
        let inputMatches = featureInputActive
            ? []
            : engine.commandProcessor.matchCommands(input: newText)
        let selIndex = engine.commandProcessor.commandSelectionIndex
        _cmdAutoMatches = inputMatches
        
        let clampedIndex = !inputMatches.isEmpty ? max(0, min(selIndex, inputMatches.count - 1)) : 0
        let featureClampedIndex = !featureOptions.isEmpty
            ? max(0, min(selIndex, featureOptions.count - 1))
            : 0
        let showPalette = featureInputActive
            ? !featureOptions.isEmpty
            : !inputMatches.isEmpty
        
        var currentY = winY
        
        // 1. INPUT WINDOW
        ImGuiSetNextWindowPos(ImVec2(x: winX, y: currentY), Int32(ImGuiCond_Always.rawValue), ImVec2(x: 0, y: 0))
        ImGuiSetNextWindowSizeConstraints(ImVec2(x: cmdW, y: 0), ImVec2(x: cmdW, y: dh * 0.6), { _ in }, nil)
        
        let enteredCmdLine = igBegin("##CmdLine", nil, wflags)
        igBringWindowToDisplayFront(igGetCurrentWindow())
        if enteredCmdLine {
            if let commandPrompt = engine.commandProcessor.commandPrompt,
               !commandPrompt.isEmpty {
                ImGuiPushStyleColor(Int32(ImGuiCol_Text.rawValue), engine.ui.theme.textPrimary)
                ImGuiTextWrappedV(commandPrompt)
                ImGuiPopStyleColor(1)
                ImGuiDummy(ImVec2(x: 0, y: 8))
            }

            if let titleFont = engine.ui.titleFont { ImGuiPushFont(titleFont, 0.0) }
            ImGuiPushStyleColor(Int32(ImGuiCol_Text.rawValue), engine.ui.theme.brandGold)
            ImGuiTextV("›")
            ImGuiPopStyleColor(1)
            ImGuiSameLine(0, 16)
            
            let promptText = featureInputActive ? "Input: " : "Cmd: "
            ImGuiPushStyleColor(Int32(ImGuiCol_Text.rawValue), engine.ui.theme.textDim)
            ImGuiTextV(promptText)
            ImGuiPopStyleColor(1)
            ImGuiSameLine(0, 8)

            ImGuiPushItemWidth(-1)
            
            let bufSize = 256
            var cBuf = [CChar](repeating: 0, count: bufSize)
            let initBytes = engine.commandProcessor.commandBuffer.utf8CString
            let copyLen = min(initBytes.count, bufSize - 1)

            cBuf.withUnsafeMutableBufferPointer { ptr in
                _ = ptr.initialize(from: initBytes.prefix(copyLen))
            }

            var submitted = false
            ImGuiPushStyleColor(Int32(ImGuiCol_Text.rawValue), engine.ui.theme.textPrimary)
            
            // Auxiliary-window frames never submit this input, so ImGui
            // clears its active ID between main frames and typed characters
            // would silently vanish. If nothing else holds activation, take
            // focus back for this frame so this frame's keystrokes land.
            if CommandLineUI._needsFocus || !ImGuiIsAnyItemActive() {
                igBringWindowToFocusFront(igGetCurrentWindow())
                igSetKeyboardFocusHere(0)
                CommandLineUI._needsFocus = false
            }

            submitted = cBuf.withUnsafeMutableBufferPointer { bufPtr -> Bool in
                guard let base = bufPtr.baseAddress else { return false }
                
                return igInputTextWithHint(
                    "##CmdInput",
                    featureInputActive ? "enter option or annotation..." : "type a command...",
                    base,
                    bufSize,
                    Int32(ImGuiInputTextFlags_EnterReturnsTrue.rawValue)
                        | Int32(ImGuiInputTextFlags_CallbackCompletion.rawValue)
                        | Int32(ImGuiInputTextFlags_CallbackAlways.rawValue),
                    { data in
                        guard let d = data else { return 0 }
                        if CommandLineUI._needsClearSelection {
                            let len = d.pointee.BufTextLen
                            d.pointee.CursorPos = len
                            d.pointee.SelectionStart = len
                            d.pointee.SelectionEnd = len
                            CommandLineUI._needsClearSelection = false
                        }
                        return 0
                    },
                    nil
                )
            }
            ImGuiPopStyleColor(1)
            
            let pMin = igGetItemRectMin()
            let pMax = igGetItemRectMax()
            let drawList = igGetWindowDrawList()
            let goldCol = igGetColorU32_Vec4(engine.ui.theme.brandGold)
            let goldTransparent = (goldCol & 0x00FFFFFF) | 0x7F000000
            let underlineY = pMax.y + 4.0
            ImDrawListAddRectFilled(drawList, ImVec2(x: pMin.x, y: underlineY), ImVec2(x: pMax.x, y: underlineY + 3.0), goldTransparent, 0.0, 0)

            let newTextFromInput = cBuf.withUnsafeBufferPointer { ptr -> String in
                guard let base = ptr.baseAddress else { return "" }
                return String(cString: base)
            }

            // Space == Enter: at a `.token` prompt a space in the buffer
            // submits exactly like Enter (one token per keypress). At a
            // `.line` prompt spaces are literal and only Enter submits.
            let spaceSubmit = !submitted
                && engine.commandProcessor.promptInputKind == .token
                && newTextFromInput.contains(where: { $0.isWhitespace })
            let submitText = spaceSubmit
                ? newTextFromInput.trimmingCharacters(in: .whitespacesAndNewlines)
                : newTextFromInput

            if !spaceSubmit, newTextFromInput != engine.commandProcessor.commandBuffer {
                engine.commandProcessor.commandBuffer = newTextFromInput
                engine.commandProcessor.commandSelectionIndex = 0
                CommandLineUI._needsClearSelection = true
            }

            if featureInputActive,
               !featureOptions.isEmpty,
               ImGuiIsKeyPressed(ImGuiKey_Tab, false) {
                engine.commandProcessor.commandBuffer = featureOptions[featureClampedIndex].value
                engine.commandProcessor.commandSelectionIndex = featureClampedIndex
                CommandLineUI._needsClearSelection = true
            } else if !inputMatches.isEmpty && ImGuiIsKeyPressed(ImGuiKey_Tab, false) {
                engine.commandProcessor.commandBuffer = inputMatches[0].descriptor.canonicalName
                engine.commandProcessor.commandSelectionIndex = 0
                CommandLineUI._needsClearSelection = true
            }

            if featureInputActive {
                updateSelection(engine: engine, itemCount: featureOptions.count)
            } else {
                updateSelection(engine: engine, matches: inputMatches)
            }

            // One submit path for Enter and Space alike: the selected
            // autocomplete match runs, otherwise the buffer goes through
            // `executeCommand`, which replays multi-token input stepwise.
            if submitted || spaceSubmit {
                if featureInputActive {
                    engine.commandProcessor.commandLineActive = false
                    engine.commandProcessor.commandBuffer = ""
                    // Empty buffer + highlighted option: Enter takes the
                    // option (arrows + Enter, no typing needed). Typed text
                    // always wins otherwise.
                    let submit = CADCommandProcessor.featureSubmitText(
                        buffer: submitText,
                        options: featureOptions,
                        selectedIndex: featureClampedIndex)
                    _ = engine.commandProcessor.submitTextToActiveFeatureCommand(
                        submit,
                        engine: engine)
                    if engine.commandProcessor.commandLineActive {
                        _needsClearSelection = true
                        _needsFocus = true
                    }
                } else if engine.commandProcessor.pendingPromptCommand == nil,
                          !inputMatches.isEmpty && clampedIndex >= 0 && clampedIndex < inputMatches.count {
                    // No pending session: Enter and Space both run the
                    // selected autocomplete match. While a pending session
                    // is open the text below goes to it instead (modal).
                    let desc = inputMatches[clampedIndex].descriptor
                    engine.commandProcessor.commandLineActive = false
                    engine.commandProcessor.commandBuffer = ""
                    engine.commandProcessor.executeCommand(desc.canonicalName)
                    if engine.commandProcessor.commandLineActive {
                        _needsClearSelection = true
                        _needsFocus = true
                    }
                } else {
                    engine.commandProcessor.commandLineActive = false
                    engine.commandProcessor.commandBuffer = ""
                    engine.commandProcessor.executeCommand(submitText)
                    if engine.commandProcessor.commandLineActive {
                        _needsClearSelection = true
                        _needsFocus = true
                    }
                }
            }

            ImGuiPopItemWidth()
            if engine.ui.titleFont != nil { ImGuiPopFont() }
        }
        let inputHeight = igGetWindowHeight()
        igEnd()

        currentY += inputHeight + 8.0

        // 2. PALETTE WINDOW
        if showPalette || (!featureInputActive && !newText.isEmpty) {
            ImGuiSetNextWindowPos(ImVec2(x: winX, y: currentY), Int32(ImGuiCond_Always.rawValue), ImVec2(x: 0, y: 0))
            ImGuiSetNextWindowSizeConstraints(ImVec2(x: cmdW, y: 0), ImVec2(x: cmdW, y: dh * 0.6), { _ in }, nil)
            
            let enteredPalette = igBegin("##CmdPalette", nil, paletteFlags)
            igBringWindowToDisplayFront(igGetCurrentWindow())
            if enteredPalette {
                if featureInputActive {
                    let currentOptions = activeFeatureCommand?.commandTextOptions(
                        for: engine.commandProcessor.commandBuffer) ?? []
                    renderFeatureOptions(
                        engine: engine,
                        options: currentOptions,
                        selectedIndex: currentOptions.isEmpty
                            ? 0
                            : max(0, min(engine.commandProcessor.commandSelectionIndex, currentOptions.count - 1)))
                } else if !inputMatches.isEmpty {
                    CommandAutocompleteUI.renderMatches(
                        engine: engine,
                        matches: inputMatches,
                        clampedIndex: clampedIndex,
                        cmdW: cmdW
                    )
                } else if !newText.isEmpty {
                    CommandAutocompleteUI.renderNoMatches(engine: engine, cmdW: cmdW)
                }
            }
            igEnd()
        }

        ImGuiPopStyleVar(4)
        ImGuiPopStyleColor(3)
    }

    private static func renderPassiveFeaturePrompt(
        engine: PhrostEngine,
        prompt: String,
        dw: Float
    ) {
        let promptW = min(Float(1000), max(Float(320), dw - 40))
        let x = (dw - promptW) * 0.5
        let y = AppLayout.belowTabBarY + 8
        let flags: Int32 = 1 | 2 | 4 | 8 | 64 | 256 | 512 | 4096 | 8192

        ImGuiSetNextWindowPos(
            ImVec2(x: x, y: y),
            Int32(ImGuiCond_Always.rawValue),
            ImVec2(x: 0, y: 0))
        ImGuiSetNextWindowSizeConstraints(
            ImVec2(x: promptW, y: 0),
            ImVec2(x: promptW, y: 120),
            { _ in }, nil)

        ImGuiPushStyleVarX(Int32(ImGuiStyleVar_WindowPadding.rawValue), 14)
        ImGuiPushStyleVarY(Int32(ImGuiStyleVar_WindowPadding.rawValue), 10)
        ImGuiPushStyleVar(Int32(ImGuiStyleVar_WindowRounding.rawValue), 8.0)
        ImGuiPushStyleVar(Int32(ImGuiStyleVar_WindowBorderSize.rawValue), 1.0)
        ImGuiPushStyleColor(Int32(ImGuiCol_WindowBg.rawValue), engine.ui.theme.panelBg)
        ImGuiPushStyleColor(Int32(ImGuiCol_Border.rawValue), engine.ui.theme.brandGold)

        let enteredPrompt = igBegin("##FeatureCommandPrompt", nil, flags)
        igBringWindowToDisplayFront(igGetCurrentWindow())
        if enteredPrompt {
            ImGuiPushStyleColor(Int32(ImGuiCol_Text.rawValue), engine.ui.theme.brandGold)
            ImGuiTextV("›")
            ImGuiPopStyleColor(1)
            ImGuiSameLine(0, 10)
            ImGuiPushStyleColor(Int32(ImGuiCol_Text.rawValue), engine.ui.theme.textPrimary)
            ImGuiTextWrappedV(prompt)
            ImGuiPopStyleColor(1)
        }
        igEnd()

        ImGuiPopStyleColor(2)
        ImGuiPopStyleVar(4)
    }

    // Retired: commands that need arguments open a pending prompted session
    // (or a feature command) instead of prefilling `"NAME "` into the
    // buffer. Space submits exactly like Enter, so a buffer can never hold
    // a same-line `"CMD arg"` tail.

    private static func renderFeatureOptions(
        engine: PhrostEngine,
        options: [FeatureCommandTextOption],
        selectedIndex: Int
    ) {
        ImGuiPushStyleColor(Int32(ImGuiCol_Text.rawValue), engine.ui.theme.textDim)
        ImGuiTextV("OPTIONS")
        ImGuiPopStyleColor(1)
        ImGuiDummy(ImVec2(x: 0, y: 6))

        // Row metrics mirror the command palette: one text line per row.
        let rowH = ImGuiGetTextLineHeightWithSpacing()
        let padX = ImGuiGetStyle()?.pointee.FramePadding.x ?? 4.0
        let transparent = ImVec4(x: 0, y: 0, z: 0, w: 0)

        for (index, option) in options.enumerated() {
            let aliasText = option.aliases.isEmpty
                ? option.value
                : "\(option.value) [\(option.aliases.joined(separator: "/"))]"
            let isSelected = index == selectedIndex
            let rowStart = igGetCursorScreenPos()
            let rowW = ImGuiGetContentRegionAvail().x

            // Transparent native highlight: the theme's raw Header/Hovered
            // colors are unreadable in some themes, so the tinted
            // commandRowHighlight rect below is the only background.
            ImGuiPushStyleColor(Int32(ImGuiCol_Header.rawValue), transparent)
            ImGuiPushStyleColor(Int32(ImGuiCol_HeaderHovered.rawValue), transparent)
            ImGuiPushStyleColor(Int32(ImGuiCol_HeaderActive.rawValue), transparent)
            let clickedRow = ImGuiSelectable(
                "##FeatureOption\(index)",
                isSelected,
                Int32(ImGuiSelectableFlags_AllowOverlap.rawValue),
                ImVec2(x: rowW, y: rowH))
            ImGuiPopStyleColor(3)
            let isHovered = ImGuiIsItemHovered(0)
            let highlighted = isSelected || isHovered
            if clickedRow {
                engine.commandProcessor.commandLineActive = false
                engine.commandProcessor.commandBuffer = ""
                _ = engine.commandProcessor.submitTextToActiveFeatureCommand(
                    option.value,
                    engine: engine)
                if engine.commandProcessor.commandLineActive {
                    _needsClearSelection = true
                    _needsFocus = true
                }
            }

            if highlighted {
                ImDrawListAddRectFilled(
                    igGetWindowDrawList(),
                    ImVec2(x: rowStart.x, y: rowStart.y),
                    ImVec2(x: rowStart.x + rowW, y: rowStart.y + rowH),
                    igGetColorU32_Vec4(engine.ui.theme.commandRowHighlight), 0, 0)
            }

            // Label re-drawn on top of the tint: gold when highlighted,
            // primary otherwise — same pairing as the command palette.
            igSetCursorScreenPos(ImVec2(x: rowStart.x + padX, y: rowStart.y))
            ImGuiPushStyleColor(
                Int32(ImGuiCol_Text.rawValue),
                highlighted ? engine.ui.theme.brandGold : engine.ui.theme.textPrimary)
            ImGuiTextV(aliasText)
            ImGuiPopStyleColor(1)
            if !option.description.isEmpty {
                ImGuiSameLine(260, 0)
                ImGuiPushStyleColor(Int32(ImGuiCol_Text.rawValue), engine.ui.theme.textDim)
                ImGuiTextV(option.description)
                ImGuiPopStyleColor(1)
            }
            // Pin the cursor to the next row; the SameLine above leaves it
            // mid-row.
            igSetCursorScreenPos(ImVec2(x: rowStart.x, y: rowStart.y + rowH))
        }
    }

    private static func updateSelection(engine: PhrostEngine, itemCount: Int) {
        guard itemCount > 0 else {
            engine.commandProcessor.commandSelectionIndex = 0
            return
        }

        if ImGuiIsKeyPressed(ImGuiKey_UpArrow, false) {
            engine.commandProcessor.commandSelectionIndex =
                engine.commandProcessor.commandSelectionIndex > 0
                ? engine.commandProcessor.commandSelectionIndex - 1
                : itemCount - 1
        }

        if ImGuiIsKeyPressed(ImGuiKey_DownArrow, false) {
            engine.commandProcessor.commandSelectionIndex =
                engine.commandProcessor.commandSelectionIndex + 1 < itemCount
                ? engine.commandProcessor.commandSelectionIndex + 1
                : 0
        }
    }

    /// Handles Up/Down arrow key navigation through the autocomplete list.
    /// Wraps around at the boundaries for a seamless cycling experience.
    @MainActor
    private static func updateSelection(
        engine: PhrostEngine,
        matches: [(descriptor: CommandDescriptor, matchingAlias: String)]
    ) {
        guard !matches.isEmpty else { return }

        if ImGuiIsKeyPressed(ImGuiKey_UpArrow, false) {
            if engine.commandProcessor.commandSelectionIndex > 0 {
                engine.commandProcessor.commandSelectionIndex -= 1
            } else {
                engine.commandProcessor.commandSelectionIndex = matches.count - 1
            }
        }

        if ImGuiIsKeyPressed(ImGuiKey_DownArrow, false) {
            if engine.commandProcessor.commandSelectionIndex + 1 < matches.count {
                engine.commandProcessor.commandSelectionIndex += 1
            } else {
                engine.commandProcessor.commandSelectionIndex = 0
            }
        }
    }
}
